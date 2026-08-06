import Foundation

/// Separates the content that is actually scrolling from the static chrome around it.
///
/// A dragged region usually contains more than the thing being captured: a sidebar, a toolbar, a
/// message composer, a floating date header. Those rows interleave with the real content by
/// y-position and, because they *don't* move when the content does, their relative order changes on
/// every scroll. That reshuffling destroys the contiguous run [[ScrollAccumulator]] needs, so every
/// merge degrades into a gap and the transcript fills with duplicates.
///
/// The structural fix — group rows by their enclosing `AXScrollArea` — only works when the app
/// exposes one. WhatsApp's Catalyst client exposes none at all. So this uses the one signal that is
/// always available and doesn't depend on how the app builds its tree: **scrolling content moves,
/// chrome does not.** A row seen at the same y in two consecutive snapshots is chrome.
///
/// Classification needs two snapshots, so the first is held back until the second arrives.
public struct ScrollingContentFilter: Sendable {

    /// Vertical movement below this is treated as no movement. Sub-pixel layout jitter and
    /// rounding in the accessibility frame both show up as fractional drift.
    public let tolerance: Double

    public private(set) var staticIdentities: Set<String> = []
    /// All positions each identity was seen at, not just one.
    ///
    /// Keeping a single position per identity is wrong wherever text repeats, and forms repeat text
    /// constantly — a field's label and its own placeholder are usually identical, so "Github URL"
    /// occupies two rows at different heights. With one stored position the comparison lands on the
    /// wrong instance, the row looks stationary, and *both* instances are blacklisted as chrome.
    /// Observed on a job application: entire snapshots (29 of 29 rows) discarded that way.
    private var lastPositions: [String: [Double]] = [:]
    /// The snapshot held back awaiting evidence of movement. Cleared once the first release
    /// happens, after which snapshots stream straight through.
    private var pending: [CapturedRow]?
    private var hasReleased = false

    public init(tolerance: Double = 2.0) {
        self.tolerance = tolerance
    }

    /// Feed one snapshot. Returns the snapshots ready to be ingested, in order — empty while the
    /// first is still held for comparison, two on the release that ends the hold, one thereafter.
    public mutating func accept(_ snapshot: [CapturedRow]) -> [[CapturedRow]] {
        let currentPositions = positionsByIdentity(snapshot)
        defer { lastPositions = currentPositions }

        // Compare each identity's *whole set* of positions. An identity counts as stationary only
        // if every instance of it is where it was, which is the only reading that survives repeated
        // text.
        var movedAny = false
        var stationary: [String] = []
        for (identity, positions) in currentPositions {
            guard let previous = lastPositions[identity] else { continue }
            if positionsMatch(previous, positions) {
                stationary.append(identity)
            } else {
                movedAny = true
            }
        }

        // Only learn from a snapshot that demonstrably moved. If nothing moved, the view didn't
        // scroll — and every row would look static, which would blacklist the entire capture.
        if movedAny {
            for identity in stationary { staticIdentities.insert(identity) }
        }
        let moved = movedAny

        // Steady state: classification is already under way, so pass snapshots straight through.
        if hasReleased { return [strip(snapshot)] }

        guard let held = pending else {
            pending = snapshot
            return []
        }

        guard moved else {
            // No movement yet, so nothing can be classified. Keep holding, preferring the newer
            // snapshot since it is at least as complete as the one before it.
            pending = snapshot
            return []
        }

        // Release both, stripped by what was just learned — so chrome captured before it could be
        // identified never reaches the transcript.
        pending = nil
        hasReleased = true
        return [strip(held), strip(snapshot)]
    }

    /// Release anything still held. Used when a capture ends without the view ever scrolling, where
    /// there is no movement evidence and the honest answer is to return the snapshot unfiltered.
    public mutating func flush() -> [CapturedRow] {
        defer { pending = nil }
        guard let held = pending else { return [] }
        return strip(held)
    }

    private func positionsByIdentity(_ snapshot: [CapturedRow]) -> [String: [Double]] {
        var grouped: [String: [Double]] = [:]
        for row in snapshot { grouped[row.identity, default: []].append(row.y) }
        for key in grouped.keys { grouped[key]?.sort() }
        return grouped
    }

    /// Whether two position sets describe the same, unmoved rows.
    private func positionsMatch(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// Filter an already-released snapshot with the current knowledge of what is static.
    public func strip(_ snapshot: [CapturedRow]) -> [CapturedRow] {
        guard !staticIdentities.isEmpty else { return snapshot }
        return snapshot.filter { !staticIdentities.contains($0.identity) }
    }
}
