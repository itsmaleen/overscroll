import Testing
@testable import OverscrollCore

/// Builds a snapshot from (text, y) pairs.
private func snap(_ items: [(String, Double)]) -> [CapturedRow] {
    items.map { CapturedRow(text: $0.0, y: $0.1) }
}

private func texts(_ snapshots: [[CapturedRow]]) -> [[String]] {
    snapshots.map { $0.map(\.text) }
}

@Suite("ScrollingContentFilter")
struct ScrollingContentFilterTests {

    @Test("the first snapshot is held until there is something to compare it against")
    func holdsFirstSnapshot() {
        var filter = ScrollingContentFilter()
        #expect(filter.accept(snap([("a", 10), ("b", 30)])).isEmpty)
    }

    // The WhatsApp case: a sidebar row sitting at a fixed y, interleaved by position with message
    // rows that scroll past it.
    @Test("rows that stay at the same y are classified as chrome and removed")
    func removesStaticChrome() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("Chats", 20), ("msg one", 40), ("msg two", 80)]))
        let released = filter.accept(snap([("Chats", 20), ("msg one", 90), ("msg two", 130)]))

        #expect(filter.staticIdentities.contains("chats"))
        #expect(texts(released) == [["msg one", "msg two"], ["msg one", "msg two"]])
    }

    // Without this guard the very first non-scrolling read would mark every row static and blank
    // the entire capture.
    @Test("a view that did not move teaches nothing")
    func noMovementLearnsNothing() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("a", 10), ("b", 30)]))
        let released = filter.accept(snap([("a", 10), ("b", 30)]))
        #expect(filter.staticIdentities.isEmpty)
        #expect(released.isEmpty)
    }

    @Test("sub-pixel jitter is not movement")
    func toleratesJitter() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("header", 20), ("body", 60)]))
        let released = filter.accept(snap([("header", 20.7), ("body", 140)]))
        #expect(filter.staticIdentities.contains("header"))
        #expect(texts(released) == [["body"], ["body"]])
    }

    @Test("chrome learned later is stripped from the held snapshot too")
    func stripsHeldSnapshotRetroactively() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("toolbar", 5), ("one", 40)]))
        let released = filter.accept(snap([("toolbar", 5), ("one", 100), ("two", 140)]))
        // "toolbar" must not survive in the first released snapshot even though it was captured
        // before there was any way to know it was static.
        #expect(released[0].map(\.text) == ["one"])
        #expect(released[1].map(\.text) == ["one", "two"])
    }

    @Test("everything moving means nothing is chrome")
    func allContentMoves() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("a", 10), ("b", 50)]))
        let released = filter.accept(snap([("a", 70), ("b", 110)]))
        #expect(filter.staticIdentities.isEmpty)
        #expect(texts(released) == [["a", "b"], ["a", "b"]])
    }

    @Test("flush returns a held snapshot when the view never scrolled")
    func flushReturnsHeld() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("a", 10), ("b", 30)]))
        #expect(filter.flush().map(\.text) == ["a", "b"])
        #expect(filter.flush().isEmpty)
    }

    @Test("later snapshots are filtered by chrome already learned")
    func filtersSubsequentSnapshots() {
        var filter = ScrollingContentFilter()
        _ = filter.accept(snap([("nav", 5), ("one", 40)]))
        _ = filter.accept(snap([("nav", 5), ("one", 100)]))
        let third = filter.accept(snap([("nav", 5), ("one", 160), ("two", 200)]))
        #expect(third.count == 1)
        #expect(third[0].map(\.text) == ["one", "two"])
    }

    // End to end: the exact failure this exists to prevent. Interleaved chrome makes consecutive
    // snapshots share no contiguous run, so every merge becomes a gap and rows duplicate.
    @Test("filtering restores clean merges through the accumulator")
    func restoresCleanMerges() {
        let source = (1...40).map { "message \($0)" }
        var filter = ScrollingContentFilter()
        var unfiltered = ScrollAccumulator()
        var filtered = ScrollAccumulator()

        var offset = 0
        while offset < source.count {
            let window = Array(source[offset..<min(offset + 10, source.count)])
            // Chrome pinned at y=50 lands in the middle of the moving rows and its relative
            // position in the sequence changes every step.
            var rows = window.enumerated().map { index, text in
                CapturedRow(text: text, y: Double(100 - offset * 8 + index * 16))
            }
            rows.append(CapturedRow(text: "SIDEBAR", y: 50))
            rows.sort { $0.y < $1.y }

            unfiltered.ingest(rows)
            for release in filter.accept(rows) { filtered.ingest(release) }
            offset += 4
        }

        // Unfiltered: chrome reshuffles the sequence, so merges fail and rows pile up duplicated.
        #expect(!unfiltered.gapIndices.isEmpty)
        #expect(unfiltered.rows.count > source.count)

        // Filtered: clean reconstruction, no gaps, no duplicates, no chrome.
        #expect(filtered.gapIndices.isEmpty)
        #expect(filtered.rows.map(\.text) == source)
        #expect(!filtered.rows.contains { $0.text == "SIDEBAR" })
    }
}
