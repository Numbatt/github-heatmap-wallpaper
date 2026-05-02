import Foundation

/// Hand-designed rectangle-pixel letterforms for the headline `DESIGN.  BUILD.  SHIP.`
///
/// Each glyph is authored as an ASCII grid. `#` = filled cell, `.` (or space)
/// = empty. Each line of the source string is one row of the glyph (top to
/// bottom). The number of rows must equal `Glyphs.rows` (7). The number of
/// columns is determined per-glyph by the longest line in that glyph's source.
///
/// ## Visual reference
///
/// Match `image-1.png` in the repo root. The reference uses segmented bars
/// (visible breaks every few cells) rather than solid bars. To re-tune any
/// letter, just edit its string below — the parser regenerates the rect data
/// at the next build. No tooling required.
///
/// ## Authoring tips
///
/// - Keep all rows the same length (pad with `.`) — easier to read at a glance.
/// - 9 columns ≈ the width that matches `image-1.png`. Narrower letters (`I`,
///   `.`) can be fewer columns.
/// - Adjacent `#` cells in the same row collapse into one wider rectangle at
///   parse time, so `####` and `# ##` produce visually different output even
///   if they fill the same total cells.
enum Glyphs {

    public typealias Rect = (x: Int, y: Int, w: Int, h: Int)

    /// Glyph height in grid rows. Always 7.
    public static let rows: Int = 7

    /// ASCII grid sources for each glyph. Edit these strings to redesign any
    /// letter. Re-build to apply.
    private static let sources: [Character: String] = [

        // D — segmented top/bottom bars, paired side rails.
        "D": """
        ###.###.#
        ##.....##
        ##.....##
        #.......#
        ##.....##
        ##.....##
        ###.###.#
        """,

        // E — three segmented horizontal bars, left rail only.
        "E": """
        ###.###.#
        ##.......
        ##.......
        ###.##...
        ##.......
        ##.......
        ###.###.#
        """,

        // S — segmented top, top-left rail, segmented middle, bottom-right
        // rail, segmented bottom. Classic S diagonal.
        "S": """
        ###.###.#
        ##.......
        ##.......
        ###.###.#
        .......##
        .......##
        ###.###.#
        """,

        // I — narrow letter, segmented top + bottom, single-cell stem.
        "I": """
        ###
        .#.
        .#.
        .#.
        .#.
        .#.
        ###
        """,

        // G — like C with a horizontal tongue mid-right.
        "G": """
        ###.###.#
        ##.......
        ##.......
        ##...###.
        ##.....##
        ##.....##
        ###.###.#
        """,

        // N — both side rails full height; a diagonal stagger of mid blocks
        // suggests the slanting stroke.
        "N": """
        ##.....##
        ##.....##
        ##.#...##
        ##.#...##
        ##...#.##
        ##...#.##
        ##.....##
        """,

        // B — segmented top, segmented middle, segmented bottom; both rails.
        "B": """
        ###.###..
        ##.....##
        ##.....##
        ###.###..
        ##.....##
        ##.....##
        ###.###..
        """,

        // U — both rails full height, segmented bottom only.
        "U": """
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ##.....##
        ###.###.#
        """,

        // L — left rail only, segmented bottom.
        "L": """
        ##.......
        ##.......
        ##.......
        ##.......
        ##.......
        ##.......
        ###.###.#
        """,

        // H — both rails full height, segmented middle bar.
        "H": """
        ##.....##
        ##.....##
        ##.....##
        ###.###.#
        ##.....##
        ##.....##
        ##.....##
        """,

        // P — segmented top, both top rails, segmented mid, left rail bottom.
        "P": """
        ###.###..
        ##.....##
        ##.....##
        ###.###..
        ##.......
        ##.......
        ##.......
        """,

        // . (period) — small block on the baseline.
        ".": """
        .....
        .....
        .....
        .....
        .....
        .....
        ##...
        """,
    ]

    // MARK: - Public API

    /// Returns the rect data for a character, or nil if unsupported.
    public static func glyph(for ch: Character) -> [Rect]? {
        if let cached = cache[ch] { return cached }
        guard let src = sources[ch] else { return nil }
        let rects = parse(source: src)
        cache[ch] = rects
        return rects
    }

    /// Returns the column-advance (width in grid columns) for a character.
    /// Used by the headline composer to position subsequent letters.
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

    /// Converts an ASCII grid source into a coalesced list of rectangles.
    /// Adjacent `#` cells in the same row are merged into a single wider
    /// rectangle (so a `####` row becomes one rect, not four). Vertical
    /// merging is intentionally NOT done — the segment-display aesthetic
    /// depends on visible row boundaries.
    private static func parse(source: String) -> [Rect] {
        var rects: [Rect] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (rowIdx, line) in lines.enumerated() {
            let chars = Array(line)
            var col = 0
            while col < chars.count {
                if chars[col] == "#" {
                    var run = 1
                    while col + run < chars.count && chars[col + run] == "#" {
                        run += 1
                    }
                    rects.append((x: col, y: rowIdx, w: run, h: 1))
                    col += run
                } else {
                    col += 1
                }
            }
        }
        return rects
    }

    private static var cache: [Character: [Rect]] = [:]
    private static var advanceCache: [Character: Int] = [:]
}
