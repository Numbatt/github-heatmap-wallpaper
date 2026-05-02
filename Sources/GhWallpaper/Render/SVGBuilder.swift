import Foundation

/// Composes the wallpaper SVG from contribution data + theme + canvas geometry.
///
/// FROZEN INTERFACE — Wave 2 Stream B replaces the placeholder `<text>` headline
/// with the rectangle-letterform composer; the `build(...)` signature stays.
public struct SVGBuilder: Sendable {
    public struct Canvas: Equatable, Hashable, Sendable {
        public let widthPx: Int
        public let heightPx: Int
        public init(widthPx: Int, heightPx: Int) {
            self.widthPx = widthPx
            self.heightPx = heightPx
        }
    }

    public init() {}

    public func build(
        calendar: ContributionCalendar,
        theme: Theme,
        canvas: Canvas
    ) -> String {
        let w = Double(canvas.widthPx)
        let h = Double(canvas.heightPx)

        // Headline sizing rule (SPEC §8): 12% of short edge, capped.
        let headlineHeight = min(0.12 * min(w, h), 600)

        // Layout zones:
        //   top margin   ~10% h
        //   headline     headlineHeight
        //   gap          headlineHeight * 0.4
        //   heatmap      ~60% w wide, fills available
        //   bottom margin ~25% h
        let topMargin = h * 0.10
        let headlineY = topMargin
        let heatmapTop = headlineY + headlineHeight + headlineHeight * 0.4
        let heatmapWidth = w * 0.60
        let heatmapCenterX = w / 2

        // Heatmap layout
        let layout = HeatmapLayout(
            days: calendar.days,
            targetWidth: heatmapWidth,
            centerX: heatmapCenterX,
            topY: heatmapTop
        )

        // Compose SVG
        var svg = ""
        svg += #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        svg += #"<svg xmlns="http://www.w3.org/2000/svg" "#
        svg += "width=\"\(canvas.widthPx)\" height=\"\(canvas.heightPx)\" "
        svg += "viewBox=\"0 0 \(canvas.widthPx) \(canvas.heightPx)\">\n"

        // Optional gradient defs (themes like `midnight` use this).
        if let gradient = theme.gradientSVG {
            svg += "  <defs>\n    \(gradient)\n  </defs>\n"
        }

        // Background
        svg += #"  <rect x="0" y="0" width="100%" height="100%" fill="\#(theme.background)"/>"# + "\n"

        // Headline — hand-designed rectangle letterforms (Wave 2 Stream B).
        let headlineText = "DESIGN.  BUILD.  SHIP."
        svg += renderHeadline(
            text: headlineText,
            color: theme.headlineColor,
            centerX: w / 2,
            topY: headlineY,
            targetHeight: headlineHeight
        )

        // Heatmap cells
        let radius = layout.cells.first.map { $0.width * 0.25 } ?? 0
        for cell in layout.cells {
            if cell.level < 0 {
                // Transparent placeholder — skip rendering entirely.
                continue
            }
            let fill = theme.cellRamp[cell.level]
            svg += #"  <rect x="\#(round3(cell.x))" y="\#(round3(cell.y))" "#
            svg += #"width="\#(round3(cell.width))" height="\#(round3(cell.height))" "#
            svg += #"rx="\#(round3(radius))" ry="\#(round3(radius))" "#
            svg += #"fill="\#(fill)"/>"# + "\n"
        }

        svg += "</svg>\n"
        return svg
    }

    private func round3(_ v: Double) -> String {
        return String(format: "%.3f", v)
    }
}
