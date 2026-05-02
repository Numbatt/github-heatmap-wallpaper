import AppKit
import Foundation

/// Capture & restore the user's previous wallpaper.
///
/// On first activation we snapshot whatever wallpaper each display is currently
/// showing, and on uninstall we put it back. Static image files (e.g.
/// `~/Pictures/sunset.jpg`) can be re-set via `setDesktopImageURL`. macOS
/// Dynamic Desktops (the time-of-day shifters under
/// `/System/Library/Desktop Pictures/`) have no public API to re-apply, so we
/// instead deep-link the user to the Wallpaper settings pane so they can re-pick.
///
/// SPEC.md §14 has the full design.

public enum PreviousWallpaperType: String, Codable {
    case staticImage = "static"
    case dynamic = "dynamic"
    case unknown = "unknown"
}

public struct PreviousWallpaper: Codable, Equatable {
    public let displayUUID: String
    public let type: PreviousWallpaperType
    /// Populated only when `type == .staticImage`.
    public let imagePath: String?

    public init(displayUUID: String, type: PreviousWallpaperType, imagePath: String?) {
        self.displayUUID = displayUUID
        self.type = type
        self.imagePath = imagePath
    }
}

public struct RestoreResult {
    public let displayUUID: String
    /// Human-readable, e.g. "restored sunset.jpg" or
    /// "opened Wallpaper settings — re-pick manually".
    public let action: String

    public init(displayUUID: String, action: String) {
        self.displayUUID = displayUUID
        self.action = action
    }
}

public enum CaptureRestoreError: Error, CustomStringConvertible {
    case appSupportUnavailable

    public var description: String {
        switch self {
        case .appSupportUnavailable:
            return "could not resolve ~/Library/Application Support"
        }
    }
}

public struct CaptureRestore {
    private static let dynamicSystemPrefix = "/System/Library/Desktop Pictures/"
    private static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
    private static let wallpaperSettingsDeepLink = URL(
        string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
    )!

    private let setter: WallpaperSetter
    private let fileManager: FileManager
    private let workspace: NSWorkspace

    public init() {
        self.setter = WallpaperSetter()
        self.fileManager = .default
        self.workspace = .shared
    }

    // MARK: - Paths

    /// `~/Library/Application Support/gh-wallpaper/previous-wallpapers.json`.
    /// Mirrors the directory convention from `Entrypoint.swift`.
    private func jsonURL() throws -> URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CaptureRestoreError.appSupportUnavailable
        }
        let dir = appSupport.appendingPathComponent("gh-wallpaper", isDirectory: true)
        return dir.appendingPathComponent("previous-wallpapers.json")
    }

    // MARK: - Capture

    /// Captures the current wallpaper for each display and writes
    /// `previous-wallpapers.json`. Idempotent: if the file already exists we
    /// skip — re-running activation must not overwrite the original snapshot
    /// with a path pointing at our own gh-wallpaper PNG.
    public func capture(displays: [DisplayInfo]) throws {
        let url = try jsonURL()

        if fileManager.fileExists(atPath: url.path) {
            return
        }

        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let entries: [PreviousWallpaper] = displays.map { display in
            classify(display: display)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }

    /// Detection rule:
    /// - `currentURL` is nil → `.unknown`
    /// - URL path begins with `/System/Library/Desktop Pictures/` → `.dynamic`
    ///   (covers Dynamic Desktops + Apple-shipped static system pictures; both
    ///   are unsafe to re-set programmatically and the deep-link path is a
    ///   strict superset of the user experience either way)
    /// - URL points to an existing regular file with extension in
    ///   {heic,jpg,jpeg,png} → `.staticImage`
    /// - otherwise → `.unknown`
    private func classify(display: DisplayInfo) -> PreviousWallpaper {
        guard let url = setter.currentURL(for: display) else {
            return PreviousWallpaper(displayUUID: display.uuid, type: .unknown, imagePath: nil)
        }

        let path = url.path

        if path.hasPrefix(Self.dynamicSystemPrefix) {
            return PreviousWallpaper(displayUUID: display.uuid, type: .dynamic, imagePath: nil)
        }

        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()

        if exists, !isDir.boolValue, Self.imageExtensions.contains(ext) {
            return PreviousWallpaper(displayUUID: display.uuid, type: .staticImage, imagePath: path)
        }

        return PreviousWallpaper(displayUUID: display.uuid, type: .unknown, imagePath: nil)
    }

    // MARK: - Read

    /// Reads `previous-wallpapers.json`. Returns `[]` if no capture exists.
    public func read() throws -> [PreviousWallpaper] {
        let url = try jsonURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PreviousWallpaper].self, from: data)
    }

    // MARK: - Restore

    /// Restores wallpapers per display.
    ///
    /// - For `.staticImage`: re-applies the saved path via `setDesktopImageURL`.
    /// - For `.dynamic` / `.unknown`: opens the Wallpaper settings pane via the
    ///   `x-apple.systempreferences` deep link **once** for the whole call (not
    ///   once per display — opening it N times has no benefit), and returns a
    ///   per-display result so the caller can name which displays need a manual
    ///   re-pick.
    ///
    /// Static-image restore failures are surfaced in the per-display action
    /// string rather than thrown, so one bad path doesn't block restoration on
    /// other displays.
    public func restore() throws -> [RestoreResult] {
        let entries = try read()
        var results: [RestoreResult] = []
        var deepLinkOpened = false
        let connectedDisplays = DisplayEnumerator.all()

        for entry in entries {
            switch entry.type {
            case .staticImage:
                if let path = entry.imagePath {
                    let filename = (path as NSString).lastPathComponent
                    if let display = connectedDisplays.first(where: { $0.uuid == entry.displayUUID }) {
                        do {
                            try setter.set(pngURL: URL(fileURLWithPath: path), on: display)
                            results.append(RestoreResult(
                                displayUUID: entry.displayUUID,
                                action: "restored \(filename)"
                            ))
                        } catch {
                            results.append(RestoreResult(
                                displayUUID: entry.displayUUID,
                                action: "failed to restore \(filename): \(error)"
                            ))
                        }
                    } else {
                        // Display not currently connected; nothing we can do.
                        results.append(RestoreResult(
                            displayUUID: entry.displayUUID,
                            action: "skipped \(filename) — display not connected"
                        ))
                    }
                } else {
                    results.append(RestoreResult(
                        displayUUID: entry.displayUUID,
                        action: "skipped — static entry missing image path"
                    ))
                }

            case .dynamic, .unknown:
                if !deepLinkOpened {
                    workspace.open(Self.wallpaperSettingsDeepLink)
                    deepLinkOpened = true
                }
                results.append(RestoreResult(
                    displayUUID: entry.displayUUID,
                    action: "opened Wallpaper settings — re-pick manually"
                ))
            }
        }

        return results
    }

    // MARK: - Clear

    /// Deletes `previous-wallpapers.json`. Used by `uninstall` after a
    /// successful restore. No-op if the file does not exist.
    public func clear() throws {
        let url = try jsonURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
