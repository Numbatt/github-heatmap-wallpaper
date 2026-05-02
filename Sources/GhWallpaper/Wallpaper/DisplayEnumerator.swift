import AppKit
import CoreGraphics
import Foundation

/// One connected display. v0.1 only uses the main display (M1); Wave 3 wires
/// per-display rendering.
public struct DisplayInfo: Equatable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let uuid: String
    public let widthPx: Int
    public let heightPx: Int

    public init(displayID: CGDirectDisplayID, uuid: String, widthPx: Int, heightPx: Int) {
        self.displayID = displayID
        self.uuid = uuid
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

public enum DisplayEnumerator {
    /// Returns the main display's info at native pixel resolution.
    public static func main() -> DisplayInfo? {
        guard let screen = NSScreen.main else { return nil }
        return info(for: screen)
    }

    /// All connected displays. Wave 3 will use this.
    public static func all() -> [DisplayInfo] {
        return NSScreen.screens.compactMap { info(for: $0) }
    }

    private static func info(for screen: NSScreen) -> DisplayInfo? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let scale = screen.backingScaleFactor
        let widthPx = Int(screen.frame.width * scale)
        let heightPx = Int(screen.frame.height * scale)
        let uuid = displayUUID(for: displayID) ?? "display-\(displayID)"
        return DisplayInfo(displayID: displayID, uuid: uuid, widthPx: widthPx, heightPx: heightPx)
    }

    private static func displayUUID(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        guard let cfStr = CFUUIDCreateString(nil, cfUUID) else { return nil }
        return cfStr as String
    }
}
