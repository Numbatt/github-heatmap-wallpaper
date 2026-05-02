import Foundation

/// Single day on the contribution heatmap. Mirrors GitHub's per-cell data exactly.
public struct ContributionDay: Equatable, Hashable, Codable, Sendable {
    public let date: Date          // UTC, midnight, parsed from data-date "YYYY-MM-DD"
    public let level: Int          // 0...4 inclusive, parsed from data-level
    public let isoDate: String     // raw "YYYY-MM-DD" string for stable hashing/snapshots

    public init(date: Date, level: Int, isoDate: String) {
        self.date = date
        self.level = level
        self.isoDate = isoDate
    }
}

/// The full scraped result for one user's profile.
public struct ContributionCalendar: Equatable, Hashable, Codable, Sendable {
    public let username: String
    public let days: [ContributionDay]   // ordered chronologically, oldest first

    public init(username: String, days: [ContributionDay]) {
        self.username = username
        self.days = days
    }

    /// Stable hash of the contribution data only (excludes username).
    /// Used by the daemon's change-detection path.
    public var contentHash: String {
        var hasher = Hasher()
        for day in days {
            hasher.combine(day.isoDate)
            hasher.combine(day.level)
        }
        return String(hasher.finalize(), radix: 16)
    }
}
