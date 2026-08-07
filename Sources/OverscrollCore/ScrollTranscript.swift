import Foundation

/// Assembles scroll snapshots by tracking where content sits in the *document*, not by matching
/// runs of text.
///
/// [[ScrollAccumulator]] joins two snapshots by finding the longest shared suffix/prefix run of
/// rows. That works, but it needs a run of several rows to be confident, and an app that exposes
/// only a handful of tall rows at a time — a chat client with link previews — frequently fails to
/// provide one. Every such failure is a gap.
///
/// This takes the geometry instead. Rows already carry a screen y, so any row visible in two
/// consecutive snapshots reveals exactly how far the content moved between them. Accumulating that
/// displacement gives every row a stable document coordinate, and merging becomes insertion into a
/// sorted set. Three consequences, all of which matter for the failure case above:
///
/// - **One shared row suffices** to fix the offset, where run matching needs `minimumOverlap`.
/// - **Repeated text stops being ambiguous.** Two `ok` messages sit at different document
///   positions, so they are distinguishable without any run to disambiguate them.
/// - **A gap becomes a measurement.** Instead of "no run matched", it is "the offset moved 420pt
///   and nothing was sampled across 300pt of it".
public struct ScrollTranscript: Sendable {

    /// Rows within this many points of each other, with identical text, are the same row seen
    /// again. Absorbs sub-pixel drift and minor reflow without merging genuinely distinct rows,
    /// which in practice are a full line-height apart.
    public let matchTolerance: Double

    public struct PlacedRow: Sendable, Equatable {
        public let row: CapturedRow
        /// Position in document space: stable across scrolling, unlike the row's screen y.
        public let documentY: Double
        /// Horizontal document position, for content scrolled sideways.
        public let documentX: Double

        /// Every distinct reading of this line, with how often each was seen.
        ///
        /// A line stays on screen across several scroll steps, so it is recognised several times.
        /// Those readings disagree — OCR substitutes a glyph here, drops a list marker there — and
        /// keeping only the first or the longest is a coin flip. Tallying them lets the majority
        /// decide, which is the one signal available that costs nothing extra: the observations are
        /// already being made.
        public internal(set) var readings: [String: Reading]

        /// One candidate spelling of a line, with the evidence supporting it.
        public struct Reading: Sendable, Equatable {
            public var count: Int
            /// Summed recogniser confidence across the passes that produced this spelling.
            public var confidenceSum: Double
            public var meanConfidence: Double { count > 0 ? confidenceSum / Double(count) : 0 }
        }

        /// The reading to use.
        ///
        /// Frequency first, but confidence decides the ties — and ties are the common case, because
        /// a line is typically seen only two or three times. Length was the original tie-break and
        /// it is worthless here: a garbled reading is usually *exactly as long* as the correct one,
        /// since OCR substitutes glyphs rather than dropping them, so the choice collapsed to
        /// dictionary order and picked "Ontical character recoanition" about half the time.
        public var consensusText: String {
            guard readings.count > 1 else { return row.text }
            let best = readings.max { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
                if abs(lhs.value.meanConfidence - rhs.value.meanConfidence) > 0.001 {
                    return lhs.value.meanConfidence < rhs.value.meanConfidence
                }
                return lhs.key.count < rhs.key.count
            }
            return best?.key ?? row.text
        }
    }

    /// Cumulative screen→document offset. Grows as the view scrolls away from where it started.
    private var offset: Double = 0
    /// Horizontal counterpart. Kept separate rather than folded into a point because the vertical
    /// axis carries reading order and the horizontal one does not.
    private var offsetX: Double = 0
    private var placed: [PlacedRow] = []
    /// Document-space spans where content was skipped without being sampled.
    public private(set) var gapSpans: [ClosedRange<Double>] = []

    public init(matchTolerance: Double = 6) {
        self.matchTolerance = matchTolerance
    }

    /// Rows carrying the consensus reading of each line rather than whichever arrived first.
    public var rows: [CapturedRow] {
        placed.map { entry in
            let text = entry.consensusText
            guard text != entry.row.text else { return entry.row }
            return CapturedRow(
                text: text,
                role: entry.row.role,
                links: entry.row.links,
                y: entry.row.y,
                x: entry.row.x,
                isSelected: entry.row.isSelected
            )
        }
    }
    public var placedRows: [PlacedRow] { placed }
    public var isEmpty: Bool { placed.isEmpty }
    public var gapCount: Int { gapSpans.count }

    public enum Outcome: Sendable, Equatable {
        case seeded(rows: Int)
        /// Displacement measured from `anchors` rows shared with what we already had.
        /// `displacement` is the vertical component; horizontal is reported by `horizontal`.
        case merged(added: Int, displacement: Double, anchors: Int)
        /// Nothing was shared, so displacement had to be assumed from the commanded scroll.
        case estimated(added: Int, assumed: Double)
        case unchanged
    }

    /// Fold in one snapshot.
    ///
    /// `commandedDisplacement` is how far we *asked* the view to move, used only when no row is
    /// shared and the true displacement cannot be measured. Sign convention matches screen space:
    /// positive means content moved down the screen.
    @discardableResult
    public mutating func ingest(
        _ snapshot: [CapturedRow],
        commandedDisplacement: Double = 0,
        commandedHorizontal: Double = 0
    ) -> Outcome {
        let incoming = snapshot.filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return .unchanged }

        guard !placed.isEmpty else {
            for row in incoming {
                placed.append(PlacedRow(row: row, documentY: row.y, documentX: row.x, readings: [row.text: PlacedRow.Reading(count: 1, confidenceSum: row.confidence ?? 1)]))
            }
            sortAndDedupe()
            return .seeded(rows: placed.count)
        }

        let anchors = measureDisplacement(incoming)

        let displacement: Double
        let horizontal: Double
        let measured: Bool
        if let anchors, !anchors.deltas.isEmpty {
            // Median, not mean: a row that reflowed or resized would otherwise drag the estimate,
            // and a single bad anchor would corrupt every subsequent position.
            displacement = median(anchors.deltas)
            horizontal = median(anchors.horizontalDeltas)
            measured = true
        } else {
            displacement = commandedDisplacement
            horizontal = commandedHorizontal
            measured = false
        }

        let existingExtent = extent(of: placed.map(\.documentY))
        offset += displacement
        offsetX += horizontal

        let before = placed.count
        let incomingPositions = incoming.map { $0.y + offset }
        for (row, documentY) in zip(incoming, incomingPositions) {
            placed.append(PlacedRow(row: row, documentY: documentY, documentX: row.x + offsetX, readings: [row.text: PlacedRow.Reading(count: 1, confidenceSum: row.confidence ?? 1)]))
        }
        sortAndDedupe()
        let added = placed.count - before

        // Gaps arise only when displacement could not be measured, and this is provable rather
        // than heuristic: an anchor is a row present in *both* viewports, so its existence
        // demonstrates the two overlap and that nothing passed between them unseen. A measured
        // merge therefore cannot have skipped content, no matter how far the offset moved.
        //
        // Which makes the converse the whole definition: no shared row, no proof of continuity.
        // Scrolling back over a gap is how it gets filled, so newly observed ground closes it.
        closeGaps(coveredBy: extent(of: incomingPositions))

        if !measured {
            if let void = void(between: existingExtent, and: extent(of: incomingPositions)) {
                gapSpans.append(void)
            }
            return .estimated(added: added, assumed: displacement)
        }

        if added == 0 { return .unchanged }
        return .merged(added: added, displacement: displacement, anchors: anchors?.count ?? 0)
    }

    // MARK: - Displacement

    private struct Anchors {
        var deltas: [Double]
        var horizontalDeltas: [Double]
        var count: Int
    }

    /// For rows already placed, how far each has moved since we last saw it.
    ///
    /// A row's document position is fixed, so `documentY - (screenY + offset)` is the displacement
    /// this snapshot represents. With repeated text there may be several candidates; the one
    /// implying the smallest movement is taken, since content rarely jumps further than it has to.
    /// Recover the displacement by consensus among every possible anchor pairing.
    ///
    /// Matching each row to its *nearest* previous instance and averaging is circular: choosing the
    /// nearest candidate presumes the offset that is being solved for. With repeated text — cells
    /// reading "Yes", a column of identical labels — it picks wrong, and the average of a right and
    /// a wrong answer is a third answer that is wrong too. Measured on a three-cell case: a true
    /// displacement of 200 came out as 100.
    ///
    /// Instead every (row, candidate) pairing proposes a displacement and votes. The true one is
    /// proposed by *every* correctly-matched row, while spurious pairings scatter, so the
    /// best-supported bucket wins outright. Cheap, and it degrades gracefully: with a single
    /// unambiguous anchor it reduces to that anchor's answer.
    private func measureDisplacement(_ incoming: [CapturedRow]) -> Anchors? {
        var index: [String: [(y: Double, x: Double)]] = [:]
        for row in placed {
            index[row.row.identity, default: []].append((row.documentY, row.documentX))
        }

        // Bucket key rounds to the match tolerance so near-identical proposals reinforce each other.
        struct Bucket: Hashable { let y: Int; let x: Int }
        var support: [Bucket: (ys: [Double], xs: [Double])] = [:]

        for row in incoming {
            guard let candidates = index[row.identity] else { continue }
            let projectedY = row.y + offset
            let projectedX = row.x + offsetX
            for candidate in candidates {
                let dy = candidate.y - projectedY
                let dx = candidate.x - projectedX
                let key = Bucket(
                    y: Int((dy / matchTolerance).rounded()),
                    x: Int((dx / matchTolerance).rounded())
                )
                support[key, default: ([], [])].ys.append(dy)
                support[key, default: ([], [])].xs.append(dx)
            }
        }

        // Most support wins; ties break toward the smaller movement, since content rarely jumps
        // further than it has to.
        let winner = support.max { lhs, rhs in
            if lhs.value.ys.count != rhs.value.ys.count {
                return lhs.value.ys.count < rhs.value.ys.count
            }
            return hypot(Double(lhs.key.y), Double(lhs.key.x))
                > hypot(Double(rhs.key.y), Double(rhs.key.x))
        }
        guard let winner, !winner.value.ys.isEmpty else { return nil }

        return Anchors(
            deltas: winner.value.ys,
            horizontalDeltas: winner.value.xs,
            count: winner.value.ys.count
        )
    }

    private func extent(of positions: [Double]) -> ClosedRange<Double>? {
        guard let low = positions.min(), let high = positions.max() else { return nil }
        return low...high
    }

    /// The unobserved span between two stretches of content, or nil when they overlap or touch.
    private func void(
        between existing: ClosedRange<Double>?, and incoming: ClosedRange<Double>?
    ) -> ClosedRange<Double>? {
        guard let existing, let incoming else { return nil }
        if incoming.lowerBound > existing.upperBound {
            return existing.upperBound...incoming.lowerBound
        }
        if incoming.upperBound < existing.lowerBound {
            return incoming.upperBound...existing.lowerBound
        }
        return nil
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Ordering

    /// Order by document position and collapse re-observations of the same row.
    ///
    /// Identity alone is not the key — the same text at two document positions is two real
    /// messages. Position alone is not the key either, since rows shift slightly. Both together
    /// are, which is exactly the ambiguity run matching existed to work around.
    private mutating func sortAndDedupe() {
        // Reading order in *document* space, which is stable while the view moves. Rows on the same
        // line sort left to right, so a table reads across before it reads down.
        //
        // Unless the content is in columns, where "down then across" is the wrong order entirely:
        // a y-major sort interleaves the two sides line by line. When a gutter is detected the
        // column becomes the primary key, so the left side is read out fully before the right.
        let boundary = columnBoundary()
        placed.sort { lhs, rhs in
            if let boundary {
                let lhsColumn = lhs.documentX < boundary ? 0 : 1
                let rhsColumn = rhs.documentX < boundary ? 0 : 1
                if lhsColumn != rhsColumn { return lhsColumn < rhsColumn }
            }
            if abs(lhs.documentY - rhs.documentY) > matchTolerance {
                return lhs.documentY < rhs.documentY
            }
            if abs(lhs.documentX - rhs.documentX) > 0.001 { return lhs.documentX < rhs.documentX }
            return lhs.row.text < rhs.row.text
        }

        var deduped: [PlacedRow] = []
        for candidate in placed {
            if let last = deduped.last,
               abs(last.documentY - candidate.documentY) <= matchTolerance,
               abs(last.documentX - candidate.documentX) <= matchTolerance,
               isSameLine(last.row, candidate.row) {
                // Another reading of a line already placed. Record the vote rather than replacing:
                // for recognised text the two spellings disagree, and the majority across all the
                // passes that saw this line is a far better answer than whichever arrived last.
                var merged = last
                merged.readings[candidate.row.text, default: PlacedRow.Reading(count: 0, confidenceSum: 0)].count += 1
                merged.readings[candidate.row.text]?.confidenceSum += candidate.row.confidence ?? 1
                // Prefer the observation carrying more link data; some passes realize an element
                // only partially.
                if candidate.row.links.count > last.row.links.count {
                    merged = PlacedRow(
                        row: candidate.row,
                        documentY: merged.documentY,
                        documentX: merged.documentX,
                        readings: merged.readings
                    )
                }
                deduped[deduped.count - 1] = merged
                continue
            }
            deduped.append(candidate)
        }
        placed = deduped
    }

    /// Where the unobserved spans sit relative to what is on screen right now.
    ///
    /// Gaps live in document space, so once the viewport's own document position is known they can
    /// be reported as a direction to travel rather than a bare count — which is the difference
    /// between telling someone "you missed something" and telling them where to go to get it.
    ///
    /// `screenRange` is the capture region in screen coordinates (top-left origin, y growing down),
    /// which this converts using the offset it has been tracking all along.
    public func gapsRelativeToViewport(screenRange: ClosedRange<Double>) -> (above: Int, below: Int) {
        let viewport = (screenRange.lowerBound + offset)...(screenRange.upperBound + offset)
        var above = 0
        var below = 0
        for span in gapSpans {
            if span.upperBound < viewport.lowerBound {
                above += 1
            } else if span.lowerBound > viewport.upperBound {
                below += 1
            }
            // A span overlapping the viewport is being looked at right now; neither arrow applies.
        }
        return (above, below)
    }

    /// Remove or shorten gap spans that newly observed content covers.
    ///
    /// Pragmatic rather than rigorous: strictly, a span is only closed once an unbroken chain of
    /// anchored merges crosses it, and this instead trims by whatever was observed. In practice
    /// scrolling back into a gap is exactly how it gets filled, and a marker that never clears
    /// would train the user to ignore it.
    private mutating func closeGaps(coveredBy extent: ClosedRange<Double>?) {
        guard let extent, !gapSpans.isEmpty else { return }
        gapSpans = gapSpans.compactMap { span in
            guard span.overlaps(extent) else { return span }
            let remainderBelow = extent.upperBound < span.upperBound
                ? extent.upperBound...span.upperBound : nil
            let remainderAbove = extent.lowerBound > span.lowerBound
                ? span.lowerBound...extent.lowerBound : nil
            // Keep whichever side still has meaningful unobserved distance; a sliver is noise.
            let candidates = [remainderAbove, remainderBelow]
                .compactMap { $0 }
                .filter { $0.upperBound - $0.lowerBound > matchTolerance }
            return candidates.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
        }
    }

    /// The column gutter, if the placed rows form side-by-side columns.
    ///
    /// Recomputed per merge rather than latched, because a capture only becomes recognisably
    /// two-column once enough of both sides has been seen — deciding early, on the first screenful,
    /// would fix an answer while the evidence for it is still arriving.
    private func columnBoundary() -> Double? {
        ColumnLayout.columnBoundary(
            for: placed.map { ColumnLayout.Row(x: $0.documentX, y: $0.documentY) }
        )
    }

    /// Whether two rows at the same position are the same line seen twice.
    ///
    /// Exact identity for anything from an accessibility tree, which reports text verbatim — two
    /// genuinely different short labels can look similar, and merging them would be a corruption.
    /// Recognised text gets a tolerance, because it is *expected* to differ between passes and
    /// demanding exactness there means the same line is stored several times over.
    private func isSameLine(_ lhs: CapturedRow, _ rhs: CapturedRow) -> Bool {
        guard lhs.role == "OCRLine", rhs.role == "OCRLine" else {
            return lhs.identity == rhs.identity
        }
        return TextSimilarity.areSameLine(lhs.identity, rhs.identity)
    }

    /// Indices in `rows` after which a gap span falls, for rendering inline markers.
    public func gapIndices() -> [Int] {
        guard !gapSpans.isEmpty else { return [] }
        var indices: [Int] = []
        for span in gapSpans {
            // The last row that sits before the skipped span.
            if let index = placed.lastIndex(where: { $0.documentY <= span.lowerBound }) {
                indices.append(index)
            }
        }
        return Array(Set(indices)).sorted()
    }
}
