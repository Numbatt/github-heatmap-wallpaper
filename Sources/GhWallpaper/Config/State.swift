import Foundation

/// Runtime state — separate from user-edited Config. JSON is fine; the user
/// shouldn't be editing this by hand.
public struct DaemonState: Codable {
    public var lastRefreshAt: Date?
    public var lastRenderHash: String?
    public var lastDataHash: String?
    public var consecutiveFailures: Int
    public var lastError: String?

    /// The version string of the binary the last time the daemon ran.
    /// Used to detect first-run after an upgrade and show "what's new".
    public var lastSeenVersion: String?
    /// When the daemon last hit the GitHub releases API to check for updates.
    public var lastUpdateCheckAt: Date?
    /// The latest version returned by the update check, if newer than CurrentVersion.
    public var latestAvailableVersion: String?
    /// The latest version we already sent a macOS notification for, so we
    /// don't re-notify on every tick.
    public var lastUpdateNotifiedVersion: String?

    public init(
        lastRefreshAt: Date? = nil,
        lastRenderHash: String? = nil,
        lastDataHash: String? = nil,
        consecutiveFailures: Int = 0,
        lastError: String? = nil,
        lastSeenVersion: String? = nil,
        lastUpdateCheckAt: Date? = nil,
        latestAvailableVersion: String? = nil,
        lastUpdateNotifiedVersion: String? = nil
    ) {
        self.lastRefreshAt = lastRefreshAt
        self.lastRenderHash = lastRenderHash
        self.lastDataHash = lastDataHash
        self.consecutiveFailures = consecutiveFailures
        self.lastError = lastError
        self.lastSeenVersion = lastSeenVersion
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.latestAvailableVersion = latestAvailableVersion
        self.lastUpdateNotifiedVersion = lastUpdateNotifiedVersion
    }
}

public enum StateStore {
    public static func read() -> DaemonState {
        guard let data = try? Data(contentsOf: Paths.stateFile) else {
            return DaemonState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DaemonState.self, from: data)) ?? DaemonState()
    }

    public static func write(_ state: DaemonState) throws {
        try Paths.ensureSupportDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: Paths.stateFile, options: [.atomic])
    }
}
