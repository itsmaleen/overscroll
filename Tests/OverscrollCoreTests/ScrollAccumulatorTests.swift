import Testing
@testable import OverscrollCore

private func rows(_ texts: [String]) -> [CapturedRow] {
    texts.enumerated().map { CapturedRow(text: $1, y: Double($0) * 20) }
}

private func texts(_ acc: ScrollAccumulator) -> [String] {
    acc.rows.map(\.text)
}

@Suite("ScrollAccumulator")
struct ScrollAccumulatorTests {

    @Test("first snapshot seeds the transcript")
    func firstSnapshot() {
        var acc = ScrollAccumulator()
        let outcome = acc.ingest(rows(["a", "b", "c"]))
        #expect(outcome == .appended(added: 3, overlap: 0))
        #expect(texts(acc) == ["a", "b", "c"])
    }

    @Test("scrolling down appends only the newly revealed rows")
    func scrollDown() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d", "e"]))
        let outcome = acc.ingest(rows(["c", "d", "e", "f", "g"]))
        #expect(outcome == .appended(added: 2, overlap: 3))
        #expect(texts(acc) == ["a", "b", "c", "d", "e", "f", "g"])
    }

    @Test("scrolling up prepends earlier rows in the right order")
    func scrollUp() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["e", "f", "g", "h", "i"]))
        let outcome = acc.ingest(rows(["b", "c", "d", "e", "f", "g"]))
        #expect(outcome == .prepended(added: 3, overlap: 3))
        #expect(texts(acc) == ["b", "c", "d", "e", "f", "g", "h", "i"])
    }

    @Test("a stationary view adds nothing")
    func stationary() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d"]))
        #expect(acc.ingest(rows(["a", "b", "c", "d"])) == .unchanged)
        #expect(texts(acc) == ["a", "b", "c", "d"])
    }

    @Test("a snapshot strictly inside the transcript adds nothing")
    func containedSnapshot() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d", "e", "f"]))
        #expect(acc.ingest(rows(["b", "c", "d"])) == .unchanged)
        #expect(texts(acc) == ["a", "b", "c", "d", "e", "f"])
    }

    // The reason alignment matches runs instead of individual rows. Per-row identity cannot tell
    // these "ok"s apart; a run of three can.
    @Test("repeated identical messages do not collapse or mis-join")
    func repeatedMessages() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["hey", "ok", "sure", "ok", "thanks", "ok"]))
        let outcome = acc.ingest(rows(["ok", "thanks", "ok", "np", "ok"]))
        #expect(outcome == .appended(added: 2, overlap: 3))
        #expect(texts(acc) == ["hey", "ok", "sure", "ok", "thanks", "ok", "np", "ok"])
    }

    // A single shared row is not evidence of an overlap. Without the minimum-run rule this joins
    // on the trailing "ok" and silently eats every row that was actually skipped.
    @Test("a lone shared row is not treated as an overlap")
    func loneSharedRowIsNotOverlap() {
        var acc = ScrollAccumulator(minimumOverlap: 3)
        acc.ingest(rows(["alpha", "beta", "ok"]))
        let outcome = acc.ingest(rows(["ok", "zulu", "yankee"]))
        // Falls to the gap path (one shared row is not a seam), and the already-known "ok" is not
        // appended a second time.
        #expect(outcome == .gap(added: 2))
        #expect(texts(acc) == ["alpha", "beta", "ok", "zulu", "yankee"])
    }

    // A gap means alignment is unknown, so rows already in the transcript must not be re-appended.
    // Without this, an app that exposes only a few rows at a time (a virtualized chat list) yields
    // the same handful of messages repeated once per scroll step.
    @Test("a gap does not re-append rows already in the transcript")
    func gapDeduplicatesAgainstTranscript() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d"]))
        let outcome = acc.ingest(rows(["c", "x", "a"]))
        #expect(outcome == .gap(added: 1))
        #expect(texts(acc) == ["a", "b", "c", "d", "x"])
    }

    @Test("a gap whose rows are all already known changes nothing")
    func gapFullyKnownIsUnchanged() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d"]))
        let outcome = acc.ingest(rows(["d", "a"]))
        #expect(outcome == .unchanged)
        #expect(texts(acc) == ["a", "b", "c", "d"])
        #expect(acc.gapIndices.isEmpty)
    }

    @Test("outrunning the viewport records a gap rather than hiding it")
    func recordsGap() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c"]))
        let outcome = acc.ingest(rows(["x", "y", "z"]))
        #expect(outcome == .gap(added: 3))
        #expect(acc.gapIndices == [2])
        #expect(texts(acc) == ["a", "b", "c", "x", "y", "z"])
    }

    // Scrolling backwards through a thread, an unplaceable snapshot is older content. Appending it
    // puts the oldest messages at the bottom of the transcript, out of chronological order.
    @Test("an unplaceable snapshot goes to the front when scrolling backwards")
    func gapRespectsBackwardHint() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["d", "e", "f"]))
        let outcome = acc.ingest(rows(["a", "b"]), hint: .towardStart)
        #expect(outcome == .gap(added: 2))
        #expect(texts(acc) == ["a", "b", "d", "e", "f"])
        // The hole is between the prepended block and the original content.
        #expect(acc.gapIndices == [1])
    }

    @Test("an unplaceable snapshot still appends when scrolling forwards")
    func gapRespectsForwardHint() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c"]))
        let outcome = acc.ingest(rows(["y", "z"]), hint: .towardEnd)
        #expect(outcome == .gap(added: 2))
        #expect(texts(acc) == ["a", "b", "c", "y", "z"])
        #expect(acc.gapIndices == [2])
    }

    @Test("a backward hint does not override a real run match")
    func hintDoesNotOverrideAlignment() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c", "d", "e"]))
        // Genuine forward overlap, despite the caller reporting a backward scroll.
        let outcome = acc.ingest(rows(["c", "d", "e", "f"]), hint: .towardStart)
        #expect(outcome == .appended(added: 1, overlap: 3))
        #expect(texts(acc) == ["a", "b", "c", "d", "e", "f"])
    }

    @Test("gap markers stay attached to their row when content is prepended")
    func gapIndicesShiftOnPrepend() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["a", "b", "c"]))
        acc.ingest(rows(["x", "y", "z"]))     // gap recorded after index 2
        #expect(acc.gapIndices == [2])
        acc.ingest(rows(["p", "q", "r", "a", "b", "c"]))  // scroll back up
        #expect(texts(acc) == ["p", "q", "r", "a", "b", "c", "x", "y", "z"])
        // "c" moved from index 2 to index 5; the gap must follow it.
        #expect(acc.gapIndices == [5])
    }

    @Test("whitespace churn between snapshots still matches")
    func whitespaceNormalization() {
        var acc = ScrollAccumulator()
        acc.ingest(rows(["Hello  there", "second line", "third line"]))
        let outcome = acc.ingest(rows(["hello there", "second   line", "third line", "fourth"]))
        #expect(outcome == .appended(added: 1, overlap: 3))
        #expect(acc.rows.count == 4)
    }

    @Test("empty rows are dropped and never create false overlaps")
    func dropsEmptyRows() {
        var acc = ScrollAccumulator()
        acc.ingest([CapturedRow(text: "a"), CapturedRow(text: "   "), CapturedRow(text: "b")])
        #expect(texts(acc) == ["a", "b"])
    }

    // The minimum-run rule has to relax when a side is genuinely shorter than the run, or the very
    // first steps of a capture — when the transcript is only a row or two long — could never join.
    @Test("a short transcript can still join on a shorter run")
    func shortTranscriptStillJoins() {
        var acc = ScrollAccumulator(minimumOverlap: 3)
        acc.ingest(rows(["a", "b"]))
        let outcome = acc.ingest(rows(["a", "b", "c", "d", "e"]))
        #expect(outcome == .appended(added: 3, overlap: 2))
        #expect(texts(acc) == ["a", "b", "c", "d", "e"])
    }

    // Conservative on purpose: a 1-row join after a scroll means we nearly outran the viewport, so
    // the honest answer is to flag it rather than assume the single shared row is a true seam.
    @Test("a 1-row overlap is reported as a gap, not a join")
    func singleRowOverlapGaps() {
        var acc = ScrollAccumulator(minimumOverlap: 3)
        acc.ingest(rows(["a", "b", "c", "d"]))
        let outcome = acc.ingest(rows(["d", "e"]))
        // Only "e" is new; the shared "d" is not duplicated onto the end.
        #expect(outcome == .gap(added: 1))
        #expect(texts(acc) == ["a", "b", "c", "d", "e"])
        #expect(acc.gapIndices == [3])
    }

    @Test("a long realistic scroll reconstructs the source exactly")
    func longScrollRoundTrip() {
        let source = (1...120).map { "message \($0)" }
        var acc = ScrollAccumulator()
        // 20-row viewport advancing 12 rows per step: 8 rows of overlap, like a real trackpad flick.
        var offset = 0
        while offset < source.count {
            let window = Array(source[offset..<min(offset + 20, source.count)])
            acc.ingest(rows(window))
            offset += 12
        }
        #expect(texts(acc) == source)
        #expect(acc.gapIndices.isEmpty)
    }
}
