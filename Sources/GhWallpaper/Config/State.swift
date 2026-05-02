import Foundation

/// Runtime state — separate from user-edited Config. JSON is fine; the user
/// shouldn't be editing this by hand.
public struct DaemonState: Codable {
    public var lastRefreshAt: Date?
    public var lastRenderHash: String?
    public var lastDataHash: String?
    public var consecutiveFailures: Int
    public var lastError: String?

    public init(
        lastRefreshAt: Date? = nil,
        lastRenderHash: String? = nil,
        lastDataHash: String? = nil,
        consecutiveFailures: Int = 0,
        lastError: String? = nil
    ) {
        self.lastRefreshAt = lastRefreshAt
        self.lastRenderHash = lastRenderHash
        self.lastDataHash = lastDataHash
        self.consecutiveFailures = consecutiveFailures
        self.lastError = lastError
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
