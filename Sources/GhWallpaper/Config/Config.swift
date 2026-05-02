import Foundation

/// Persistent configuration. Lives at `~/Library/Application Support/gh-wallpaper/config.toml`.
///
/// We hand-roll a tiny key=value parser instead of pulling in a TOML library —
/// our schema is 4 keys total, all strings. If the schema ever grows arrays or
/// nested tables, switch to a real TOML library.
public struct UserConfig: Equatable, Codable, Sendable {
    public var username: String
    public var themeID: String         // "github-light" | "github-dark" | "paper" | "midnight" | "auto"
    public var displays: DisplayMode
    public var includePrivate: Bool    // not used in v0.1 (we scrape; profile setting controls it)

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
    }

    public init(
        username: String,
        themeID: String = "github-dark",
        displays: DisplayMode = .all,
        includePrivate: Bool = true
    ) {
        self.username = username
        self.themeID = themeID
        self.displays = displays
        self.includePrivate = includePrivate
    }

    public func resolvedTheme() -> Theme {
        Themes.byId(themeID) ?? Themes.githubDark
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
        return UserConfig(
            username: username,
            themeID: themeID,
            displays: displays,
            includePrivate: includePrivate
        )
    }

    public static func write(_ config: UserConfig) throws {
        try Paths.ensureSupportDir()
        let contents = """
        # gh-wallpaper config — edit via the wizard (`gh-wallpaper`) or CLI subcommands.
        username = "\(config.username)"
        theme = "\(config.themeID)"
        displays = "\(config.displays.serialized)"
        include_private = \(config.includePrivate ? "true" : "false")

        """
        try contents.write(to: Paths.configFile, atomically: true, encoding: .utf8)
    }
}
