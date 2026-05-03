import Foundation

/// A theme defines all colors used in a wallpaper render.
public struct Theme: Equatable, Hashable, Codable, Sendable {
    public let id: String                  // "github-light" | "github-dark" | "paper" | "midnight" | "blossom" | "sunset" | "ocean" | "forest"
    public let background: String          // CSS color string, e.g. "#0d1117"
    public let backgroundIsGradient: Bool  // when true, `background` is an SVG <linearGradient>/<radialGradient> id reference
    public let cellRamp: [String]          // exactly 5 CSS color strings, level 0 -> 4
    public let headlineColor: String       // CSS color string
    /// Optional <defs> markup for gradient backgrounds. When non-nil,
    /// SVGBuilder will embed this inside <defs>...</defs> at the top of
    /// the SVG, and `background` should be a `url(#id)` reference.
    public let gradientSVG: String?

    public init(
        id: String,
        background: String,
        backgroundIsGradient: Bool = false,
        cellRamp: [String],
        headlineColor: String,
        gradientSVG: String? = nil
    ) {
        precondition(cellRamp.count == 5, "cellRamp must have exactly 5 entries (levels 0-4)")
        self.id = id
        self.background = background
        self.backgroundIsGradient = backgroundIsGradient
        self.cellRamp = cellRamp
        self.headlineColor = headlineColor
        self.gradientSVG = gradientSVG
    }
}

public enum Themes {
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

    /// Off-white "paper" theme with a single-ink (deep navy) 5-step alpha
    /// scale. Hex-with-alpha (#RRGGBBAA) is well-supported by resvg, so we
    /// express the ramp inline rather than emitting a gradient.
    public static let paper = Theme(
        id: "paper",
        background: "#f4f1ea",
        cellRamp: [
            "#0a153822",  // ~13% alpha — barely-there grid placeholder
            "#0a153855",  // ~33%
            "#0a153888",  // ~53%
            "#0a1538bb",  // ~73%
            "#0a1538ff"   // 100% — full deep navy
        ],
        headlineColor: "#0a1538"
    )

    /// Midnight: deep blue → purple radial gradient background with a custom
    /// green ramp on top. The gradient is emitted as an SVG <defs> block via
    /// `gradientSVG`, and `background` is a `url(#midnight-bg)` reference
    /// (with `backgroundIsGradient = true`).
    public static let midnight = Theme(
        id: "midnight",
        background: "url(#midnight-bg)",
        backgroundIsGradient: true,
        cellRamp: ["#1a1a3a", "#2d5f3a", "#3d8f4a", "#4dbf5a", "#5dff6a"],
        headlineColor: "#f0e7ff",
        gradientSVG: """
            <radialGradient id="midnight-bg" cx="50%" cy="50%" r="75%" fx="50%" fy="50%">
              <stop offset="0%" stop-color="#0a0a1f"/>
              <stop offset="100%" stop-color="#1e0a30"/>
            </radialGradient>
            """
    )

    /// Blossom: soft pink background with a rich rose headline and a purple
    /// 5-step cell ramp. Background and headline are different shades of pink
    /// so the text stays readable against the pale wash; the purple ramp gives
    /// the contributions enough saturation to pop off the pink.
    public static let blossom = Theme(
        id: "blossom",
        background: "#ffe3f0",
        cellRamp: [
            "#ecd5fa",  // L0 — pale lavender, just barely off the pink bg
            "#d4a3f7",  // L1 — light purple
            "#a866e8",  // L2 — medium purple
            "#7d2bd5",  // L3 — vivid purple
            "#4a148c"   // L4 — deep indigo-purple
        ],
        headlineColor: "#c2185b"  // rich rose — strong contrast on pale pink
    )

    /// Sunset: warm cream background with a deep terracotta headline and an
    /// amber→burnt-sienna cell ramp. Cozy warm-light counterpart to `paper`.
    public static let sunset = Theme(
        id: "sunset",
        background: "#fff4e6",
        cellRamp: [
            "#fde9c8",  // L0 — pale buttery yellow
            "#fbc77a",  // L1 — light amber
            "#f59e3b",  // L2 — amber/orange
            "#dd6b20",  // L3 — deep orange
            "#9a3412"   // L4 — burnt sienna
        ],
        headlineColor: "#c2410c"  // deep terracotta
    )

    /// Ocean: pale aqua background with a deep slate headline and a
    /// teal→navy cell ramp. Calm cool-light theme; pairs with sunset.
    public static let ocean = Theme(
        id: "ocean",
        background: "#e6f4f4",
        cellRamp: [
            "#cfe8ec",  // L0 — pale teal, just barely off the bg
            "#7fc7d4",  // L1 — light teal
            "#3b9ab0",  // L2 — teal
            "#1e5f7a",  // L3 — ocean blue
            "#0a2d3f"   // L4 — deep navy
        ],
        headlineColor: "#0f3a4a"  // dark slate-blue
    )

    /// Forest: warm cream background with an espresso headline and a
    /// sage→deep-emerald cell ramp. Earthy alternative to GitHub's neon greens.
    public static let forest = Theme(
        id: "forest",
        background: "#faf6ec",
        cellRamp: [
            "#e0e6d4",  // L0 — pale sage
            "#a8bf8a",  // L1 — light sage
            "#6b8e4e",  // L2 — moss
            "#3a6b2c",  // L3 — forest green
            "#1a3d18"   // L4 — deep emerald
        ],
        headlineColor: "#3d2817"  // espresso brown
    )

    /// Resolves the `auto` theme by reading the system appearance synchronously.
    /// Called per refresh tick by the daemon — no listener, no async.
    ///
    /// macOS convention: `AppleInterfaceStyle` is unset in Light Mode and
    /// equals "Dark" in Dark Mode (UserDefaults global domain).
    public static func autoResolved() -> Theme {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        if style == "Dark" {
            return githubDark
        }
        return githubLight
    }

    public static func byId(_ id: String) -> Theme? {
        switch id {
        case "github-dark":  return githubDark
        case "github-light": return githubLight
        case "paper":        return paper
        case "midnight":     return midnight
        case "blossom":      return blossom
        case "sunset":       return sunset
        case "ocean":        return ocean
        case "forest":       return forest
        case "auto":         return autoResolved()
        default: return nil
        }
    }
}
