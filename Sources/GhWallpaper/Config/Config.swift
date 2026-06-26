import Foundation

/// Persistent configuration. Lives at `~/Library/Application Support/gh-wallpaper/config.toml`.
///
/// We hand-roll a tiny key=value parser instead of pulling in a TOML library —
/// our schema is 4 keys total, all strings. If the schema ever grows arrays or
/// nested tables, switch to a real TOML library.
public struct UserConfig: Equatable, Codable, Sendable {
    public var username: String
    public var themeID: String         // any built-in id (see `Themes.builtins`), "auto", or a custom theme id loaded from `Paths.customThemesDir`
    public var displays: DisplayMode
    public var includePrivate: Bool    // not used in v0.1 (we scrape; profile setting controls it)

    // Headline display settings. nil = use built-in default for each field.
    public var headlineText: String?        // nil → "DESIGN  BUILD  SHIP"
    public var headlineFont: HeadlineFont?  // nil → .pixelGlyphs
    public var headlineSizeScale: Double?   // nil → 1.0

    // Daily rotation config. default = rotation off.
    public var rotationConfig: RotationConfig

    public enum DisplayMode: Equatable, Codable, Sendable {
        case all
        case mainOnly
        case custom(uuids: [String])

        public var serialized: String {
            switch self {
            case .all: return "all"
            case .mainOnly: return "main"
            case .custom(let uuids): return "custom:" + uuids.joined(separator: ",")
            }
        }

        public static func parse(_ raw: String) -> DisplayMode {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s == "all" { return .all }
            if s == "main" { return .mainOnly }
            if s.hasPrefix("custom:") {
                let list = s.dropFirst("custom:".count)
                let ids = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                return .custom(uuids: ids.filter { !$0.isEmpty })
            }
            return .all  // unknown → safe default
        }

        #if os(macOS)
        /// Returns the subset of `displays` that this mode targets. For
        /// `.mainOnly`, picks the display flagged `isMain` (or the first
        /// display as a fallback). For `.custom`, returns matches by UUID;
        /// if no UUIDs match (e.g. the configured display is currently
        /// disconnected), falls back to all so the user always sees *some*
        /// wallpaper.
        ///
        /// macOS-only: `DisplayInfo` and the multi-display flow live behind
        /// `#if os(macOS)`. Linux is single-display + explicit `--canvas`.
        public func filter(_ displays: [DisplayInfo]) -> [DisplayInfo] {
            switch self {
            case .all:
                return displays
            case .mainOnly:
                if let main = displays.first(where: { $0.isMain }) {
                    return [main]
                }
                return displays.first.map { [$0] } ?? []
            case .custom(let uuids):
                let set = Set(uuids)
                let matched = displays.filter { set.contains($0.uuid) }
                return matched.isEmpty ? displays : matched
            }
        }
        #endif
    }

    public init(
        username: String,
        themeID: String = "github-dark",
        displays: DisplayMode = .all,
        includePrivate: Bool = true,
        headlineText: String? = nil,
        headlineFont: HeadlineFont? = nil,
        headlineSizeScale: Double? = nil,
        rotationConfig: RotationConfig = .default
    ) {
        self.username = username
        self.themeID = themeID
        self.displays = displays
        self.includePrivate = includePrivate
        self.headlineText = headlineText
        self.headlineFont = headlineFont
        self.headlineSizeScale = headlineSizeScale
        self.rotationConfig = rotationConfig
    }

    public func resolvedTheme() -> Theme {
        Themes.byId(themeID) ?? Themes.githubDark
    }

    public func resolvedHeadlineOptions() -> HeadlineOptions {
        HeadlineOptions(text: headlineText, font: headlineFont, sizeScale: headlineSizeScale)
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case notFound
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound: return "config file not found at \(Paths.configFile.path); run `gh-wallpaper` to set up"
        case .invalid(let m): return "invalid config: \(m)"
        }
    }
}

/// Tiny TOML-subset reader/writer. Supports only `key = "value"` and `key = true|false`.
public enum ConfigStore {

    public static func exists() -> Bool {
        FileManager.default.fileExists(atPath: Paths.configFile.path)
    }

    public static func read() throws -> UserConfig {
        guard FileManager.default.fileExists(atPath: Paths.configFile.path) else {
            throw ConfigError.notFound
        }
        let raw = try String(contentsOf: Paths.configFile, encoding: .utf8)
        var kv: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            kv[key] = val
        }
        guard let username = kv["username"], !username.isEmpty else {
            throw ConfigError.invalid("missing or empty username")
        }
        let themeID = kv["theme"] ?? "github-dark"
        let displays = UserConfig.DisplayMode.parse(kv["displays"] ?? "all")
        let includePrivate = (kv["include_private"] ?? "true") == "true"

        // Headline settings (all optional)
        let headlineText = kv["headline_text"].flatMap { $0.isEmpty ? nil : $0 }
        let headlineFont = kv["headline_font"].flatMap { HeadlineFont.parse($0) }
        let headlineSizeScale = kv["headline_size_scale"].flatMap { s -> Double? in
            guard let d = Double(s), d > 0 else { return nil }
            return d
        }

        // Rotation settings
        let rotateTheme = kv["rotate_theme"].flatMap { RotationMode(rawValue: $0) } ?? .off
        let rotateThemePool = kv["rotate_theme_pool"].map { s in
            s.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        let rotateHeadline = kv["rotate_headline"].flatMap { RotationMode(rawValue: $0) } ?? .off
        let rotateHeadlinePool = kv["rotate_headline_pool"].map { s in
            s.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []

        return UserConfig(
            username: username,
            themeID: themeID,
            displays: displays,
            includePrivate: includePrivate,
            headlineText: headlineText,
            headlineFont: headlineFont,
            headlineSizeScale: headlineSizeScale,
            rotationConfig: RotationConfig(
                themeMode: rotateTheme,
                themePool: rotateThemePool,
                headlineMode: rotateHeadline,
                headlinePool: rotateHeadlinePool
            )
        )
    }

    public static func write(_ config: UserConfig) throws {
        try Paths.ensureSupportDir()
        var lines: [String] = [
            "# gh-wallpaper config — edit via the wizard (`gh-wallpaper`) or CLI subcommands.",
            "username = \"\(config.username)\"",
            "theme = \"\(config.themeID)\"",
            "displays = \"\(config.displays.serialized)\"",
            "include_private = \(config.includePrivate ? "true" : "false")",
        ]

        // Headline settings — only emit when non-default so the file stays readable.
        if let text = config.headlineText, !text.isEmpty {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("headline_text = \"\(escaped)\"")
        }
        if let font = config.headlineFont {
            lines.append("headline_font = \"\(font.serialized)\"")
        }
        if let scale = config.headlineSizeScale, scale != 1.0 {
            lines.append(String(format: "headline_size_scale = %.4g", scale))
        }

        // Rotation settings
        let rot = config.rotationConfig
        if rot.themeMode != .off {
            lines.append("rotate_theme = \"\(rot.themeMode.rawValue)\"")
        }
        if !rot.themePool.isEmpty {
            lines.append("rotate_theme_pool = \"\(rot.themePool.joined(separator: "|"))\"")
        }
        if rot.headlineMode != .off {
            lines.append("rotate_headline = \"\(rot.headlineMode.rawValue)\"")
        }
        if !rot.headlinePool.isEmpty {
            let pool = rot.headlinePool.joined(separator: "|")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("rotate_headline_pool = \"\(pool)\"")
        }

        lines.append("")  // trailing newline
        try lines.joined(separator: "\n").write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }
}
