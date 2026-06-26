import Foundation

/// Rendering mode for the wallpaper headline.
///
/// `.pixelGlyphs` is the default — renders using the hand-designed rect-based
/// glyphs in `Glyphs.swift` (no system font dependency, identical output on all
/// platforms). `.system` renders an SVG `<text>` element using `font-family`,
/// which resvg resolves via fontdb against installed system fonts.
public enum HeadlineFont: Equatable, Hashable, Codable, Sendable {
    case pixelGlyphs
    case system(family: String)

    /// Stable string representation used for config persistence and render hashing.
    /// Format: `"pixel-glyphs"` or `"system:<family>"`.
    var serialized: String {
        switch self {
        case .pixelGlyphs:         return "pixel-glyphs"
        case .system(let family):  return "system:\(family)"
        }
    }

    /// Parses a serialized string back to a `HeadlineFont`. Returns `nil` on
    /// unrecognized input so callers can warn and fall back gracefully.
    static func parse(_ raw: String) -> HeadlineFont? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "pixel-glyphs" { return .pixelGlyphs }
        if s.hasPrefix("system:") {
            let family = String(s.dropFirst("system:".count)).trimmingCharacters(in: .whitespaces)
            return family.isEmpty ? nil : .system(family: family)
        }
        return nil
    }
}

/// All display-level options that affect how the headline is rendered.
/// Passed as a parameter to `SVGBuilder.build` so callers can override
/// without touching `UserConfig`.
///
/// All fields are optional; `nil` means "use the built-in default":
///   - `text`      → `"DESIGN  BUILD  SHIP"`
///   - `font`      → `.pixelGlyphs`
///   - `sizeScale` → `1.0`
public struct HeadlineOptions: Equatable, Hashable, Sendable {
    public var text: String?
    public var font: HeadlineFont?
    public var sizeScale: Double?

    public static let `default` = HeadlineOptions()

    public init(text: String? = nil, font: HeadlineFont? = nil, sizeScale: Double? = nil) {
        self.text = text
        self.font = font
        self.sizeScale = sizeScale
    }

    public var resolvedText: String { text ?? "DESIGN  BUILD  SHIP" }
    public var resolvedFont: HeadlineFont { font ?? .pixelGlyphs }
    public var resolvedSizeScale: Double { sizeScale ?? 1.0 }

    /// Stable string for render hashing. Changing font or serialization format
    /// produces a different string and invalidates the cached hash.
    var fontString: String { resolvedFont.serialized }
}
