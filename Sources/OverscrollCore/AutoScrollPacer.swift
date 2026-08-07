import Foundation

/// Decides whether an unattended capture should keep scrolling.
///
/// Scrolling by hand is the main labour in a long capture, and people are bad at the one thing it
/// requires: waiting. A fast flick outruns the harvest — measured on a real page, a hurried scroll
/// produced 3-row reads where a paused one produced 15 — so the content is on screen for less time
/// than it takes to read it. Driving the scroll from the *completion* of each harvest removes that
/// failure mode entirely, because the next step cannot start until the last one has been read.
///
/// Kept separate from the capture controller so the stopping rule is testable without a window, a
/// permission grant, or a real app to scroll.
public struct AutoScrollPacer: Sendable {

    /// Consecutive steps that add nothing before concluding the end has been reached.
    ///
    /// More than one, because a single barren step is common mid-document: a step can land on a
    /// figure, a wide table, or a stretch the recogniser fails on, and stopping there would end the
    /// capture in the middle with no indication anything was missed.
    public let stopAfterStaleSteps: Int

    /// Hard ceiling on steps. A backstop against a view that scrolls forever — an infinite feed, or
    /// content that regenerates as it is read — where the stale rule would never fire.
    public let maxSteps: Int

    public private(set) var steps = 0
    public private(set) var staleSteps = 0

    public init(stopAfterStaleSteps: Int = 3, maxSteps: Int = 300) {
        self.stopAfterStaleSteps = stopAfterStaleSteps
        self.maxSteps = maxSteps
    }

    public enum Decision: Sendable, Equatable {
        case scroll
        /// Stopped, with a reason worth showing the user — "reached the end" and "hit the step
        /// limit" mean very different things about whether the capture is complete.
        case stop(reason: String)
    }

    /// Report what the last step yielded and decide whether to take another.
    public mutating func next(rowsAdded: Int) -> Decision {
        steps += 1
        staleSteps = rowsAdded > 0 ? 0 : staleSteps + 1

        if staleSteps >= stopAfterStaleSteps {
            return .stop(reason: "reached the end")
        }
        if steps >= maxSteps {
            return .stop(reason: "stopped at the \(maxSteps)-step limit")
        }
        return .scroll
    }

    public mutating func reset() {
        steps = 0
        staleSteps = 0
    }
}
