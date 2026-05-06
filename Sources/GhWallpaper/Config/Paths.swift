import Foundation

/// Canonical filesystem paths used throughout gh-wallpaper.
/// All of these live under the user's home directory; no system-wide files.
///
/// macOS keeps its existing layout under `~/Library/Application Support/gh-wallpaper/`
/// (config + cache + state collapse to one directory). Linux follows the
/// XDG Base Directory spec, splitting config / cache / state across separate
/// directories.
public enum Paths {

    // MARK: - Platform-conditional roots

    #if os(macOS)
    /// macOS: `~/Library/Application Support/gh-wallpaper/`
    public static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/gh-wallpaper", isDirectory: true)
    }

    /// On macOS, cache state and config all live in supportDir.
    public static var cacheDir: URL { supportDir }
    public static var stateDir: URL { supportDir }
    #else
    /// Linux config root: `${XDG_CONFIG_HOME:-~/.config}/gh-wallpaper/`
    public static var supportDir: URL {
        xdgRoot(env: "XDG_CONFIG_HOME", fallback: ".config")
    }

    /// Linux cache root: `${XDG_CACHE_HOME:-~/.cache}/gh-wallpaper/`
    public static var cacheDir: URL {
        xdgRoot(env: "XDG_CACHE_HOME", fallback: ".cache")
    }

    /// Linux state root: `${XDG_STATE_HOME:-~/.local/state}/gh-wallpaper/`
    public static var stateDir: URL {
        xdgRoot(env: "XDG_STATE_HOME", fallback: ".local/state")
    }

    private static func xdgRoot(env: String, fallback: String) -> URL {
        let envValue = ProcessInfo.processInfo.environment[env]
        let base: URL
        if let envValue, !envValue.isEmpty {
            base = URL(fileURLWithPath: envValue)
        } else {
            base = URL(fileURLWithPath: linuxHome()).appendingPathComponent(fallback)
        }
        return base.appendingPathComponent("gh-wallpaper", isDirectory: true)
    }

    /// Linux home directory. Prefers `$HOME` over `NSHomeDirectory()` because
    /// `NSHomeDirectory()` reads from the passwd database (`getpwuid(getuid())`),
    /// which can disagree with `$HOME` in containers, GitHub Actions runners,
    /// and sudo-like contexts. Systemd's `%h` resolves via `$HOME`, so for
    /// the systemd-unit and XDG paths to agree with what the user manager
    /// expects, we follow the same convention.
    private static func linuxHome() -> String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }
    #endif

    // MARK: - Files (platform-neutral, derived from the roots above)

    public static var configFile: URL {
        #if os(macOS)
        return supportDir.appendingPathComponent("config.toml")
        #else
        return supportDir.appendingPathComponent("config.toml")
        #endif
    }

    public static var stateFile: URL {
        stateDir.appendingPathComponent("state.json")
    }

    /// Directory where users drop custom theme JSON files.
    /// Each `*.json` file under this dir is loaded at startup, decoded
    /// into a `Theme`, and made available alongside the built-ins.
    public static var customThemesDir: URL {
        supportDir.appendingPathComponent("themes", isDirectory: true)
    }

    /// Directory inside `customThemesDir` where the editor stores image
    /// backgrounds copied from the user's photo picker. Theme JSONs
    /// reference these as `images/<theme-id>.<ext>` (relative paths).
    public static var customThemesImagesDir: URL {
        customThemesDir.appendingPathComponent("images", isDirectory: true)
    }

    public static var previousWallpapersFile: URL {
        stateDir.appendingPathComponent("previous-wallpapers.json")
    }

    public static func wallpaperPNG(displayUUID: String) -> URL {
        cacheDir.appendingPathComponent("wallpaper-\(displayUUID).png")
    }

    #if os(macOS)
    public static var launchdPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/dev.numbatt.gh-wallpaper.plist")
    }

    public static let launchdLabel = "dev.numbatt.gh-wallpaper"

    public static var logFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/gh-wallpaper/agent.log")
    }
    #else
    /// Linux unit lives at `${XDG_CONFIG_HOME:-~/.config}/systemd/user/gh-wallpaper.service`.
    /// The unit file isn't owned by the binary — it ships via `contrib/linux/install.sh` —
    /// but the path is exposed here for the diagnose command.
    public static var systemdUnitPath: URL {
        let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base: URL
        if let cfg, !cfg.isEmpty {
            base = URL(fileURLWithPath: cfg)
        } else {
            base = URL(fileURLWithPath: linuxHome()).appendingPathComponent(".config")
        }
        return base.appendingPathComponent("systemd/user/gh-wallpaper.service")
    }

    public static let systemdUnitName = "gh-wallpaper.service"

    public static var logFile: URL {
        stateDir.appendingPathComponent("agent.log")
    }
    #endif

    /// Ensures the relevant directories exist. Idempotent. Creates support,
    /// cache, and state roots — on macOS these all collapse to one directory.
    @discardableResult
    public static func ensureSupportDir() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        return supportDir
    }
}
