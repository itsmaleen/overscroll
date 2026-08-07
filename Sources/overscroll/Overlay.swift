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
    func overlayDidToggleAutoScroll()
    func overlayDidToggleOCR()
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
    /// Whether the capture is reading pixels rather than the accessibility tree.
    var ocrMode: Bool = false { didSet { needsDisplay = true } }
    /// Whether an unattended scroll-to-the-end is running.
    var autoScrolling: Bool = false { didSet { needsDisplay = true } }

    /// Unobserved spans sitting before / after what is currently on screen. Drives the arrows that
    /// point the user back toward content the capture missed.
    var gapsAbove: Int = 0 { didSet { syncAnimation() } }
    var gapsBelow: Int = 0 { didSet { syncAnimation() } }

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
        capturedEdges.insert(edge)
        syncAnimation()
    }

    func clearCapturedEdges() {
        capturedEdges.removeAll()
        gapsAbove = 0
        gapsBelow = 0
        lastEdgeAdded = nil
        animationTimer?.invalidate()
        animationTimer = nil
        needsDisplay = true
    }

    /// Run the animation only while something on screen is actually animating.
    private func syncAnimation() {
        if capturedEdges.isEmpty && gapsAbove == 0 && gapsBelow == 0 {
            animationTimer?.invalidate()
            animationTimer = nil
        } else {
            startAnimating()
        }
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
            drawGapArrows(in: highlight)
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

    /// Arrows pointing toward content the capture skipped.
    ///
    /// Distinct from the edge glow on purpose. The glow is accent-coloured and means "content was
    /// captured from beyond here" — a success. These are amber, chevron-shaped, and drift *outward*
    /// in the direction the user must scroll to recover what was missed. Same surface, opposite
    /// meanings, so they must not be mistakable for one another.
    private func drawGapArrows(in rect: NSRect) {
        if gapsAbove > 0 { drawChevronStack(in: rect, pointingUp: true, count: gapsAbove) }
        if gapsBelow > 0 { drawChevronStack(in: rect, pointingUp: false, count: gapsBelow) }
    }

    private func drawChevronStack(in rect: NSRect, pointingUp: Bool, count: Int) {
        let amber = NSColor.systemOrange
        let chevronWidth: CGFloat = 22
        let chevronHeight: CGFloat = 9
        let spacing: CGFloat = 13
        let centerX = rect.midX
        let stackDepth = spacing * 3 + 30

        // A selection can sit hard against a screen edge, leaving no room outside it. Rather than
        // drawing the arrows off-screen where they would be invisible exactly when needed, fold
        // them inside the selection and keep pointing the same way.
        let roomOutside = pointingUp ? bounds.maxY - rect.maxY : rect.minY - bounds.minY
        let inside = roomOutside < stackDepth
        // Anchor just outside the edge normally, just inside it when folded.
        let baseAnchor = pointingUp
            ? (inside ? rect.maxY - 10 : rect.maxY + 10)
            : (inside ? rect.minY + 10 : rect.minY - 10)
        // Folding reverses which way the stack marches away from the anchor.
        let march: CGFloat = inside ? -1 : 1

        // The HUD is pinned to the bottom centre, exactly where the downward stack wants to live.
        // Push the stack clear of it rather than letting the count badge disappear behind it —
        // which is precisely when the user most needs to read it.
        var anchor = baseAnchor
        if !pointingUp {
            let hud = hudLayout().box
            if hud.intersects(NSRect(x: centerX - chevronWidth, y: bounds.minY,
                                     width: chevronWidth * 2, height: hud.maxY)) {
                // Lowest point the stack and its label will reach, before any correction.
                let reach = inside ? anchor : anchor - (spacing * 3 + 6) - 15
                let required = hud.maxY + 12
                if reach < required { anchor += required - reach }
            }
        }
        let anchorY = anchor

        // Continuous drift, so the motion reads as "keep going this way" rather than a blink.
        let travel = (animationPhase * 6).truncatingRemainder(dividingBy: spacing)

        for index in 0..<3 {
            let progress = CGFloat(index) * spacing + travel
            // Fade in as a chevron emerges and out as it reaches the end of its run.
            let span = spacing * 3
            let fade = 1 - abs((progress / span) * 2 - 1)
            let alpha = max(0, min(1, fade)) * 0.85
            guard alpha > 0.01 else { continue }

            let travelled = progress * march
            let baseY = pointingUp ? anchorY + travelled : anchorY - travelled
            // The tip always points the way the user must scroll, regardless of folding.
            let tipY = pointingUp ? baseY + chevronHeight : baseY - chevronHeight

            let path = NSBezierPath()
            path.move(to: NSPoint(x: centerX - chevronWidth / 2, y: baseY))
            path.line(to: NSPoint(x: centerX, y: tipY))
            path.line(to: NSPoint(x: centerX + chevronWidth / 2, y: baseY))
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            amber.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }

        let label = count == 1 ? "1 gap" : "\(count) gaps"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let labelTravel = (spacing * 3 + 6) * march
        let labelY = pointingUp
            ? anchorY + labelTravel
            : anchorY - labelTravel - size.height
        let box = NSRect(x: centerX - size.width / 2 - 6, y: labelY - 2, width: size.width + 12, height: size.height + 4)
        amber.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: centerX - size.width / 2, y: labelY), withAttributes: attrs)
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

    /// The HUD's frame and its rendered text, so other elements can avoid overlapping it.
    private func hudLayout() -> (box: NSRect, text: String, attrs: [NSAttributedString.Key: Any]) {
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
            parts.append("O: \(ocrMode ? "reading pixels" : "read pixels")")
            parts.append(autoScrolling ? "G: stop auto-scroll" : "G: auto-scroll to end")
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
        return (box, text, attrs)
    }

    private func drawHUD() {
        // Single source of truth: `hudLayout()` builds both the text and the frame, so the gap
        // arrows can avoid the box the HUD will actually occupy.
        let layout = hudLayout()
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: layout.box, xRadius: 10, yRadius: 10).fill()
        layout.text.draw(in: layout.box.insetBy(dx: 16, dy: 10), withAttributes: layout.attrs)
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
        case 31:      delegate?.overlayDidToggleOCR()             // O
        case 5:       delegate?.overlayDidToggleAutoScroll()      // G
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
