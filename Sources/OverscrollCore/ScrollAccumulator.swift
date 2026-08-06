import Foundation

/// Which way the view was scrolled to produce a snapshot.
///
/// Only consulted when alignment fails. A successful run match determines placement on its own; a
/// gap has no evidence of position, and without a hint the accumulator can only append — which puts
/// older content at the *end* of the transcript whenever the user scrolls backwards through a
/// thread.
public enum ScrollHint: Sendable {
    case unknown
    /// Scrolling backwards, revealing content that belongs before what we already have.
    case towardStart
    /// Scrolling forwards, revealing content that belongs after it.
    case towardEnd
}

/// Result of folding one harvested snapshot into the running transcript.
public enum MergeOutcome: Sendable, Equatable {
    /// Snapshot was already fully contained in what we have. Typically: the scroll didn't move
    /// (hit the end of the content) or fired twice for one gesture.
    case unchanged
    /// Scrolled forward. `added` new rows appended, matching on `overlap` shared rows.
    case appended(added: Int, overlap: Int)
    /// Scrolled backward. `added` new rows prepended, matching on `overlap` shared rows.
    case prepended(added: Int, overlap: Int)
    /// No overlap found at all — the scroll step jumped further than one viewport, so content
    /// between the two snapshots was never seen. Appended anyway, but the transcript has a hole.
    case gap(added: Int)
}

/// Folds successive snapshots of a scrolling view into one ordered, de-duplicated transcript.
///
/// This is the text-domain analogue of the overlap detection that image stitchers run on pixels:
/// consecutive snapshots of a scrolling view share a run of rows, so the join is found by locating
/// the longest suffix/prefix match between what we have and what just arrived.
///
/// Matching on *runs* rather than on individual rows is what makes repeated messages safe. A chat
/// log full of standalone "ok" and "👍" rows would defeat any per-row identity scheme (which "ok"
/// is this one?), but a run of five consecutive rows is effectively unique.
public struct ScrollAccumulator: Sendable {
    /// Shortest run accepted as a real overlap. One shared row is far too weak — in a chat log a
    /// lone "ok" matches half the transcript. Three consecutive rows is empirically unambiguous.
    /// Snapshots shorter than this fall back to full containment checks only.
    public let minimumOverlap: Int

    public private(set) var rows: [CapturedRow] = []
    /// Indices in `rows` immediately *after* which content was skipped.
    public private(set) var gapIndices: [Int] = []

    public init(minimumOverlap: Int = 3) {
        self.minimumOverlap = max(1, minimumOverlap)
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Fold one snapshot in. Snapshots may arrive in either scroll direction.
    @discardableResult
    public mutating func ingest(
        _ snapshot: [CapturedRow], hint: ScrollHint = .unknown
    ) -> MergeOutcome {
        let incoming = snapshot.filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return .unchanged }

        guard !rows.isEmpty else {
            rows = incoming
            return .appended(added: incoming.count, overlap: 0)
        }

        let have = rows.map(\.identity)
        let new = incoming.map(\.identity)

        // A snapshot wholly inside what we already have means nothing moved. Check this before
        // overlap matching: a stationary view produces an identical snapshot, which would otherwise
        // register as a full-length suffix match with zero new rows — same answer, but this is a
        // cheaper and more honest path.
        if contains(haystack: have, needle: new) { return .unchanged }

        // Scrolled forward: the tail of what we have is the head of what just arrived.
        let forward = longestOverlap(suffixOf: have, prefixOf: new)
        // Scrolled backward: the head of what we have is the tail of what just arrived.
        let backward = longestOverlap(suffixOf: new, prefixOf: have)

        // Prefer the longer match. Ties go to forward, since scrolling down is the common case and
        // a symmetric match usually means the view barely moved.
        if forward >= backward, forward >= effectiveMinimum(have.count, new.count) {
            let fresh = Array(incoming.dropFirst(forward))
            rows.append(contentsOf: fresh)
            return .appended(added: fresh.count, overlap: forward)
        }

        if backward >= effectiveMinimum(have.count, new.count) {
            let fresh = Array(incoming.dropLast(backward))
            rows.insert(contentsOf: fresh, at: 0)
            // Prepending shifts every recorded gap.
            gapIndices = gapIndices.map { $0 + fresh.count }
            return .prepended(added: fresh.count, overlap: backward)
        }

        // Nothing matched. Either the scroll step outran the viewport, or the app exposed too few
        // rows for a run of `minimumOverlap` to exist.
        //
        // Whatever the cause, alignment is unknown — so rows already somewhere in the transcript
        // must not be appended again. Blindly appending the whole snapshot is what turns a thread
        // with a small exposed window into the same four messages repeated five times. The cost is
        // that genuinely repeated content is dropped here; that is the right trade when position is
        // already unknown, and the normal append path (which aligns on runs) still handles repeats.
        let known = Set(have)
        let fresh = incoming.filter { !known.contains($0.identity) }
        guard !fresh.isEmpty else { return .unchanged }

        // Recorded rather than silently papered over: a transcript with an unmarked hole in it is
        // worse than one that admits the hole, because the reader can't tell.
        if hint == .towardStart {
            // Scrolling backwards, so the unplaceable rows belong before everything we have. The
            // hole sits between them and the existing content.
            rows.insert(contentsOf: fresh, at: 0)
            gapIndices = gapIndices.map { $0 + fresh.count }
            gapIndices.append(fresh.count - 1)
            gapIndices.sort()
            return .gap(added: fresh.count)
        }

        gapIndices.append(rows.count - 1)
        rows.append(contentsOf: fresh)
        return .gap(added: fresh.count)
    }

    /// Require the full `minimumOverlap`, unless a snapshot is genuinely shorter than that (a
    /// nearly-empty viewport), in which case demand that it match in full.
    private func effectiveMinimum(_ haveCount: Int, _ newCount: Int) -> Int {
        min(minimumOverlap, min(haveCount, newCount))
    }

    /// Length of the longest run that is both a suffix of `a` and a prefix of `b`.
    private func longestOverlap(suffixOf a: [String], prefixOf b: [String]) -> Int {
        var k = min(a.count, b.count)
        while k > 0 {
            if Array(a.suffix(k)) == Array(b.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }

    private func contains(haystack: [String], needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for start in 0...limit where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
