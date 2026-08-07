import Foundation

/// Detects whether captured rows are laid out in side-by-side columns.
///
/// Reading order is normally "down, then across", and sorting by y then x produces it. A two-column
/// layout inverts that: the correct order is the whole left column, then the whole right one, and a
/// y-major sort interleaves them into nonsense — observed on a job posting where the description
/// and the application form alternated line by line.
///
/// The hazard is over-detection. An indented list also has rows at two different x positions, and
/// splitting *that* into columns would scatter every bullet away from its own continuation lines —
/// a far worse outcome than the interleaving being fixed. Three conditions must hold together, and
/// each one exists to reject a specific false positive:
///
/// - **A wide gap** between the two x groups. Indentation is tens of points; a column gutter is
///   hundreds. This alone rejects most nesting.
/// - **Both sides substantial.** A handful of rows sitting right of the others is a pull-quote, a
///   caption or a set of timestamps, not a column.
/// - **Vertical co-existence.** Real columns occupy the *same* vertical span. Content that merely
///   moves right partway down the page is one column that changed indent, not two.
public enum ColumnLayout {

    public struct Row: Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Minimum horizontal gutter, as a fraction of the content's total width.
    private static let minimumGutterFraction = 0.08
    /// Minimum rows on the smaller side.
    private static let minimumRowsPerColumn = 5
    /// Minimum overlap of the two vertical spans, as a fraction of the smaller span.
    private static let minimumVerticalOverlap = 0.5

    /// The x boundary separating two columns, or nil when the rows are a single column.
    ///
    /// Returns the split point rather than groups so the caller can classify rows itself and keep
    /// its own row type.
    public static func columnBoundary(for rows: [Row]) -> Double? {
        guard rows.count >= minimumRowsPerColumn * 2 else { return nil }

        let xs = rows.map(\.x).sorted()
        guard let minX = xs.first, let maxX = xs.last, maxX > minX else { return nil }
        let width = maxX - minX
        let requiredGutter = max(width * minimumGutterFraction, 60)

        // The widest gap in the sorted x positions is the only candidate worth testing: any real
        // gutter is the largest empty horizontal band in the layout.
        var bestGap = 0.0
        var boundary = 0.0
        for index in 1..<xs.count {
            let gap = xs[index] - xs[index - 1]
            if gap > bestGap {
                bestGap = gap
                boundary = (xs[index] + xs[index - 1]) / 2
            }
        }
        guard bestGap >= requiredGutter else { return nil }

        let left = rows.filter { $0.x < boundary }
        let right = rows.filter { $0.x >= boundary }
        guard left.count >= minimumRowsPerColumn, right.count >= minimumRowsPerColumn else {
            return nil
        }
        guard verticallyCoexist(left, right) else { return nil }
        return boundary
    }

    /// Whether two groups occupy the same vertical territory, rather than following one another.
    private static func verticallyCoexist(_ left: [Row], _ right: [Row]) -> Bool {
        guard let leftMin = left.map(\.y).min(), let leftMax = left.map(\.y).max(),
              let rightMin = right.map(\.y).min(), let rightMax = right.map(\.y).max()
        else { return false }

        let overlap = min(leftMax, rightMax) - max(leftMin, rightMin)
        guard overlap > 0 else { return false }
        let smallerSpan = min(leftMax - leftMin, rightMax - rightMin)
        guard smallerSpan > 0 else { return false }
        return overlap / smallerSpan >= minimumVerticalOverlap
    }
}
