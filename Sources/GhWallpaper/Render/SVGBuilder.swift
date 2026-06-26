import Foundation

/// Composes the wallpaper SVG from contribution data + theme + canvas geometry.
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
        canvas: Canvas,
        headline: HeadlineOptions = .default
    ) -> String {
        let w = Double(canvas.widthPx)
        let h = Double(canvas.heightPx)

        // Sizing rules:
        //   Headline target height = 12% of short edge, capped at 600pt.
        //   Headline width is hard-capped at 73% of canvas width — if the
        //   intrinsic glyph width at target height would overflow, the
        //   headline scales down (Headline.swift handles the clamp). The
        //   headline cap is intentionally tighter than the heatmap so the
        //   heatmap reads as the dominant horizontal element.
        //   Heatmap fills 75% of canvas width; height follows from the 53×7 grid.
        //
        // Layout (rule of thirds, headline-dominant):
        //   - title baseline at h × 0.30
        //   - heatmap top at h × 0.55
        //   - balanced top/bottom margins
        let targetHeadlineHeight = min(0.12 * headline.resolvedSizeScale * min(w, h), 600)
        let maxHeadlineWidth = w * 0.73
        let heatmapWidth = w * 0.75
        let heatmapCenterX = w / 2
        let heatmapTop = h * 0.55

        // Position the headline so its bottom sits at h × 0.40 (above the heatmap).
        // We don't know actualHeight until renderHeadline runs (it might shrink
        // to fit width), so we anchor by the bottom edge.
        let headlineBottom = h * 0.40
        let headlineTopGuess = headlineBottom - targetHeadlineHeight

        // Heatmap layout — width-driven; cells are square so height follows.
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

        if let gradient = theme.gradientSVG {
            svg += "  <defs>\n    \(gradient)\n  </defs>\n"
        }

        svg += #"  <rect x="0" y="0" width="100%" height="100%" fill="\#(theme.background)"/>"# + "\n"

        // Image background (if set) draws on top of the solid/gradient fill,
        // then a translucent black overlay sits between the image and the
        // heatmap so the cells stay readable on busy photos. resvg renders
        // SVG <image> natively, but its loader silently rejects `file://`
        // URLs (logs `'…' is not a path to an image` and renders nothing).
        // Emit the plain absolute filesystem path instead — that's what
        // resvg actually accepts. CustomThemes.resolvedImagePath already
        // gives us an absolute path.
        if let imagePath = theme.backgroundImagePath, !imagePath.isEmpty {
            let escaped = escapeXMLAttribute(imagePath)
            svg += #"  <image href="\#(escaped)" "#
            svg += #"x="0" y="0" width="100%" height="100%" "#
            svg += #"preserveAspectRatio="xMidYMid slice"/>"# + "\n"
            let alpha = (theme.backgroundDimAlpha ?? 0.4).clamped01()
            if alpha > 0 {
                svg += #"  <rect x="0" y="0" width="100%" height="100%" "#
                svg += #"fill="rgba(0,0,0,\#(round3(alpha)))"/>"# + "\n"
            }
        }

        // Headline. Bottom anchor at h × 0.40 regardless of rendering mode.
        let headlineText = headline.resolvedText
        switch headline.resolvedFont {
        case .pixelGlyphs:
            // Two-pass pixel-glyph path: first pass measures actualHeight so we can
            // anchor the bottom edge precisely; second pass emits the SVG rects.
            var throwaway = 0.0
            _ = renderHeadline(
                text: headlineText,
                color: theme.headlineColor,
                centerX: heatmapCenterX,
                topY: headlineTopGuess,
                targetHeight: targetHeadlineHeight,
                maxWidth: maxHeadlineWidth,
                actualHeight: &throwaway
            )
            let headlineTop = headlineBottom - throwaway
            var unused = 0.0
            svg += renderHeadline(
                text: headlineText,
                color: theme.headlineColor,
                centerX: heatmapCenterX,
                topY: headlineTop,
                targetHeight: targetHeadlineHeight,
                maxWidth: maxHeadlineWidth,
                actualHeight: &unused
            )

        case .system(let family):
            // Single-pass SVG <text> path. resvg resolves font-family via fontdb.
            // No text-metrics callback from resvg, so we use headlineBottom directly
            // as the alphabetic baseline — close enough for all-caps display text.
            svg += renderSystemFontHeadline(
                text: headlineText,
                fontFamily: family,
                fontSize: targetHeadlineHeight,
                color: theme.headlineColor,
                centerX: heatmapCenterX,
                baselineY: headlineBottom
            )
        }

        // Heatmap cells.
        let radius = layout.cells.first.map { $0.width * 0.25 } ?? 0
        for cell in layout.cells {
            if cell.level < 0 { continue }
            let fill = theme.cellRamp[cell.level]
            svg += #"  <rect x="\#(round3(cell.x))" y="\#(round3(cell.y))" "#
            svg += #"width="\#(round3(cell.width))" height="\#(round3(cell.height))" "#
            svg += #"rx="\#(round3(radius))" ry="\#(round3(radius))" "#
            svg += #"fill="\#(fill)"/>"# + "\n"
        }

        svg += "</svg>\n"
        return svg
    }

    private func renderSystemFontHeadline(
        text: String,
        fontFamily: String,
        fontSize: Double,
        color: String,
        centerX: Double,
        baselineY: Double
    ) -> String {
        let escapedFamily = escapeXMLAttribute(fontFamily)
        let escapedText = escapeXMLAttribute(text)
        return "  <text"
            + " x=\"\(round3(centerX))\""
            + " y=\"\(round3(baselineY))\""
            + " font-family=\"\(escapedFamily)\""
            + " font-size=\"\(round3(fontSize))\""
            + " fill=\"\(color)\""
            + " text-anchor=\"middle\""
            + " dominant-baseline=\"alphabetic\""
            + ">\(escapedText)</text>\n"
    }

    private func round3(_ v: Double) -> String {
        // POSIX locale forces "." as the decimal separator on every platform.
        // swift-corelibs-foundation's String(format:) honors LC_NUMERIC, so a
        // German locale would emit "1,234" and produce invalid SVG.
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// Escapes characters that would break an XML attribute value.
    /// File paths can contain `&`, `<`, `>`, `"`; absolute paths from a
    /// trusted directory rarely do, but custom themes can be hand-edited.
    private func escapeXMLAttribute(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:   out.append(c)
            }
        }
        return out
    }
}

private extension Double {
    func clamped01() -> Double {
        return Swift.min(1.0, Swift.max(0.0, self))
    }
}
