import Foundation

/// A theme defines all colors used in a wallpaper render.
///
/// FROZEN INTERFACE — Wave 2 Stream C populates the full set; M1 ships only
/// `githubDark`. The struct shape itself does not change.
public struct Theme: Equatable, Hashable, Codable, Sendable {
    public let id: String                  // "github-light" | "github-dark" | "paper" | "midnight"
    public let background: String          // CSS color string, e.g. "#0d1117"
    public let backgroundIsGradient: Bool  // when true, `background` is an SVG <linearGradient>/<radialGradient> id reference
    public let cellRamp: [String]          // exactly 5 CSS color strings, level 0 -> 4
    public let headlineColor: String       // CSS color string

    public init(
        id: String,
        background: String,
        backgroundIsGradient: Bool = false,
        cellRamp: [String],
        headlineColor: String
    ) {
        precondition(cellRamp.count == 5, "cellRamp must have exactly 5 entries (levels 0-4)")
        self.id = id
        self.background = background
        self.backgroundIsGradient = backgroundIsGradient
        self.cellRamp = cellRamp
        self.headlineColor = headlineColor
    }
}

public enum Themes {
    /// Ships in M1. Wave 2 Stream C will add the others + auto-resolver.
    public static let githubDark = Theme(
        id: "github-dark",
        background: "#0d1117",
        cellRamp: ["#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"],
        headlineColor: "#f0f6fc"
    )

    public static let githubLight = Theme(
        id: "github-light",
        background: "#ffffff",
        cellRamp: ["#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39"],
        headlineColor: "#0d1117"
    )

    public static func byId(_ id: String) -> Theme? {
        switch id {
        case "github-dark":  return githubDark
        case "github-light": return githubLight
        default: return nil
        }
    }
}
