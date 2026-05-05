import Foundation

/// User-defined themes loaded from JSON files in
/// `~/Library/Application Support/gh-wallpaper/themes/*.json`.
///
/// Each file is decoded directly into a `Theme` (which is `Codable`).
/// Files that fail validation are skipped with a logged warning — never
/// throwing, since this runs from the daemon and we don't want a malformed
/// theme file to break the refresh loop. Bad files are logged once per
/// process; the user can re-run `gh-wallpaper themes` to re-trigger a load.
public final class CustomThemes: @unchecked Sendable {

    public static let shared = CustomThemes()

    /// Override directory for tests. When non-nil, `loadOnce` reads from here
    /// instead of `Paths.customThemesDir`. Set in `setUp`, clear in
    /// `tearDown`. Has no effect once `loadOnce` has cached results — call
    /// `reload()` to re-scan after changing this.
    public var directoryOverride: URL?

    private let queue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.custom-themes")
    private var cache: [String: Theme]?

    private init() {}

    /// Returns the custom theme matching `id`, or nil if none. Triggers a
    /// one-time directory scan on first call.
    public func find(id: String) -> Theme? {
        loadOnce()[id]
    }

    /// All custom themes, sorted by id. Used by `gh-wallpaper themes`.
    public func all() -> [Theme] {
        loadOnce().values.sorted { $0.id < $1.id }
    }

    /// Forces a re-scan of the themes directory on the next `find`/`all`.
    /// Tests should call this after mutating `directoryOverride` or after
    /// writing fixture files.
    public func reload() {
        queue.sync { cache = nil }
    }

    // MARK: - Internal

    private func loadOnce() -> [String: Theme] {
        return queue.sync {
            if let cache = cache { return cache }
            let loaded = scanDirectory()
            cache = loaded
            return loaded
        }
    }

    private func scanDirectory() -> [String: Theme] {
        let dir = directoryOverride ?? Paths.customThemesDir
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            return [:]  // no dir = no custom themes; not an error
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Logger.shared.warn("custom themes: could not read \(dir.path)")
            return [:]
        }
        var loaded: [String: Theme] = [:]
        let builtinIDs = Set(Themes.builtins.map { $0.id } + ["auto"])
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let theme = decode(url: url) else { continue }
            guard validate(theme: theme, source: url) else { continue }
            if builtinIDs.contains(theme.id) {
                Logger.shared.warn(
                    "custom themes: \(url.lastPathComponent) uses reserved id '\(theme.id)' — skipping"
                )
                continue
            }
            if loaded[theme.id] != nil {
                Logger.shared.warn(
                    "custom themes: duplicate id '\(theme.id)' in \(url.lastPathComponent) — skipping"
                )
                continue
            }
            loaded[theme.id] = theme
        }
        if !loaded.isEmpty {
            Logger.shared.info("custom themes: loaded \(loaded.count) from \(dir.path)")
        }
        return loaded
    }

    private func decode(url: URL) -> Theme? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            Logger.shared.warn(
                "custom themes: failed to parse \(url.lastPathComponent): \(error)"
            )
            return nil
        }
    }

    private func validate(theme: Theme, source: URL) -> Bool {
        if theme.id.trimmingCharacters(in: .whitespaces).isEmpty {
            Logger.shared.warn("custom themes: \(source.lastPathComponent) has empty id")
            return false
        }
        if theme.cellRamp.count != 5 {
            Logger.shared.warn(
                "custom themes: \(source.lastPathComponent) cellRamp must have 5 entries (got \(theme.cellRamp.count))"
            )
            return false
        }
        for color in theme.cellRamp + [theme.headlineColor] {
            if !Self.isValidHex(color) {
                Logger.shared.warn(
                    "custom themes: \(source.lastPathComponent) has invalid color '\(color)'"
                )
                return false
            }
        }
        // Background may be a hex color or a `url(#...)` gradient reference;
        // we only require the gradient flag + gradientSVG when it looks like one.
        if theme.backgroundIsGradient {
            if theme.gradientSVG == nil {
                Logger.shared.warn(
                    "custom themes: \(source.lastPathComponent) marked backgroundIsGradient but missing gradientSVG"
                )
                return false
            }
        } else if !Self.isValidHex(theme.background) {
            Logger.shared.warn(
                "custom themes: \(source.lastPathComponent) has invalid background '\(theme.background)' (use #RRGGBB or set backgroundIsGradient)"
            )
            return false
        }
        return true
    }

    /// Validates `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`. Case-insensitive.
    static func isValidHex(_ s: String) -> Bool {
        guard s.first == "#" else { return false }
        let hex = s.dropFirst()
        guard [3, 4, 6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }
}
