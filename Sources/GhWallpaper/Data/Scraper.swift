import Foundation
// swift-corelibs-foundation moved URLSession into FoundationNetworking;
// Apple Foundation keeps it in the umbrella import. `@preconcurrency`
// suppresses the Linux-only warning that URLSession isn't Sendable
// (Apple Foundation's URLSession is Sendable; swift-corelibs isn't yet).
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

public enum ScraperError: Error, CustomStringConvertible {
    case userNotFound(String)
    case httpError(status: Int)
    case networkError(Error)
    case parseError(String)

    public var description: String {
        switch self {
        case .userNotFound(let u): return "GitHub user not found: \(u)"
        case .httpError(let s):    return "GitHub returned HTTP \(s)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .parseError(let m):   return "Parser error: \(m)"
        }
    }
}

/// Fetches a user's contribution-graph HTML from github.com.
public struct Scraper: Sendable {
    public static let userAgent = "gh-wallpaper/0.1 (+https://github.com/Numbatt/github-heatmap-wallpaper)"

    private let session: URLSession
    private let parser: HTMLParser

    public init(session: URLSession = .shared, parser: HTMLParser = HTMLParser()) {
        self.session = session
        self.parser = parser
    }

    public func fetch(username: String) async throws -> ContributionCalendar {
        guard let url = URL(string: "https://github.com/users/\(username)/contributions") else {
            throw ScraperError.parseError("invalid username produced bad URL: \(username)")
        }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            // Apple Foundation has `URLSession.data(for:)` (async); the
            // FoundationNetworking shipped in swift:5.10-jammy doesn't.
            // The dataTask + continuation wrapper works on every Foundation
            // implementation and platform Swift Concurrency runs on.
            (data, response) = try await Self.fetchData(session: session, request: req)
        } catch {
            throw ScraperError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ScraperError.httpError(status: -1)
        }
        if http.statusCode == 404 {
            throw ScraperError.userNotFound(username)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ScraperError.httpError(status: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ScraperError.parseError("response was not valid UTF-8")
        }
        let days = try parser.parse(html: html)
        return ContributionCalendar(username: username, days: Self.dropFutureDays(days))
    }

    /// Portable async wrapper around `URLSession.dataTask`. Bridges the
    /// completion-handler API into Swift Concurrency on platforms whose
    /// Foundation lacks the native `URLSession.data(for:)` async method.
    private static func fetchData(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    /// GitHub's anonymous HTML reports dates in UTC, which can include a cell
    /// for "tomorrow" in the user's local tz once UTC rolls past local midnight.
    /// That cell renders as an orphan in the otherwise-empty rightmost column.
    /// Compare ISO date strings (lexicographic = chronological for YYYY-MM-DD)
    /// against the user's local today so the comparison stays tz-correct.
    static func dropFutureDays(_ days: [ContributionDay], now: Date = Date()) -> [ContributionDay] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let todayISO = formatter.string(from: now)
        return days.filter { $0.isoDate <= todayISO }
    }
}
