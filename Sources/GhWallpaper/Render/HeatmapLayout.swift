import Foundation

/// Computes the grid layout for the contribution heatmap given a target canvas
/// size and the contribution days. Pure function: no I/O, deterministic.
///
/// GitHub's grid is up to 53 columns × 7 rows aligned to weeks (Sunday → Saturday).
/// Cells outside the actual contribution window (the partial first/last week)
/// render fully transparent — they exist as grid placeholders only.
public struct HeatmapLayout {
    public struct Cell: Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let level: Int   // -1 means "transparent placeholder"
    }

    public let cells: [Cell]
    public let originX: Double
    public let originY: Double
    public let totalWidth: Double
    public let totalHeight: Double

    /// - Parameters:
    ///   - days: chronologically-sorted contribution days
    ///   - targetWidth: total width the heatmap should occupy in points
    ///   - centerX: x-coordinate where the heatmap should be horizontally centered
    ///   - topY: y-coordinate of the heatmap's top edge
    public init(
        days: [ContributionDay],
        targetWidth: Double,
        centerX: Double,
        topY: Double
    ) {
        // GitHub returns exactly 53 weeks × 7 days = 371 cells, ordered Sun→Sat
        // chronologically (the parser sorts by ISO date ascending). We lay them
        // out directly in column-major order: days[0] at (col=0, row=0),
        // days[1] at (col=0, row=1), ..., days[7] at (col=1, row=0), etc.
        //
        // No date arithmetic. No timezone-sensitive Calendar operations. The
        // weekday of each cell is determined purely by its index, which avoids
        // a class of off-by-one bugs that depended on the user's local TZ vs
        // the UTC midnight Date the parser produced from "YYYY-MM-DD" strings.
        let rows = 7
        let columns = max(1, Int((Double(days.count) / Double(rows)).rounded(.up)))

        let cellWidth = targetWidth / (Double(columns) + Double(columns - 1) * 0.25)
        let gap = cellWidth * 0.25
        let cellHeight = cellWidth
        let totalHeight = Double(rows) * cellHeight + Double(rows - 1) * gap
        let totalWidth = targetWidth

        let originX = centerX - totalWidth / 2
        let originY = topY

        var cells: [Cell] = []
        cells.reserveCapacity(columns * rows)

        for (i, day) in days.enumerated() {
            let col = i / rows
            let row = i % rows
            guard col < columns else { break }
            let x = originX + Double(col) * (cellWidth + gap)
            let y = originY + Double(row) * (cellHeight + gap)
            cells.append(Cell(x: x, y: y, width: cellWidth, height: cellHeight, level: day.level))
        }

        self.cells = cells
        self.originX = originX
        self.originY = originY
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
    }
}
