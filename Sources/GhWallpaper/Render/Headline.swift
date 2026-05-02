import Foundation

/// Renders the headline text as a stitched-together stream of SVG `<rect>`
/// elements built from the hand-designed glyphs in `Glyphs`. No fonts.
///
/// The caller owns the sizing rule (12% of short edge, capped at 600pt) and
/// passes us the resolved `targetHeight`. We scale the 7-row glyph grid so the
/// total glyph block stands exactly `targetHeight` tall, then center it
/// horizontally at `centerX`.
///
/// Returns SVG markup (no `<svg>` wrapper) — drop it directly into a parent SVG.
func renderHeadline(
    text: String,
    color: String,
    centerX: Double,
    topY: Double,
    targetHeight: Double
) -> String {
    // Tracking constants, in grid columns.
    let letterGap = 1   // tight kerning between adjacent letters
    let wordGap   = 3   // wider gap on space (visually ~2× a normal letter gap)

    // 1. Compute total glyph-grid width in columns for the whole text.
    var totalCols = 0
    var prevWasLetter = false
    for ch in text {
        if ch == " " {
            totalCols += wordGap
            prevWasLetter = false
            continue
        }
        if prevWasLetter {
            totalCols += letterGap
        }
        totalCols += Glyphs.letterAdvance(for: ch)
        prevWasLetter = true
    }

    // 2. Compute the unit size: every grid cell is `unit` points square.
    //    The headline is 7 rows tall; that locks the unit.
    let unit = targetHeight / Double(Glyphs.rows)
    let totalWidth = Double(totalCols) * unit

    // 3. Position cursor at the left edge of the centered block.
    var cursorCols = 0
    let originX = centerX - totalWidth / 2
    let originY = topY

    // 4. Emit rects.
    var svg = ""
    prevWasLetter = false
    for ch in text {
        if ch == " " {
            cursorCols += wordGap
            prevWasLetter = false
            continue
        }
        if prevWasLetter {
            cursorCols += letterGap
        }
        if let rects = Glyphs.glyph(for: ch) {
            for r in rects {
                let x = originX + Double(cursorCols + r.x) * unit
                let y = originY + Double(r.y) * unit
                let w = Double(r.w) * unit
                let h = Double(r.h) * unit
                svg += #"  <rect x="\#(fmt(x))" y="\#(fmt(y))" "#
                svg += #"width="\#(fmt(w))" height="\#(fmt(h))" "#
                svg += #"fill="\#(color)" shape-rendering="crispEdges"/>"# + "\n"
            }
        }
        cursorCols += Glyphs.letterAdvance(for: ch)
        prevWasLetter = true
    }
    return svg
}

private func fmt(_ v: Double) -> String {
    return String(format: "%.3f", v)
}
