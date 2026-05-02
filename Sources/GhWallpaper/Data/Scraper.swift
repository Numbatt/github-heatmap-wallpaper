import Foundation

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
            (data, response) = try await session.data(for: req)
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
        return ContributionCalendar(username: username, days: days)
    }
}
