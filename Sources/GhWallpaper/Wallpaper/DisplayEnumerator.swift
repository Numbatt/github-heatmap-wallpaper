import AppKit
import CoreGraphics
import Foundation

/// One connected display.
public struct DisplayInfo: Equatable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let uuid: String
    public let widthPx: Int
    public let heightPx: Int
    public let isMain: Bool

    public init(
        displayID: CGDirectDisplayID,
        uuid: String,
        widthPx: Int,
        heightPx: Int,
        isMain: Bool = false
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.isMain = isMain
    }
}

public enum DisplayEnumerator {
    /// Returns the main display's info at native pixel resolution.
    public static func main() -> DisplayInfo? {
        guard let screen = NSScreen.main else { return nil }
        return info(for: screen, mainID: CGMainDisplayID())
    }

    /// All connected displays.
    public static func all() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { info(for: $0, mainID: mainID) }
    }

    private static func info(for screen: NSScreen, mainID: CGDirectDisplayID) -> DisplayInfo? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let scale = screen.backingScaleFactor
        let widthPx = Int(screen.frame.width * scale)
        let heightPx = Int(screen.frame.height * scale)
        let uuid = displayUUID(for: displayID) ?? "display-\(displayID)"
        return DisplayInfo(
            displayID: displayID,
            uuid: uuid,
            widthPx: widthPx,
            heightPx: heightPx,
            isMain: displayID == mainID
        )
    }

    private static func displayUUID(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        guard let cfStr = CFUUIDCreateString(nil, cfUUID) else { return nil }
        return cfStr as String
    }
}
