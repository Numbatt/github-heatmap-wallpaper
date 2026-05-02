import Foundation

/// Canonical filesystem paths used throughout gh-wallpaper.
/// All of these live under the user's home directory; no system-wide files.
public enum Paths {
    public static var supportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/gh-wallpaper", isDirectory: true)
    }

    public static var configFile: URL {
        supportDir.appendingPathComponent("config.toml")
    }

    public static var stateFile: URL {
        supportDir.appendingPathComponent("state.json")
    }

    public static var previousWallpapersFile: URL {
        supportDir.appendingPathComponent("previous-wallpapers.json")
    }

    public static func wallpaperPNG(displayUUID: String) -> URL {
        supportDir.appendingPathComponent("wallpaper-\(displayUUID).png")
    }

    public static var launchdPlist: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/dev.numbatt.gh-wallpaper.plist")
    }

    public static let launchdLabel = "dev.numbatt.gh-wallpaper"

    public static var logFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/gh-wallpaper/agent.log")
    }

    /// Ensures the support directory exists. Idempotent.
    @discardableResult
    public static func ensureSupportDir() throws -> URL {
        let dir = supportDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
