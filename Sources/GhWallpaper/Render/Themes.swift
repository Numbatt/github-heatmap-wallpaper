import Foundation

/// A theme defines all colors used in a wallpaper render.
public struct Theme: Equatable, Hashable, Codable, Sendable {
    public let id: String                  // built-in id or user-supplied string for custom themes
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

    /// Tokyo Night: the popular dark editor theme. Deep midnight-blue base
    /// with a blue→magenta ramp and a cyan accent headline.
    public static let tokyoNight = Theme(
        id: "tokyo-night",
        background: "#1a1b26",  // bg
        cellRamp: [
            "#16161e",  // L0 — bg-dark, sits just below the base
            "#3d59a1",  // L1 — deep blue
            "#7aa2f7",  // L2 — blue (signature)
            "#9d7cd8",  // L3 — purple
            "#bb9af7"   // L4 — magenta peak
        ],
        headlineColor: "#7dcfff"  // cyan — the iconic Tokyo Night accent
    )

    /// Dracula: the iconic purple/pink/cyan dark theme. Selection-grey base,
    /// neon-green ramp anchored on Dracula's signature green, with a hot
    /// pink headline that's instantly recognizable.
    public static let dracula = Theme(
        id: "dracula",
        background: "#282a36",  // bg
        cellRamp: [
            "#44475a",  // L0 — current-line / selection (Dracula surface)
            "#3a5a40",  // L1 — synth dim green (bridge surface → green)
            "#50fa7b",  // L2 — green (signature)
            "#8aff9c",  // L3 — synth lighter green
            "#b4ffc7"   // L4 — synth peak
        ],
        headlineColor: "#ff79c6"  // pink — peak Dracula
    )

    /// Nord: the cold "arctic, north-bluish" palette. Polar-night base with
    /// a frost-blue ramp and a snowstorm headline. Calm, low-saturation.
    public static let nord = Theme(
        id: "nord",
        background: "#2e3440",  // polar-night-0
        cellRamp: [
            "#3b4252",  // L0 — polar-night-1
            "#5e81ac",  // L1 — frost-3 (deep blue)
            "#81a1c1",  // L2 — frost-2
            "#88c0d0",  // L3 — frost-1 (icy blue)
            "#8fbcbb"   // L4 — frost-0 (teal peak)
        ],
        headlineColor: "#eceff4"  // snow-storm-2 (off-white)
    )

    /// Gruvbox Dark (medium contrast): warm retro palette with hard yellows
    /// and oranges on a soft brown base. Beloved for its "developer-cozy"
    /// aesthetic — the dev equivalent of a wool sweater.
    public static let gruvboxDark = Theme(
        id: "gruvbox-dark",
        background: "#282828",  // dark0
        cellRamp: [
            "#3c3836",  // L0 — dark1
            "#665c54",  // L1 — dark3
            "#d79921",  // L2 — yellow
            "#fabd2f",  // L3 — yellow-bright
            "#fe8019"   // L4 — orange-bright (peak)
        ],
        headlineColor: "#ebdbb2"  // light1 — cream
    )

    /// Catppuccin Frappé: ported from the Catppuccin palette, with slot
    /// assignments matching how Hesam Panahi (who suggested the theme) uses
    /// Frappé on his own site — pink for headings, green for active elements.
    /// L1 and L4 are synthesized to bridge surface0 → green and to anchor a
    /// peak above Frappé's two published greens; the published palette only
    /// ships one base green.
    public static let catppuccinFrappe = Theme(
        id: "catppuccin-frappe",
        background: "#303446",  // base
        cellRamp: [
            "#414559",  // L0 — surface0
            "#5d7a52",  // L1 — synth dark green (bridge surface0 → green)
            "#a6d189",  // L2 — green
            "#b8e19d",  // L3 — light green
            "#cdf09d"   // L4 — synth bright green (peak anchor)
        ],
        headlineColor: "#f4b8e4"  // pink
    )

    /// Catppuccin Mocha: Frappé's deeper sibling — the darkest and most
    /// popular Catppuccin flavor. Same slot mapping as Frappé (pink headline,
    /// green ramp); L1 and L4 are synthesized for the same reason.
    public static let catppuccinMocha = Theme(
        id: "catppuccin-mocha",
        background: "#1e1e2e",  // base
        cellRamp: [
            "#313244",  // L0 — surface0
            "#5d8268",  // L1 — synth dark green (bridge surface0 → green)
            "#a6e3a1",  // L2 — green
            "#b8e9b1",  // L3 — synth light green
            "#caf0c1"   // L4 — synth bright green (peak)
        ],
        headlineColor: "#f5c2e7"  // pink
    )

    /// Built-in themes in display order. Used by the CLI help, wizard, and
    /// snapshot generator — the single source of truth for "what ships."
    public static let builtins: [Theme] = [
        githubDark, githubLight, paper, midnight,
        blossom, ocean,
        tokyoNight, dracula, nord, gruvboxDark,
        catppuccinFrappe, catppuccinMocha,
    ]

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

    /// Looks up a theme by id. Built-ins are checked first; if no match,
    /// falls back to user-defined themes loaded from
    /// `~/Library/Application Support/gh-wallpaper/themes/*.json`.
    public static func byId(_ id: String) -> Theme? {
        switch id {
        case "github-dark":       return githubDark
        case "github-light":      return githubLight
        case "paper":             return paper
        case "midnight":          return midnight
        case "blossom":           return blossom
        case "ocean":             return ocean
        case "tokyo-night":       return tokyoNight
        case "dracula":           return dracula
        case "nord":              return nord
        case "gruvbox-dark":      return gruvboxDark
        case "catppuccin-frappe": return catppuccinFrappe
        case "catppuccin-mocha":  return catppuccinMocha
        case "auto":              return autoResolved()
        default:
            return CustomThemes.shared.find(id: id)
        }
    }
}
