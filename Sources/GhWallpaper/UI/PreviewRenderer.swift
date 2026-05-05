import AppKit
import Foundation

/// Live-preview helper for the theme editor. Wraps the production
/// `SVGBuilder` + `Rasterizer` pipeline so the preview view sees the same
/// output the daemon would render — no parallel implementation.
///
/// Renders to a temp PNG and loads it as an `NSImage`. Synchronous; the
/// caller debounces drag events upstream (see `ThemeEditor.swift`).
public struct PreviewRenderer {
    /// Default preview canvas — keeps rasterization snappy. Aspect matches
    /// the 14" MBP retina canvas (2880×1800) at half scale.
    public static let defaultCanvas = SVGBuilder.Canvas(widthPx: 1440, heightPx: 900)

    private let builder = SVGBuilder()
    private let rasterizer: Rasterizer
    private let calendar: ContributionCalendar

    public init(calendar: ContributionCalendar? = nil) throws {
        self.rasterizer = try Rasterizer()
        self.calendar = calendar ?? Self.syntheticCalendar()
    }

    public func render(theme: Theme, canvas: SVGBuilder.Canvas = PreviewRenderer.defaultCanvas) throws -> NSImage {
        let data = try renderPNGData(theme: theme, canvas: canvas)
        guard let image = Self.imageFromPNG(data: data) else {
            throw RasterizerError.ioError("could not decode preview PNG")
        }
        return image
    }

    /// Background-safe step: build SVG → spawn resvg → read PNG bytes.
    /// Returns the raw PNG `Data`. Doesn't touch any AppKit types, so
    /// callers can run this from `Task.detached` without crossing the
    /// main-actor boundary with non-Sendable AppKit objects.
    public func renderPNGData(theme: Theme, canvas: SVGBuilder.Canvas = PreviewRenderer.defaultCanvas) throws -> Data {
        let svg = builder.build(calendar: calendar, theme: theme, canvas: canvas)
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-wallpaper-preview-\(UUID().uuidString).png")
        try rasterizer.rasterize(
            svg: svg,
            toPNG: pngURL,
            widthPx: canvas.widthPx,
            heightPx: canvas.heightPx
        )
        defer { try? FileManager.default.removeItem(at: pngURL) }
        do {
            return try Data(contentsOf: pngURL)
        } catch {
            throw RasterizerError.ioError("could not read preview PNG: \(error.localizedDescription)")
        }
    }

    /// Main-thread-safe NSImage construction. Goes through `NSBitmapImageRep`
    /// to force eager pixel decoding — `NSImage(data:)` alone can return an
    /// image whose representation is lazy enough that SwiftUI's
    /// `Image(nsImage:)` shows nothing on first draw. Wrapping the bitmap
    /// rep in a fresh NSImage guarantees the bytes are decoded and bound.
    public static func imageFromPNG(data: Data) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        return image
    }

    /// Generates a 53×7 calendar with a plausible activity pattern so the
    /// preview shows variation across all 5 ramp levels — without hitting
    /// the network or requiring the user to have a config.
    private static func syntheticCalendar() -> ContributionCalendar {
        var days: [ContributionDay] = []
        let cal = Calendar(identifier: .gregorian)
        let endDate = Date()
        let totalDays = 53 * 7
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for offset in (0..<totalDays).reversed() {
            guard let date = cal.date(byAdding: .day, value: -offset, to: endDate) else { continue }
            // Smooth "real-looking" activity: weekdays brighter than weekends,
            // with a sinusoidal seasonal trend so the wallpaper has texture
            // across all 5 levels.
            let weekday = cal.component(.weekday, from: date)
            let isWeekend = (weekday == 1 || weekday == 7)
            let phase = Double(offset) / Double(totalDays) * .pi * 2
            let seasonal = (sin(phase) + 1) / 2  // 0…1
            var level = Int(seasonal * 4.5)       // 0…4
            if isWeekend { level = max(0, level - 2) }
            // Pepper a few peaks + a few empties so the ramp is exercised.
            if offset % 23 == 0 { level = 4 }
            if offset % 31 == 0 { level = 0 }
            level = max(0, min(4, level))
            days.append(ContributionDay(date: date, level: level, isoDate: formatter.string(from: date)))
        }
        return ContributionCalendar(username: "preview", days: days)
    }
}
