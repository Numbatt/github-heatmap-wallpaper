import Foundation

public enum RotationMode: String, Equatable, Codable, Sendable {
    case off
    case daily
}

/// Controls daily rotation of themes and headline texts.
/// When a mode is `.daily`, the daemon picks one entry from its pool
/// at the first refresh tick of each new calendar day and holds that
/// pick stable for the remainder of the day.
public struct RotationConfig: Equatable, Codable, Sendable {
    /// Whether to rotate through themes daily.
    public var themeMode: RotationMode
    /// Explicit theme IDs to rotate through. Empty = all built-in themes.
    /// `"auto"` is always excluded (rotation picks must be stable).
    public var themePool: [String]
    /// Whether to rotate through headline texts daily.
    public var headlineMode: RotationMode
    /// The headline strings to rotate through. Rotation is a no-op when empty.
    public var headlinePool: [String]

    public static let `default` = RotationConfig()

    public init(
        themeMode: RotationMode = .off,
        themePool: [String] = [],
        headlineMode: RotationMode = .off,
        headlinePool: [String] = []
    ) {
        self.themeMode = themeMode
        self.themePool = themePool
        self.headlineMode = headlineMode
        self.headlinePool = headlinePool
    }
}
