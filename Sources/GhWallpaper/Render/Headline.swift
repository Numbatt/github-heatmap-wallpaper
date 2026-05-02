import Foundation

/// Renders the headline text as a stitched-together stream of SVG `<rect>`
/// elements built from the hand-designed glyphs in `Glyphs`. No fonts.
///
/// Sizing: the caller passes `targetHeight` (the desired height in points if it
/// fits) and `maxWidth` (a hard width cap — typically `0.73 × canvas_width`).
/// We scale the 7-row glyph grid so the headline stands `targetHeight` tall
/// **unless** that produces a width > `maxWidth`, in which case we shrink down
/// so the headline fits. Returns the actual rendered height in `actualHeight`
/// so the caller can lay out subsequent elements correctly.
///
/// Returns SVG markup (no `<svg>` wrapper) — drop it directly into a parent SVG.
@discardableResult
func renderHeadline(
    text: String,
    color: String,
    centerX: Double,
    topY: Double,
    targetHeight: Double,
    maxWidth: Double,
    actualHeight: inout Double
) -> String {
    // Tracking constants, in grid columns.
    let letterGap = 1
    let wordGap   = 3

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

    // 2. Compute unit size constrained by both height and width.
    let unitFromHeight = targetHeight / Double(Glyphs.rows)
    let unitFromWidth  = maxWidth / Double(totalCols)
    let unit = min(unitFromHeight, unitFromWidth)
    let totalWidth = Double(totalCols) * unit
    actualHeight = unit * Double(Glyphs.rows)

    // 3. Position cursor at the left edge of the centered block.
    var cursorCols = 0
    let originX = centerX - totalWidth / 2
    let originY = topY

    // Vertical inset only: rows render shorter than their cell height, leaving
    // a thin background gap above and below each row. Horizontal inset is 0
    // so adjacent `#` cells in the same row still merge into one continuous
    // bar (the parser coalesces, the renderer doesn't break the merge).
    //
    // Result: stacked rows in the same column visibly separate (the
    // "small gaps between the lines" effect from image-1.png), while a row
    // of #### remains a solid bar.
    let rowInset = 0.10  // 10% on each side vertically = 80% rect height, 20% gap

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
                let y = originY + Double(r.y) * unit + rowInset * unit
                let w = Double(r.w) * unit
                let h = Double(r.h) * unit - 2 * rowInset * unit
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
