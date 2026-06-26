import Foundation

/// Persisted record of the daemon's daily rotation picks. Stored separately
/// from `UserConfig` because this is transient state (changes daily), not
/// user-authored configuration.
///
/// Theme and headline rotations track their pick dates independently so
/// either can be enabled without affecting the other.
public struct RotationState: Codable, Sendable {
    /// ISO date string ("yyyy-MM-dd") of the last theme pick.
    public var lastThemePickDate: String?
    /// Theme ID picked for `lastThemePickDate`.
    public var pickedThemeID: String?
    /// ISO date string ("yyyy-MM-dd") of the last headline pick.
    public var lastHeadlinePickDate: String?
    /// Headline text picked for `lastHeadlinePickDate`.
    public var pickedHeadlineText: String?

    public init() {}
}

public enum RotationStateStore {
    /// Reads the rotation state from disk. Returns an empty `RotationState`
    /// if the file is missing or corrupt — callers treat that as "no pick yet".
    public static func read() -> RotationState {
        guard FileManager.default.fileExists(atPath: Paths.rotationStateFile.path),
              let data = try? Data(contentsOf: Paths.rotationStateFile),
              let state = try? JSONDecoder().decode(RotationState.self, from: data) else {
            return RotationState()
        }
        return state
    }

    /// Writes the rotation state atomically to `Paths.rotationStateFile`.
    public static func write(_ state: RotationState) throws {
        try Paths.ensureSupportDir()
        let data = try JSONEncoder().encode(state)
        try data.write(to: Paths.rotationStateFile, options: .atomic)
    }

    /// Removes the rotation state file so the daemon re-picks on the next tick.
    /// Used when the rotation pool changes (e.g. `gh-wallpaper rotate theme daily …`).
    public static func clear() {
        try? FileManager.default.removeItem(at: Paths.rotationStateFile)
    }
}
