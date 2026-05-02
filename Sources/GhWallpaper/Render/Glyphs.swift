import Foundation

/// Hand-designed rectangle-pixel letterforms for the headline `DESIGN.  BUILD.  SHIP.`
///
/// Each glyph is authored as an ASCII grid. `#` = filled cell, `.` (or space)
/// = empty. Each line of the source string is one row of the glyph (top to
/// bottom). Number of rows must equal `Glyphs.rows` (7). Number of columns
/// is determined per-glyph by the longest line.
///
/// ## Visual reference
///
/// Match `image-1.png` in the repo root. The reference uses **segmented bars**
/// (visible breaks every few cells) and 2-cell-wide side rails. The standard
/// segmentation pattern is `##.###.##` — symmetric, two 1-cell gaps splitting
/// the bar into 2-3-2 segments. Side rails are `##.....##` — paired blocks
/// flush left and flush right, 2 cells wide each.
///
/// ## Authoring
///
/// To re-tune any letter, just edit its string below and rebuild. Adjacent
/// `#` cells in the same row coalesce into one wider `<rect>`; the parser
/// never merges across rows, so segment boundaries are preserved by design.
enum Glyphs {

    public typealias Rect = (x: Int, y: Int, w: Int, h: Int)

    /// Glyph height in grid rows. Always 7.
    public static let rows: Int = 7

    /// ASCII grid sources for each glyph. Edit these strings to redesign any
    /// letter. Re-build to apply.
    ///
    /// Layout model (matches `image-1.png`):
    ///   - 9 columns × 7 rows per letter (1 column for `I`).
    ///   - Top/bottom bars are split into 3 segments by 2 single-cell gaps
    ///     (`##.###.##`). The bar's end-segments sit in cols 0-1 and 7-8.
    ///   - Side rails are paired blocks (`##.....##`) in cols 0-1 and 7-8 —
    ///     the SAME columns as the bar end-segments — so the rails extend
    ///     vertically from the bars without offset (the "curve overlap").
    ///   - A thin background gap is rendered between rows (see Headline.swift)
    ///     so each rail block reads as a discrete chunk rather than a
    ///     continuous vertical stem.
    private static let sources: [Character: String] = [

        // D — continuous top + bottom bars; both rails full height; no middle.
        "D": """
        #########
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        #########
        """,

        // E — three continuous bars + left rail only. Middle bar is shorter.
        "E": """
        #########
        ##.......
        ##.......
        ######...
        ##.......
        ##.......
        #########
        """,

        // S — three continuous bars; top-left rail; bottom-right rail.
        "S": """
        #########
        ##.......
        ##.......
        #########
        .......##
        .......##
        #########
        """,

        // I — single column, full height.
        "I": """
        #
        #
        #
        #
        #
        #
        #
        """,

        // G — like C with a horizontal tongue mid-right.
        "G": """
        #########
        ##.......
        ##.......
        ##...####
        ##.....##
        ##.....##
        #########
        """,

        // N — both rails + diagonal staircase between them.
        "N": """
        ##.....##
        ###....##
        ##.#...##
        ##..#..##
        ##...#.##
        ##....###
        ##.....##
        """,

        // B — three continuous bars + both rails.
        "B": """
        #########
        ##.....##
        ##.....##
        #########
        ##.....##
        ##.....##
        #########
        """,

        // U — both rails + continuous bottom bar (no top bar).
        "U": """
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        #########
        """,

        // L — left rail + continuous bottom bar.
        "L": """
        ##.......
        ##.......
        ##.......
        ##.......
        ##.......
        ##.......
        #########
        """,

        // H — both rails + continuous middle bar (no top/bottom bars).
        "H": """
        ##.....##
        ##.....##
        ##.....##
        #########
        ##.....##
        ##.....##
        ##.....##
        """,

        // P — top + middle bars; both rails on top half; left rail bottom.
        "P": """
        #########
        ##.....##
        ##.....##
        #########
        ##.......
        ##.......
        ##.......
        """,

        // . (period) — small block on the baseline.
        ".": """
        ..
        ..
        ..
        ..
        ..
        ##
        ##
        """,
    ]

    // MARK: - Public API

    public static func glyph(for ch: Character) -> [Rect]? {
        if let cached = cache[ch] { return cached }
        guard let src = sources[ch] else { return nil }
        let rects = parse(source: src)
        cache[ch] = rects
        return rects
    }

    public static func letterAdvance(for ch: Character) -> Int {
        if let cached = advanceCache[ch] { return cached }
        guard let src = sources[ch] else { return 0 }
        var maxLen = 0
        var current = 0
        for c in src {
            if c == "\n" {
                maxLen = max(maxLen, current)
                current = 0
            } else {
                current += 1
            }
        }
        maxLen = max(maxLen, current)
        advanceCache[ch] = maxLen
        return maxLen
    }

    // MARK: - Parser

    private static func parse(source: String) -> [Rect] {
        var rects: [Rect] = []
        var rowIdx = 0
        var col = 0
        var runStart = -1
        for c in source {
            if c == "\n" {
                if runStart >= 0 {
                    rects.append((x: runStart, y: rowIdx, w: col - runStart, h: 1))
                    runStart = -1
                }
                rowIdx += 1
                col = 0
                continue
            }
            if c == "#" {
                if runStart < 0 { runStart = col }
            } else {
                if runStart >= 0 {
                    rects.append((x: runStart, y: rowIdx, w: col - runStart, h: 1))
                    runStart = -1
                }
            }
            col += 1
        }
        if runStart >= 0 {
            rects.append((x: runStart, y: rowIdx, w: col - runStart, h: 1))
        }
        return rects
    }

    private static var cache: [Character: [Rect]] = [:]
    private static var advanceCache: [Character: Int] = [:]
}
