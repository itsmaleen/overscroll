import Testing
@testable import OverscrollCore

/// Snapshot from (text, screenY) pairs.
private func snap(_ items: [(String, Double)]) -> [CapturedRow] {
    items.map { CapturedRow(text: $0.0, y: $0.1) }
}

@Suite("ScrollTranscript")
struct ScrollTranscriptTests {

    @Test("first snapshot seeds document space from screen space")
    func seeds() {
        var transcript = ScrollTranscript()
        let outcome = transcript.ingest(snap([("a", 10), ("b", 40)]))
        #expect(outcome == .seeded(rows: 2))
        #expect(transcript.rows.map(\.text) == ["a", "b"])
    }

    // The headline improvement: run matching needs `minimumOverlap` rows to join. Geometry needs
    // one, because a single shared row fully determines the displacement.
    @Test("a single shared row is enough to place a whole snapshot")
    func singleAnchorSuffices() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30), ("c", 60)]))
        // Scrolled backwards by 60: everything moves *down* the screen, so "a" is now at 60 and
        // two earlier rows come into view above it. Only "a" is shared — one anchor.
        let outcome = transcript.ingest(snap([("x", 0), ("y", 30), ("a", 60)]))

        guard case .merged(let added, let displacement, let anchors) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(added == 2)
        // Negative: content moved down the screen, i.e. toward the start of the document.
        #expect(displacement == -60)
        #expect(anchors == 1)
        #expect(transcript.rows.map(\.text) == ["x", "y", "a", "b", "c"])
    }

    @Test("scrolling forward appends newly revealed rows in order")
    func scrollForward() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30), ("c", 60)]))
        transcript.ingest(snap([("b", 0), ("c", 30), ("d", 60)]))
        #expect(transcript.rows.map(\.text) == ["a", "b", "c", "d"])
    }

    @Test("scrolling backward places earlier rows before what we had")
    func scrollBackward() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("c", 0), ("d", 30), ("e", 60)]))
        transcript.ingest(snap([("a", 0), ("b", 30), ("c", 60)]))
        #expect(transcript.rows.map(\.text) == ["a", "b", "c", "d", "e"])
    }

    // Where run matching is at its weakest and geometry at its strongest: identical text is
    // disambiguated by position alone, with no run required.
    @Test("repeated identical messages stay distinct by position")
    func repeatedMessages() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("ok", 0), ("sure", 30), ("ok", 60)]))
        // Scrolled forward 30: everything shifts up one row and "thanks" appears at the bottom.
        // Two of the three anchors are the ambiguous "ok"; the median absorbs whichever one the
        // nearest-candidate heuristic mismatches.
        transcript.ingest(snap([("ok", -30), ("sure", 0), ("ok", 30), ("thanks", 60)]))
        #expect(transcript.rows.map(\.text) == ["ok", "sure", "ok", "thanks"])
    }

    @Test("a stationary view adds nothing")
    func stationary() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30)]))
        let outcome = transcript.ingest(snap([("a", 0), ("b", 30)]))
        #expect(outcome == .unchanged)
        #expect(transcript.rows.count == 2)
    }

    @Test("sub-pixel drift does not duplicate a row")
    func toleratesDrift() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30)]))
        transcript.ingest(snap([("a", 0.4), ("b", 30.6)]))
        #expect(transcript.rows.map(\.text) == ["a", "b"])
    }

    // A reflowed or resized row would drag a mean-based estimate and corrupt every later position.
    @Test("displacement uses the median so one odd anchor cannot skew it")
    func medianResistsOutlier() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30), ("c", 60), ("d", 90)]))
        // a, b, c all moved up 20; "d" reflowed and appears to have moved 200.
        let outcome = transcript.ingest(snap([("a", -20), ("b", 10), ("c", 40), ("d", -110)]))
        guard case .merged(_, let displacement, _) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(displacement == 20)
    }

    @Test("no shared row falls back to the commanded displacement and records a gap")
    func estimatesWhenNoAnchor() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30)]))
        let outcome = transcript.ingest(snap([("y", 0), ("z", 30)]), commandedDisplacement: 400)
        guard case .estimated(let added, let assumed) = outcome else {
            Issue.record("expected estimated, got \(outcome)")
            return
        }
        #expect(added == 2)
        #expect(assumed == 400)
        #expect(transcript.gapCount == 1)
        #expect(transcript.rows.map(\.text) == ["a", "b", "y", "z"])
    }

    // A gap is a hole in document space, not merely a large offset change. Content can travel a
    // long way and still land flush against what we already had, in which case nothing was missed
    // and recording a gap would be a lie.
    @Test("a large displacement that lands flush records no gap")
    func largeDisplacementWithoutVoidIsNotAGap() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30), ("shared", 60)]))
        // "shared" moved 500pt, but the new row sits directly after it in the document.
        transcript.ingest(snap([("shared", -440), ("far", -410)]))
        #expect(transcript.gapCount == 0)
        #expect(transcript.rows.map(\.text) == ["a", "b", "shared", "far"])
    }

    // The key property, stated as a test: an anchor is a row visible in *both* viewports, so its
    // existence proves they overlap and nothing passed between them. A measured merge therefore
    // cannot have skipped content, however far the offset moved.
    @Test("a measured merge never records a gap, however large the displacement")
    func measuredMergeIsNeverAGap() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30), ("shared", 60)]))
        transcript.ingest(snap([("shared", -940), ("far", -910)]))
        #expect(transcript.gapCount == 0)
    }

    @Test("a long scroll reconstructs the source exactly with no gaps")
    func longScrollRoundTrip() {
        let source = (1...120).map { "message \($0)" }
        var transcript = ScrollTranscript()
        let rowHeight = 24.0

        var offset = 0
        while offset < source.count {
            let window = Array(source[offset..<min(offset + 20, source.count)])
            let rows = window.enumerated().map { index, text in
                // Content scrolls up as the viewport advances.
                CapturedRow(text: text, y: Double(index) * rowHeight - Double(offset) * rowHeight)
            }
            transcript.ingest(rows)
            offset += 12
        }

        #expect(transcript.rows.map(\.text) == source)
        #expect(transcript.gapCount == 0)
    }

    // The case that defeats run matching entirely: a viewport exposing only two rows can never
    // produce a run of three, so every merge degrades to a gap.
    @Test("a viewport too small to form a run still merges cleanly")
    func tinyViewport() {
        let source = (1...30).map { "row \($0)" }
        var transcript = ScrollTranscript()
        let rowHeight = 40.0

        var offset = 0
        while offset < source.count {
            let window = Array(source[offset..<min(offset + 2, source.count)])
            let rows = window.enumerated().map { index, text in
                CapturedRow(text: text, y: Double(index) * rowHeight - Double(offset) * rowHeight)
            }
            transcript.ingest(rows)
            offset += 1
        }

        #expect(transcript.rows.map(\.text) == source)
        #expect(transcript.gapCount == 0)
    }

    @Test("gap indices point at the row preceding the skipped span")
    func gapIndicesPlacement() {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30)]))
        transcript.ingest(snap([("y", 0), ("z", 30)]), commandedDisplacement: 400)
        let indices = transcript.gapIndices()
        #expect(indices.count == 1)
        #expect(transcript.rows[indices[0]].text == "b")
    }
}

@Suite("ScrollTranscript gap navigation")
struct ScrollTranscriptGapNavigationTests {

    /// Builds a transcript with one gap sitting above the current viewport.
    private func transcriptWithGapAbove() -> ScrollTranscript {
        var transcript = ScrollTranscript()
        transcript.ingest(snap([("a", 0), ("b", 30)]))
        // No shared row: displacement assumed, so a gap is recorded between 30 and 400.
        transcript.ingest(snap([("y", 400), ("z", 430)]), commandedDisplacement: 0)
        return transcript
    }

    @Test("a gap earlier in the document reports as above the viewport")
    func gapAbove() {
        let transcript = transcriptWithGapAbove()
        // Viewport sits entirely past the gap span (30...400) — touching it would count as within.
        let counts = transcript.gapsRelativeToViewport(screenRange: 410...460)
        #expect(counts.above == 1)
        #expect(counts.below == 0)
    }

    @Test("a gap later in the document reports as below the viewport")
    func gapBelow() {
        let transcript = transcriptWithGapAbove()
        // Viewport back at the start, entirely before the gap span (30...400).
        let counts = transcript.gapsRelativeToViewport(screenRange: 0...20)
        #expect(counts.above == 0)
        #expect(counts.below == 1)
    }

    // Neither arrow should point anywhere while the gap is on screen.
    @Test("a gap overlapping the viewport reports in neither direction")
    func gapWithinViewport() {
        let transcript = transcriptWithGapAbove()
        let counts = transcript.gapsRelativeToViewport(screenRange: 0...440)
        #expect(counts.above == 0)
        #expect(counts.below == 0)
    }

    // A marker that never clears trains the user to ignore it.
    @Test("scrolling back over a gap closes it")
    func observingClosesGap() {
        var transcript = transcriptWithGapAbove()
        #expect(transcript.gapCount == 1)
        // Re-observe the skipped ground, anchored to content we already have.
        transcript.ingest(snap([("b", 30), ("mid1", 150), ("mid2", 300), ("y", 400)]))
        #expect(transcript.gapCount == 0)
    }

    @Test("partially covering a gap leaves the uncovered remainder")
    func partialCoverageLeavesRemainder() {
        var transcript = transcriptWithGapAbove()
        // Only the lower half of the 30...400 span is observed.
        transcript.ingest(snap([("b", 30), ("mid", 200)]))
        #expect(transcript.gapCount == 1)
        let span = transcript.gapSpans[0]
        #expect(span.lowerBound == 200)
        #expect(span.upperBound == 400)
    }
}

@Suite("ScrollTranscript horizontal scrolling")
struct ScrollTranscriptHorizontalTests {

    /// Snapshot from (text, y, x) triples.
    private func grid(_ items: [(String, Double, Double)]) -> [CapturedRow] {
        items.map { CapturedRow(text: $0.0, y: $0.1, x: $0.2) }
    }

    // A wide table is scrolled sideways: every row keeps its height and only x changes. A y-only
    // model reads that as "nothing moved" and captures a single viewport.
    @Test("sideways scrolling reveals new columns and places them correctly")
    func horizontalScroll() {
        var transcript = ScrollTranscript()
        transcript.ingest(grid([("A1", 0, 0), ("B1", 0, 100), ("A2", 30, 0), ("B2", 30, 100)]))
        // Scrolled right by 100: column A leaves, column C arrives.
        let outcome = transcript.ingest(grid([
            ("B1", 0, 0), ("C1", 0, 100), ("B2", 30, 0), ("C2", 30, 100),
        ]))

        guard case .merged(let added, _, _) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(added == 2)
        // Reading order: across each row, then down.
        #expect(transcript.rows.map(\.text) == ["A1", "B1", "C1", "A2", "B2", "C2"])
    }

    @Test("purely horizontal movement is still a measured merge, not a gap")
    func horizontalIsNotAGap() {
        var transcript = ScrollTranscript()
        transcript.ingest(grid([("keep", 0, 0), ("edge", 0, 200)]))
        transcript.ingest(grid([("edge", 0, 0), ("new", 0, 200)]))
        #expect(transcript.gapCount == 0)
        #expect(transcript.rows.map(\.text) == ["keep", "edge", "new"])
    }

    // Identical text repeated across columns is the normal case in a table; picking the nearest
    // anchor by vertical distance alone would match the wrong cell.
    @Test("repeated cell text across columns does not corrupt the displacement")
    func repeatedCellsAcrossColumns() {
        var transcript = ScrollTranscript()
        transcript.ingest(grid([("Yes", 0, 0), ("No", 0, 100), ("Yes", 0, 200)]))
        transcript.ingest(grid([("No", 0, -100), ("Yes", 0, 0), ("Maybe", 0, 100)]))
        #expect(transcript.rows.map(\.text) == ["Yes", "No", "Yes", "Maybe"])
    }

    @Test("diagonal movement is measured on both axes")
    func diagonalScroll() {
        var transcript = ScrollTranscript()
        transcript.ingest(grid([("a", 0, 0), ("b", 50, 50)]))
        transcript.ingest(grid([("b", 20, 10), ("c", 70, 60)]))
        #expect(transcript.rows.map(\.text) == ["a", "b", "c"])
        #expect(transcript.gapCount == 0)
    }
}

@Suite("ScrollTranscript OCR consensus")
struct ScrollTranscriptConsensusTests {

    private func ocr(_ items: [(String, Double)]) -> [CapturedRow] {
        items.map { CapturedRow(text: $0.0, role: "OCRLine", y: $0.1) }
    }

    private func ax(_ items: [(String, Double)]) -> [CapturedRow] {
        items.map { CapturedRow(text: $0.0, role: "AXStaticText", y: $0.1) }
    }

    // A line seen three times, misread once: the majority should decide, not arrival order.
    @Test("the most frequently observed reading wins")
    func majorityWins() {
        var transcript = ScrollTranscript()
        let good = "5. Markers/overlay circling or identifying what it is referencing"
        let bad = "• Markers/overlay circling or identifying what it is referencing"

        transcript.ingest(ocr([("anchor line for displacement", 0), (bad, 40)]))
        transcript.ingest(ocr([("anchor line for displacement", 0), (good, 40)]))
        transcript.ingest(ocr([("anchor line for displacement", 0), (good, 40)]))

        #expect(transcript.rows.map(\.text).contains(good))
        #expect(!transcript.rows.map(\.text).contains(bad))
    }

    // Without consensus these are two rows a few points apart, both surviving.
    @Test("readings of one line collapse to a single row")
    func collapsesToOneRow() {
        var transcript = ScrollTranscript()
        transcript.ingest(ocr([("The quick brown fox jumps over", 0)]))
        transcript.ingest(ocr([("The quick br0wn fox jumps over", 2)]))
        #expect(transcript.rows.count == 1)
    }

    @Test("a tie is broken toward the longer reading")
    func tieBreaksLonger() {
        var transcript = ScrollTranscript()
        let full = "- Putting something to show user what Ironhand is referencing"
        let clipped = "Putting something to show user what Ironhand is referencing"
        transcript.ingest(ocr([(clipped, 0)]))
        transcript.ingest(ocr([(full, 1)]))
        #expect(transcript.rows.map(\.text) == [full])
    }

    // Accessibility text is verbatim, so two similar short labels are genuinely different things
    // and merging them would corrupt the transcript.
    @Test("accessibility rows are matched exactly, never approximately")
    func accessibilityRowsAreExact() {
        var transcript = ScrollTranscript()
        transcript.ingest(ax([("Reply to Sarah", 0), ("Reply to Sarih", 20)]))
        #expect(transcript.rows.count == 2)
    }

    @Test("genuinely different OCR lines are not merged")
    func differentLinesSurvive() {
        var transcript = ScrollTranscript()
        transcript.ingest(ocr([
            ("1. Bigger button for quick chat showing core feature", 0),
            ("2. Zooming in on just the camera", 40),
        ]))
        #expect(transcript.rows.count == 2)
    }
}
