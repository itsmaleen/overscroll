import CoreGraphics
import Foundation

/// Posts synthetic scroll events into another application.
///
/// Events go to the target process directly rather than through the HID tap. Hit testing at the HID
/// layer routes by cursor location, which would send the scroll to our own full-screen overlay
/// instead of the window beneath it, and working around that means toggling the overlay's mouse
/// transparency around every event — a race for no benefit.
public enum Scroller {
    public enum Direction {
        case up, down, left, right

        /// Vertical and horizontal deltas. Positive `wheel1` scrolls content down (view moves up),
        /// matching natural-direction trackpad semantics.
        func deltas(step: Int32) -> (vertical: Int32, horizontal: Int32) {
            switch self {
            case .up:    return (step, 0)
            case .down:  return (-step, 0)
            case .left:  return (0, step)
            case .right: return (0, -step)
            }
        }
    }

    /// Pixels per keypress. Deliberately well under a typical viewport height: the accumulator can
    /// only stitch two snapshots that still share a run of rows, so a step that outruns the viewport
    /// produces a gap in the transcript. Small steps cost extra harvests, which are cheap.
    ///
    /// Measured against WhatsApp, where messages are tall and only a handful are exposed at once:
    /// a 20px step produced gaps on 4 of 10 merges, 40px on 9 of 10. The original 120px was far too
    /// aggressive; this is only a starting point, which `AdaptiveScrollStep` tunes from.
    public static let defaultStep: Int32 = 60

    /// Self-tuning step size.
    ///
    /// The workable step depends on how tall the target's rows are and how many it exposes at a
    /// time, which varies per app and even per conversation — so there is no good fixed default.
    /// Halving on a gap and creeping back up on clean merges converges within a few keypresses,
    /// without asking the user to know or care.
    public struct AdaptiveScrollStep: Sendable {
        public private(set) var current: Int32
        private let minimum: Int32
        private let maximum: Int32

        public init(start: Int32 = 60, minimum: Int32 = 15, maximum: Int32 = 180) {
            self.current = start
            self.minimum = minimum
            self.maximum = maximum
        }

        /// A gap means the step outran the shared run; back off hard.
        public mutating func registerGap() {
            current = max(minimum, current / 2)
        }

        /// A clean merge means there is headroom; recover gradually, so one lucky step doesn't
        /// immediately undo a back-off.
        public mutating func registerCleanMerge() {
            current = min(maximum, current + 8)
        }
    }

    public static func scroll(_ direction: Direction, step: Int32 = defaultStep, toPID pid: pid_t) {
        let (vertical, horizontal) = direction.deltas(step: step)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }
        event.postToPid(pid)
    }

    /// Fallback for apps that ignore per-process scroll events. Routes through the HID tap, which
    /// hit-tests at `point`, so the caller must make the overlay mouse-transparent first.
    public static func scrollViaHID(_ direction: Direction, step: Int32 = defaultStep, at point: CGPoint) {
        let (vertical, horizontal) = direction.deltas(step: step)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}
