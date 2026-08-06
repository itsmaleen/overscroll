import AppKit
import OverscrollAX

/// Main-actor isolated: every callback originates from an AppKit event and lands in UI state.
@MainActor
protocol OverlayDelegate: AnyObject {
    func overlayDidDragRegion(_ rect: NSRect)
    func overlayDidCommitRegion(_ rect: NSRect)
    /// `committing` distinguishes a hover preview from a click that selects. Passed explicitly
    /// rather than inferred from the current event, which is ambiguous by the time it's read.
    func overlayDidPickWindow(at point: NSPoint, committing: Bool)
    func overlayDidRequestScroll(_ direction: Scroller.Direction)
    func overlayDidFinish()
    func overlayDidCancel()
    func overlayDidToggleWindowPicking()
    func overlayDidToggleKeepImage()
}

/// A side of the selection that captured content extends beyond.
///
/// Scrolling pulls in content the box was never physically over, which otherwise leaves the user
/// with no way to tell whether a scroll accomplished anything. Marking the edge it came from makes
/// the invisible part of the capture visible.
enum CaptureEdge: Hashable {
    case top, bottom, left, right

    init(scrolling direction: Scroller.Direction) {
        switch direction {
        case .up: self = .top        // scrolling up reveals content above the box
        case .down: self = .bottom
        case .left: self = .left
        case .right: self = .right
        }
    }
}

enum OverlayMode {
    /// Drawing the rectangle by dragging.
    case selecting
    /// Hovering to choose a whole window instead of dragging a rectangle.
    case pickingWindow
    /// Region fixed; scrolling and harvesting.
    case locked
}

/// Full-screen borderless window that hosts the selection UI.
///
/// Once the region is locked the window turns mouse-transparent, which is what lets the trackpad
/// keep scrolling the app underneath while the window still holds keyboard focus for WASD. That is
/// the whole reason both input modes can coexist rather than one replacing the other.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above normal windows and full-screen apps, below the screen saver's own chrome.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }
}

final class OverlayView: NSView {
    weak var delegate: OverlayDelegate?

    var mode: OverlayMode = .selecting { didSet { needsDisplay = true } }
    /// Selection rectangle in this view's coordinate space.
    var selection: NSRect? { didSet { needsDisplay = true } }
    /// Rectangle of the window under the cursor, while picking.
    var hoveredWindow: NSRect? { didSet { needsDisplay = true } }
    var statusText: String = "" { didSet { needsDisplay = true } }
    var keepImage: Bool = false { didSet { needsDisplay = true } }
    /// Whether scrolling can do anything yet. Until a target window is resolved the keys are inert,
    /// and advertising them just invites the user to press something that does nothing.
    var scrollAvailable: Bool = false { didSet { needsDisplay = true } }
    var rowCount: Int = 0 { didSet { needsDisplay = true } }

    /// Edges that captured content extends past, with the animation running while any exist.
    private(set) var capturedEdges: Set<CaptureEdge> = []
    private var lastEdgeAdded: (edge: CaptureEdge, at: Date)?
    private var animationPhase: CGFloat = 0
    private var animationTimer: Timer?

    private var dragOrigin: NSPoint?

    deinit { animationTimer?.invalidate() }

    /// Record that a scroll in this direction actually brought in new content.
    func noteCapturedEdge(_ edge: CaptureEdge) {
        lastEdgeAdded = (edge, Date())
        let isNew = capturedEdges.insert(edge).inserted
        if isNew || animationTimer == nil { startAnimating() }
        needsDisplay = true
    }

    func clearCapturedEdges() {
        capturedEdges.removeAll()
        lastEdgeAdded = nil
        animationTimer?.invalidate()
        animationTimer = nil
        needsDisplay = true
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        // 30fps is plenty for a slow pulse and keeps the overlay from competing with the app being
        // scrolled underneath it.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationPhase += 0.12
            self.needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let highlight = (mode == .pickingWindow) ? hoveredWindow : selection

        NSColor.black.withAlphaComponent(0.28).setFill()
        if let highlight {
            // Dim everything except the chosen region, so the user can read the content they're
            // about to capture at full contrast while still seeing the boundary.
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: highlight))
            path.windingRule = .evenOdd
            path.fill()

            drawEdgeIndicators(in: highlight)

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: highlight)
            border.lineWidth = mode == .locked ? 2.5 : 1.5
            if mode != .locked {
                border.setLineDash([6, 4], count: 2, phase: 0)
            }
            border.stroke()
            drawDimensions(for: highlight)
        } else {
            bounds.fill()
        }

        drawHUD()
    }

    /// Glow along each edge that captured content extends beyond.
    ///
    /// The box stays put while the content moves under it, so without this there is no way to see
    /// that a scroll pulled anything in — or from which direction. A steady pulse means "this side
    /// holds captured content you can no longer see"; a brief brighter flash marks the edge that
    /// just grew.
    private func drawEdgeIndicators(in rect: NSRect) {
        guard !capturedEdges.isEmpty else { return }

        let depth: CGFloat = 28
        let pulse = 0.30 + 0.16 * sin(animationPhase)

        for edge in capturedEdges {
            // The edge that just received content flashes brighter, decaying over ~0.7s.
            var intensity = pulse
            if let recent = lastEdgeAdded, recent.edge == edge {
                let age = Date().timeIntervalSince(recent.at)
                if age < 0.7 { intensity += 0.45 * (1 - age / 0.7) }
            }

            let band: NSRect
            let angle: CGFloat
            switch edge {
            case .top:
                band = NSRect(x: rect.minX, y: rect.maxY - depth, width: rect.width, height: depth)
                angle = 270  // strongest at the top, fading inward
            case .bottom:
                band = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: depth)
                angle = 90
            case .left:
                band = NSRect(x: rect.minX, y: rect.minY, width: depth, height: rect.height)
                angle = 0
            case .right:
                band = NSRect(x: rect.maxX - depth, y: rect.minY, width: depth, height: rect.height)
                angle = 180
            }

            let gradient = NSGradient(
                colors: [
                    NSColor.controlAccentColor.withAlphaComponent(min(1, intensity)),
                    NSColor.controlAccentColor.withAlphaComponent(0),
                ]
            )
            gradient?.draw(in: band, angle: angle)
        }
    }

    private func drawDimensions(for rect: NSRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        let background = NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attrs)
    }

    private func drawHUD() {
        // Only advertise keys that currently do something. Listing scroll keys before a target
        // window is resolved invites the user to press them and conclude the app is broken.
        var parts: [String] = []
        switch mode {
        case .selecting:
            parts.append("Drag to select")
            if scrollAvailable { parts.append("WASD/arrows scroll") }
            parts.append("Space: pick window")
        case .pickingWindow:
            parts.append("Click a window")
            parts.append("Space: back to drag")
        case .locked:
            if scrollAvailable { parts.append("WASD/arrows or trackpad to scroll") }
            parts.append("I: image \(keepImage ? "ON" : "off")")
            // Copying nothing is not a meaningful action, so the key stays hidden until it is.
            if rowCount > 0 { parts.append("Return: copy \(rowCount) rows") }
        }
        parts.append("Esc: cancel")

        let hint = parts.joined(separator: "  ·  ")
        let text = statusText.isEmpty ? hint : "\(hint)\n\(statusText)"

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(
            x: bounds.midX - size.width / 2 - 16,
            y: bounds.minY + 48,
            width: size.width + 32,
            height: size.height + 20
        )
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(
            in: box.insetBy(dx: 16, dy: 10),
            withAttributes: attrs
        )
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if mode == .pickingWindow {
            delegate?.overlayDidPickWindow(at: point, committing: true)
            return
        }
        dragOrigin = point
        selection = NSRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .selecting, let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        selection = rect
        delegate?.overlayDidDragRegion(rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .selecting, let rect = selection else { return }
        dragOrigin = nil
        // A click without a drag is almost always a misfire, not a request to capture a 3-pixel box.
        guard rect.width > 12, rect.height > 12 else {
            selection = nil
            return
        }
        delegate?.overlayDidCommitRegion(rect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .pickingWindow else { return }
        delegate?.overlayDidPickWindow(at: convert(event.locationInWindow, from: nil), committing: false)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        DebugLog.log("keyDown code=\(event.keyCode) windowIsKey=\(window?.isKeyWindow ?? false)")
        // Key codes, not characters: WASD must work regardless of the active keyboard layout, and
        // the arrow keys have no character representation at all.
        switch event.keyCode {
        case 13, 126: delegate?.overlayDidRequestScroll(.up)      // W, ↑
        case 1,  125: delegate?.overlayDidRequestScroll(.down)    // S, ↓
        case 0,  123: delegate?.overlayDidRequestScroll(.left)    // A, ←
        case 2,  124: delegate?.overlayDidRequestScroll(.right)   // D, →
        case 36, 76:  delegate?.overlayDidFinish()                // Return, Enter
        case 53:      delegate?.overlayDidCancel()                // Esc
        case 49:      delegate?.overlayDidToggleWindowPicking()   // Space
        case 34:      delegate?.overlayDidToggleKeepImage()       // I
        default:      super.keyDown(with: event)
        }
    }

    // No `performKeyEquivalent` override here, deliberately.
    //
    // It was added to suppress the system beep and returned `true` for every key this view cares
    // about — which AppKit reads as "handled". Because `performKeyEquivalent` runs *before*
    // `keyDown` in the responder chain, that swallowed W/A/S/D, the arrows, Return, Space and Esc
    // outright: `keyDown` was never reached, so scrolling did nothing and the overlay could not
    // even be dismissed. `keyDown` already consumes these keys without calling `super`, so nothing
    // beeps and nothing needs intercepting earlier.
}
