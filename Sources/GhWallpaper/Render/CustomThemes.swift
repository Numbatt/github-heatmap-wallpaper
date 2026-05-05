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

    /// Writes a theme to `Paths.customThemesDir/<id>.json` (or
    /// `directoryOverride` if set). Creates the directory if missing.
    /// Uses pretty-printed, sorted-key JSON so files diff cleanly.
    /// Caller is responsible for refusing to write over a built-in id.
    @discardableResult
    public func save(_ theme: Theme) throws -> URL {
        let dir = directoryOverride ?? Paths.customThemesDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(theme.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: url, options: [.atomic])
        reload()
        return url
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
            guard let decoded = decode(url: url) else { continue }
            guard let theme = validateAndResolve(theme: decoded, source: url) else { continue }
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

    /// Validates a decoded theme and rewrites `backgroundImagePath` to an
    /// absolute filesystem path on success. Returns nil if validation fails
    /// (with a Logger.warn for each rejected file); returns the (possibly
    /// transformed) `Theme` on success.
    private func validateAndResolve(theme: Theme, source: URL) -> Theme? {
        switch Self.validate(theme: theme, baseDirectory: source.deletingLastPathComponent()) {
        case .success(let resolved):
            return resolved
        case .failure(let err):
            Logger.shared.warn("custom themes: \(source.lastPathComponent) \(err.message)")
            return nil
        }
    }

    /// Pure validator usable from any caller (e.g. `themes import` from
    /// stdin). Returns the theme with `backgroundImagePath` rewritten to an
    /// absolute path on success; otherwise a `ValidationError` with a
    /// human-readable message the caller can print to stderr.
    ///
    /// Pass `baseDirectory: nil` to forbid relative `backgroundImagePath`
    /// values (use absolute or `~/` paths only). With `baseDirectory` set,
    /// relative paths resolve against that directory.
    public enum ValidationError: Error, CustomStringConvertible {
        case empty(field: String)
        case wrongRampLength(got: Int)
        case invalidColor(String)
        case gradientWithoutSVG
        case invalidBackgroundColor(String)
        case imagePathRelativeWithoutBase
        case imageExtensionNotSupported(String)
        case imageNotFound(String)
        case dimAlphaOutOfRange(Double)

        public var message: String {
            switch self {
            case .empty(let f):                return "\(f) is empty"
            case .wrongRampLength(let n):       return "cellRamp must have 5 entries (got \(n))"
            case .invalidColor(let c):          return "invalid color '\(c)'"
            case .gradientWithoutSVG:           return "marked backgroundIsGradient but missing gradientSVG"
            case .invalidBackgroundColor(let b):return "invalid background '\(b)' (use #RRGGBB or set backgroundIsGradient)"
            case .imagePathRelativeWithoutBase: return "backgroundImagePath must be absolute (or ~/-prefixed) when imported from stdin"
            case .imageExtensionNotSupported(let e): return "backgroundImagePath must be png/jpg/jpeg (got '.\(e)')"
            case .imageNotFound(let p):         return "backgroundImagePath not found at \(p)"
            case .dimAlphaOutOfRange(let v):    return "backgroundDimAlpha must be 0…1 (got \(v))"
            }
        }

        public var description: String { message }
    }

    public static func validate(theme: Theme, baseDirectory: URL?) -> Result<Theme, ValidationError> {
        if theme.id.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(.empty(field: "id"))
        }
        if theme.cellRamp.count != 5 {
            return .failure(.wrongRampLength(got: theme.cellRamp.count))
        }
        for color in theme.cellRamp + [theme.headlineColor] {
            if !isValidHex(color) {
                return .failure(.invalidColor(color))
            }
        }
        if theme.backgroundIsGradient {
            if theme.gradientSVG == nil {
                return .failure(.gradientWithoutSVG)
            }
        } else if !isValidHex(theme.background) {
            return .failure(.invalidBackgroundColor(theme.background))
        }
        var resolvedImagePath: String? = nil
        if let raw = theme.backgroundImagePath, !raw.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let isAbsoluteOrTilde = trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
            if !isAbsoluteOrTilde && baseDirectory == nil {
                return .failure(.imagePathRelativeWithoutBase)
            }
            let baseURL = baseDirectory ?? Paths.customThemesDir
            let resolved = resolveImagePath(raw, base: baseURL)
            let allowed: Set<String> = ["png", "jpg", "jpeg"]
            let ext = (resolved as NSString).pathExtension.lowercased()
            guard allowed.contains(ext) else {
                return .failure(.imageExtensionNotSupported(ext))
            }
            guard FileManager.default.fileExists(atPath: resolved) else {
                return .failure(.imageNotFound(resolved))
            }
            resolvedImagePath = resolved
        }
        if let alpha = theme.backgroundDimAlpha, !(0.0...1.0).contains(alpha) {
            return .failure(.dimAlphaOutOfRange(alpha))
        }
        if resolvedImagePath == nil {
            return .success(theme)
        }
        return .success(Theme(
            id: theme.id,
            background: theme.background,
            backgroundIsGradient: theme.backgroundIsGradient,
            cellRamp: theme.cellRamp,
            headlineColor: theme.headlineColor,
            gradientSVG: theme.gradientSVG,
            backgroundImagePath: resolvedImagePath,
            backgroundDimAlpha: theme.backgroundDimAlpha
        ))
    }

    /// Resolves a `backgroundImagePath` string to an absolute filesystem path.
    /// - Absolute (`/foo/bar.png`) → unchanged.
    /// - Tilde (`~/Pictures/foo.png`) → expanded.
    /// - Relative (`images/foo.png`) → joined to `base`.
    static func resolveImagePath(_ raw: String, base: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") { return trimmed }
        if trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return base.appendingPathComponent(trimmed).standardizedFileURL.path
    }

    /// Validates `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`. Case-insensitive.
    static func isValidHex(_ s: String) -> Bool {
        guard s.first == "#" else { return false }
        let hex = s.dropFirst()
        guard [3, 4, 6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }
}
