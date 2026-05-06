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
}
#endif
