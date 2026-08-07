import Testing
@testable import OverscrollCore

@Suite("AutoScrollPacer")
struct AutoScrollPacerTests {

    @Test("keeps scrolling while steps yield content")
    func continuesWhileProductive() {
        var pacer = AutoScrollPacer()
        for _ in 0..<20 {
            #expect(pacer.next(rowsAdded: 4) == .scroll)
        }
    }

    @Test("stops once enough consecutive steps yield nothing")
    func stopsAtEnd() {
        var pacer = AutoScrollPacer(stopAfterStaleSteps: 3)
        #expect(pacer.next(rowsAdded: 0) == .scroll)
        #expect(pacer.next(rowsAdded: 0) == .scroll)
        #expect(pacer.next(rowsAdded: 0) == .stop(reason: "reached the end"))
    }

    // A single barren step is common mid-document — a figure, a wide table, a stretch the
    // recogniser fails on — and stopping there would end the capture in the middle.
    @Test("a lone barren step does not end the capture")
    func toleratesOneBarrenStep() {
        var pacer = AutoScrollPacer(stopAfterStaleSteps: 3)
        #expect(pacer.next(rowsAdded: 0) == .scroll)
        #expect(pacer.next(rowsAdded: 5) == .scroll)
        #expect(pacer.next(rowsAdded: 0) == .scroll)
        #expect(pacer.next(rowsAdded: 0) == .scroll)
        #expect(pacer.staleSteps == 2)
    }

    @Test("growth resets the stale counter")
    func growthResets() {
        var pacer = AutoScrollPacer(stopAfterStaleSteps: 3)
        _ = pacer.next(rowsAdded: 0)
        _ = pacer.next(rowsAdded: 0)
        _ = pacer.next(rowsAdded: 1)
        #expect(pacer.staleSteps == 0)
    }

    // An infinite feed never goes stale, so the stale rule alone would scroll forever.
    @Test("the step ceiling stops a view that never runs out")
    func stopsAtStepLimit() {
        var pacer = AutoScrollPacer(stopAfterStaleSteps: 3, maxSteps: 5)
        for _ in 0..<4 { #expect(pacer.next(rowsAdded: 2) == .scroll) }
        #expect(pacer.next(rowsAdded: 2) == .stop(reason: "stopped at the 5-step limit"))
    }

    // The two stops mean different things about whether the capture is complete.
    @Test("the reason distinguishes finishing from being cut off")
    func reasonsDiffer() {
        var ended = AutoScrollPacer(stopAfterStaleSteps: 1)
        var capped = AutoScrollPacer(stopAfterStaleSteps: 99, maxSteps: 1)
        #expect(ended.next(rowsAdded: 0) == .stop(reason: "reached the end"))
        #expect(capped.next(rowsAdded: 3) == .stop(reason: "stopped at the 1-step limit"))
    }

    @Test("reset returns it to a fresh state")
    func resets() {
        var pacer = AutoScrollPacer()
        _ = pacer.next(rowsAdded: 0)
        _ = pacer.next(rowsAdded: 0)
        pacer.reset()
        #expect(pacer.steps == 0)
        #expect(pacer.staleSteps == 0)
    }
}
