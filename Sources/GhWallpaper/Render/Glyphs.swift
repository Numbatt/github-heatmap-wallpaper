import Foundation

/// Hand-designed rectangle-pixel letterforms for the headline `DESIGN.  BUILD.  SHIP.`
///
/// Each glyph is a list of `(x, y, w, h)` rectangles laid out on a fixed 7-row grid.
/// The glyph's column count is what `letterAdvance(for:)` returns — the Headline
/// composer uses it to position the next letter.
///
/// Visual model (matches `image-1.png`):
///
///   row 0       ▄▄▄▄▄        top bar
///   row 1       █   █        upper-side rails (single-cell blocks)
///   row 2       █   █        upper-side rails (second tier)
///   row 3       ▄▄▄▄▄        middle bar
///   row 4       █   █        lower-side rails
///   row 5       █   █        lower-side rails (second tier)
///   row 6       ▄▄▄▄▄        bottom bar
///
/// Bars are 1 row tall; side rails are 1×1 blocks. Two stacked rails (rows 1+2 or
/// rows 4+5) read as a "vertical stem" with a hairline gap — which is the
/// segment-display look the spec calls for.
///
/// Pure data — no logic in this file.
enum Glyphs {

    /// `(x, y, width, height)` rectangle on the 7-row glyph grid.
    /// Coordinates are integers in grid columns/rows.
    typealias Rect = (x: Int, y: Int, w: Int, h: Int)

    /// Glyph height in grid rows. Always 7.
    static let rows: Int = 7

    // MARK: - Letterforms (5 cols × 7 rows unless noted)

    /// `D` — full top + bottom bars, partial middle bar, both side rails.
    static let D: [Rect] = [
        // top bar
        (0, 0, 5, 1),
        // upper rails
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (4, 2, 1, 1),
        // middle bar (partial — the inner "belly" line)
        (0, 3, 4, 1),
        // lower rails
        (0, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        // bottom bar
        (0, 6, 5, 1),
    ]

    /// `E` — three bars, left rail only.
    static let E: [Rect] = [
        (0, 0, 5, 1),
        (0, 1, 1, 1),
        (0, 2, 1, 1),
        (0, 3, 4, 1),
        (0, 4, 1, 1),
        (0, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `S` — three bars, top-left rail, bottom-right rail.
    static let S: [Rect] = [
        (0, 0, 5, 1),
        // top half: rail on left only
        (0, 1, 1, 1),
        (0, 2, 1, 1),
        (0, 3, 5, 1),
        // bottom half: rail on right only
        (4, 4, 1, 1),
        (4, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `I` — narrow letter, three bars only, 3 cols wide.
    static let I: [Rect] = [
        (0, 0, 3, 1),
        (1, 1, 1, 1),
        (1, 2, 1, 1),
        (0, 3, 3, 1),
        (1, 4, 1, 1),
        (1, 5, 1, 1),
        (0, 6, 3, 1),
    ]

    /// `G` — like C but with an inward-poking middle-right block.
    static let G: [Rect] = [
        (0, 0, 5, 1),
        (0, 1, 1, 1),
        (0, 2, 1, 1),
        // middle bar — only on the right half (the "G" tongue)
        (2, 3, 3, 1),
        (0, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `N` — both side rails full height; the diagonal is suggested by mid-row
    /// blocks staggered between the rails.
    static let N: [Rect] = [
        // top: only the corner caps (left and right) — no top bar across the whole.
        (0, 0, 2, 1), (3, 0, 2, 1),
        // upper inner staircase
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (2, 2, 1, 1), (4, 2, 1, 1),
        // mid: diagonal block in the middle
        (0, 3, 1, 1), (2, 3, 1, 1), (4, 3, 1, 1),
        // lower inner staircase
        (0, 4, 1, 1), (2, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        // bottom: corner caps
        (0, 6, 2, 1), (3, 6, 2, 1),
    ]

    /// `.` (period) — small square block sitting on the baseline, wider than tall.
    /// 2 cols wide.
    static let PERIOD: [Rect] = [
        (0, 5, 2, 1),
        (0, 6, 2, 1),
    ]

    /// `B` — full top, full middle, full bottom bar; rails on left and right.
    static let B: [Rect] = [
        (0, 0, 5, 1),
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (4, 2, 1, 1),
        (0, 3, 5, 1),
        (0, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `U` — both side rails, no top bar, full bottom bar.
    static let U: [Rect] = [
        // No top bar
        (0, 0, 1, 1), (4, 0, 1, 1),
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (4, 2, 1, 1),
        (0, 3, 1, 1), (4, 3, 1, 1),
        (0, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `L` — left rail full height, full bottom bar.
    static let L: [Rect] = [
        (0, 0, 1, 1),
        (0, 1, 1, 1),
        (0, 2, 1, 1),
        (0, 3, 1, 1),
        (0, 4, 1, 1),
        (0, 5, 1, 1),
        (0, 6, 5, 1),
    ]

    /// `H` — both side rails full height plus a middle bar.
    static let H: [Rect] = [
        (0, 0, 1, 1), (4, 0, 1, 1),
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (4, 2, 1, 1),
        (0, 3, 5, 1),
        (0, 4, 1, 1), (4, 4, 1, 1),
        (0, 5, 1, 1), (4, 5, 1, 1),
        (0, 6, 1, 1), (4, 6, 1, 1),
    ]

    /// `P` — top bar, both upper rails, middle bar, left lower rails only.
    static let P: [Rect] = [
        (0, 0, 5, 1),
        (0, 1, 1, 1), (4, 1, 1, 1),
        (0, 2, 1, 1), (4, 2, 1, 1),
        (0, 3, 5, 1),
        (0, 4, 1, 1),
        (0, 5, 1, 1),
        (0, 6, 1, 1),
    ]

    // MARK: - Lookup

    /// Returns the glyph rectangles for a given character, or `nil` if undefined.
    static func glyph(for char: Character) -> [Rect]? {
        switch char {
        case "D": return D
        case "E": return E
        case "S": return S
        case "I": return I
        case "G": return G
        case "N": return N
        case "B": return B
        case "U": return U
        case "L": return L
        case "H": return H
        case "P": return P
        case ".": return PERIOD
        default:  return nil
        }
    }

    /// Returns the glyph's advance width (in grid columns) for the composer's
    /// horizontal cursor. Includes the glyph's own width but no inter-letter gap.
    static func letterAdvance(for char: Character) -> Int {
        switch char {
        case "I": return 3
        case ".": return 2
        case " ": return 0   // word space handled by the composer, not here
        default:  return 5
        }
    }
}
