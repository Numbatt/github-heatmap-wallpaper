#if os(macOS)
import AppKit
import Foundation

public enum WallpaperSetterError: Error, CustomStringConvertible {
    case screenNotFound(displayID: CGDirectDisplayID)
    case setFailed(Error)

    public var description: String {
        switch self {
        case .screenNotFound(let id): return "no NSScreen found for display \(id)"
        case .setFailed(let e):       return "setDesktopImageURL failed: \(e.localizedDescription)"
        }
    }
}

public struct WallpaperSetter {
    public init() {}

    /// Sets the wallpaper on the screen matching `display.displayID`.
    public func set(pngURL: URL, on display: DisplayInfo) throws {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }) else {
            throw WallpaperSetterError.screenNotFound(displayID: display.displayID)
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(pngURL, for: screen, options: [:])
        } catch {
            throw WallpaperSetterError.setFailed(error)
        }
    }

    /// Returns the URL of the current wallpaper for a screen, if any.
    /// Used by `CaptureRestore` to snapshot the prior wallpaper before
    /// the daemon overwrites it.
    public func currentURL(for display: DisplayInfo) -> URL? {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }) else {
            return nil
        }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Ping-pong wallpaper filename for a display: whichever of the two stable
    /// slots ("-a"/"-b") is NOT currently set. Picking a slot that differs from
    /// the current one dodges macOS's same-path no-op (it caches the desktop
    /// image by path), while capping macOS's "Your Photos" wallpaper history at
    /// two entries per display. The old unique-timestamp-per-render scheme grew
    /// that history without bound — macOS's image-wallpaper extension cached a
    /// full copy of every distinct path forever (hundreds of orphaned
    /// thumbnails, ~1 GB over months). Shared by the daemon, the wizard, and the
    /// `refresh`/theme-apply CLI path so all render sites stay consistent.
    public func nextWallpaperName(for display: DisplayInfo) -> String {
        let current = currentURL(for: display)?.lastPathComponent
        let slot = current == "wallpaper-\(display.uuid)-a.png" ? "b" : "a"
        return "wallpaper-\(display.uuid)-\(slot).png"
    }
}
#endif
