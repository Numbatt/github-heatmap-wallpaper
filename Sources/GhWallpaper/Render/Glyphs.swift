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
    /// Standard pixel-font model: each letter is a 6×7 grid (except `I` which
    /// is 1×7 per the reference) where filled cells (`#`) form the letter
    /// shape exactly the way a chunky sans-serif letter would when pixelated
    /// at low resolution.
    private static let sources: [Character: String] = [

        "D": """
        #####.
        #....#
        #....#
        #....#
        #....#
        #....#
        #####.
        """,

        "E": """
        ######
        #.....
        #.....
        #####.
        #.....
        #.....
        ######
        """,

        "S": """
        .#####
        #.....
        #.....
        .####.
        .....#
        .....#
        #####.
        """,

        "I": """
        #
        #
        #
        #
        #
        #
        #
        """,

        "G": """
        .####.
        #....#
        #.....
        #..###
        #....#
        #....#
        .####.
        """,

        "N": """
        #....#
        ##...#
        #.#..#
        #..#.#
        #...##
        #....#
        #....#
        """,

        "B": """
        #####.
        #....#
        #....#
        #####.
        #....#
        #....#
        #####.
        """,

        "U": """
        #....#
        #....#
        #....#
        #....#
        #....#
        #....#
        .####.
        """,

        "L": """
        #.....
        #.....
        #.....
        #.....
        #.....
        #.....
        ######
        """,

        "H": """
        #....#
        #....#
        #....#
        ######
        #....#
        #....#
        #....#
        """,

        "P": """
        #####.
        #....#
        #....#
        #####.
        #.....
        #.....
        #.....
        """,

        ".": """
        ..
        ..
        ..
        ..
        ..
        ..
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
