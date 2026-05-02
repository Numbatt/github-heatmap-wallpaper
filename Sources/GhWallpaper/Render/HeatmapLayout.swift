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
        // GitHub's heatmap is 53 columns × 7 rows max. We always lay out 53×7 cells;
        // those that fall outside the day range render at level -1 (transparent).
        let columns = 53
        let rows = 7

        // Determine the date of the cell at column 0, row 0 (a Sunday).
        // It is the Sunday on or before the first contribution day.
        let calendar = Calendar(identifier: .gregorian)
        let startDate: Date
        if let first = days.first?.date {
            // Find the Sunday of that week. GitHub uses Sunday-start weeks.
            let weekday = calendar.component(.weekday, from: first)  // 1 = Sunday
            let daysBack = weekday - 1
            startDate = calendar.date(byAdding: .day, value: -daysBack, to: first) ?? first
        } else {
            startDate = Date()
        }

        // Build a date -> level lookup for fast access.
        var levelByDate: [String: Int] = [:]
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        for day in days {
            levelByDate[day.isoDate] = day.level
        }

        // Cell sizing: targetWidth = columns * cell + (columns - 1) * gap.
        // Gap is 25% of cell width.
        let cellWidth = targetWidth / (Double(columns) + Double(columns - 1) * 0.25)
        let gap = cellWidth * 0.25
        let cellHeight = cellWidth
        let totalHeight = Double(rows) * cellHeight + Double(rows - 1) * gap
        let totalWidth = targetWidth

        let originX = centerX - totalWidth / 2
        let originY = topY

        var cells: [Cell] = []
        cells.reserveCapacity(columns * rows)

        for col in 0..<columns {
            for row in 0..<rows {
                let dayIdx = col * rows + row
                guard let date = calendar.date(
                    byAdding: .day,
                    value: dayIdx,
                    to: startDate
                ) else { continue }
                let iso = f.string(from: date)
                let level = levelByDate[iso] ?? -1   // -1 = not in window, render transparent

                let x = originX + Double(col) * (cellWidth + gap)
                let y = originY + Double(row) * (cellHeight + gap)
                cells.append(Cell(x: x, y: y, width: cellWidth, height: cellHeight, level: level))
            }
        }

        self.cells = cells
        self.originX = originX
        self.originY = originY
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
    }
}
