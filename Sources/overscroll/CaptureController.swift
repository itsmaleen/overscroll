import AppKit
import OverscrollAX
import OverscrollCore

/// Drives one capture from hotkey to clipboard.
///
/// State machine: select a region (by drag or by window pick) → lock it → scroll and harvest
/// repeatedly → emit markdown. Scrolling is available in *every* state, including mid-drag, because
/// while positioning the rectangle the trackpad is already occupied and the keyboard is the only
/// free hand.
@MainActor
final class CaptureController: NSObject, OverlayDelegate {

    private var window: OverlayWindow?
    private var view: OverlayView?

    /// Geometry-based merge: tracks where content sits in the document rather than matching runs
    /// of text. Measured against WhatsApp it removed gaps entirely (0 vs 14 on the same snapshot
    /// stream) because a single shared row is enough to place a snapshot, where run alignment
    /// needed three consecutive ones and a chat client rarely exposes that many.
    private var transcript = ScrollTranscript()
    /// Strips the static chrome a dragged region inevitably includes. Without it, sidebar and
    /// toolbar rows interleave with the scrolling content by y-position and reshuffle on every
    /// scroll, which destroys the run alignment the accumulator depends on.
    private var contentFilter = ScrollingContentFilter()
    private var target: WindowTarget?
    private var windowElement: AXUIElement?
    private var regionCG: CGRect = .zero
    private var keepImage = false
    private var usedOCR = false
    private var usedAX = false

    private var scrollMonitor: Any?
    /// Catches Esc and Return even when the overlay is not the key window.
    ///
    /// Load-bearing, not a nicety: once the region locks the overlay becomes mouse-transparent, so
    /// a click passes through to another app, that app becomes key, and the overlay never receives
    /// another keyDown. Without a global monitor the user is left with a full-screen dim layer and
    /// no way to dismiss it.
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// Hard stop. Whatever else fails, a capture cannot own the screen indefinitely.
    private var watchdog: Timer?
    private var lastActivity = Date()
    private var harvestWorkItem: DispatchWorkItem?
    /// Scrolls issued since the content last actually changed.
    ///
    /// This is the signal that per-process scroll events are being ignored — *not* an empty
    /// harvest, which was the original and wrong test. An app that ignores `postToPid` still
    /// reports its accessibility tree perfectly well; the rows come back fine, they simply never
    /// move. Waiting for an empty read means the fallback never fires and the whole capture is one
    /// viewport repeated.
    private var scrollsSinceChange = 0
    private var useHIDScroll = false

    var isActive: Bool { window != nil }

    /// Dismiss a capture from outside the overlay's own event handling.
    func cancelIfActive() {
        guard isActive else { return }
        overlayDidCancel()
    }

    // MARK: - Lifecycle

    func begin() {
        guard !isActive else { return }
        guard Permissions.missingDescription(requireScreenRecording: false) == nil else {
            Notifier.warn(Permissions.missingDescription(requireScreenRecording: false)!)
            Permissions.requestAccessibility()
            return
        }

        transcript = ScrollTranscript()
        contentFilter = ScrollingContentFilter()
        lastHint = .unknown
        target = nil
        windowElement = nil
        regionCG = .zero
        usedOCR = false
        usedAX = false
        scrollsSinceChange = 0
        useHIDScroll = false

        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let window = OverlayWindow(frame: frame)
        let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.delegate = self
        window.contentView = view

        self.window = window
        self.view = view

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        DebugLog.start("capture begin")
        installEscapeHatches()
    }

    /// Three independent ways out, because the overlay covers everything and any single mechanism
    /// that depends on focus can be lost.
    private func installEscapeHatches() {
        lastActivity = Date()

        // 1. Global monitor: fires regardless of which app is key.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handleGlobalKey(event) }
        }
        // 2. Local monitor: covers the case where we *are* key but the responder chain misroutes.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            if event.keyCode == 53 { self.overlayDidCancel(); return nil }
            return event
        }
        // 3. Watchdog: an abandoned capture tears itself down rather than owning the screen.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if Date().timeIntervalSince(self.lastActivity) > 180 {
                    Notifier.warn("Capture timed out after 3 minutes of inactivity.")
                    self.overlayDidCancel()
                }
            }
        }
    }

    private func handleGlobalKey(_ event: NSEvent) {
        guard isActive else { return }
        switch event.keyCode {
        case 53: overlayDidCancel()
        case 36, 76: overlayDidFinish()
        default: break
        }
    }

    private func teardown() {
        harvestWorkItem?.cancel()
        harvestWorkItem = nil
        for monitor in [scrollMonitor, globalKeyMonitor, localKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        scrollMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        watchdog?.invalidate()
        watchdog = nil
        view?.clearCapturedEdges()
        window?.orderOut(nil)
        window = nil
        view = nil
    }

    // MARK: - OverlayDelegate

    func overlayDidDragRegion(_ rect: NSRect) {
        // Resolve the target as the rectangle is drawn, so WASD can scroll the content underneath
        // before the region is even committed.
        regionCG = ScreenSpace.cgRect(fromAppKit: screenRect(from: rect))
        if target == nil {
            resolveTarget(at: CGPoint(x: regionCG.midX, y: regionCG.midY))
        }
    }

    func overlayDidCommitRegion(_ rect: NSRect) {
        regionCG = ScreenSpace.cgRect(fromAppKit: screenRect(from: rect))
        resolveTarget(at: CGPoint(x: regionCG.midX, y: regionCG.midY))
        lockRegion()
    }

    func overlayDidPickWindow(at point: NSPoint, committing: Bool) {
        let cgPoint = ScreenSpace.cgPoint(fromAppKit: screenPoint(from: point))
        guard let found = WindowResolver.window(at: cgPoint) else { return }

        let appKitRect = ScreenSpace.appKitRect(fromCG: found.bounds)
        view?.hoveredWindow = viewRect(fromScreen: appKitRect)
        guard committing else { return }

        target = found
        regionCG = found.bounds
        windowElement = AXHarvester.windowElement(for: found)
        view?.selection = viewRect(fromScreen: appKitRect)
        lockRegion()
    }

    func overlayDidToggleWindowPicking() {
        guard let view, view.mode != .locked else { return }
        view.mode = (view.mode == .pickingWindow) ? .selecting : .pickingWindow
        view.hoveredWindow = nil
    }

    func overlayDidToggleKeepImage() {
        keepImage.toggle()
        view?.keepImage = keepImage
    }

    /// Direction of the most recent scroll, so an unplaceable snapshot lands on the correct side
    /// of the transcript instead of always being appended.
    private var lastHint: ScrollHint = .unknown
    private var scrollStep = Scroller.AdaptiveScrollStep()
    /// Edge the in-flight scroll would pull content from. Only marked on the overlay once a harvest
    /// confirms rows actually arrived — an edge that glows after a scroll into a dead end would be
    /// telling the user something false.
    private var pendingEdge: CaptureEdge?
    /// Direction of the last key-driven scroll, so it can be replayed if the route it used turns
    /// out to be a no-op for this app.
    private var lastScrollDirection: Scroller.Direction?

    func overlayDidRequestScroll(_ direction: Scroller.Direction) {
        lastActivity = Date()
        lastHint = (direction == .up) ? .towardStart : .towardEnd
        pendingEdge = CaptureEdge(scrolling: direction)
        lastScrollDirection = direction
        // Scrolling before a target exists: use whatever window is under the pointer.
        if target == nil {
            let mouse = ScreenSpace.cgPoint(fromAppKit: NSEvent.mouseLocation)
            resolveTarget(at: mouse)
        }
        guard let target else { return }

        // Do not scroll past content that has not been read yet. Each keypress moves the view, but
        // a harvest has to complete before the next move or the rows in between are never seen —
        // and the accumulator cannot bridge a jump it has no overlapping snapshot for. Bounding the
        // scroll rate by the harvest rate is what makes held-down keys safe.
        guard !harvestInFlight else {
            DebugLog.log("scroll \(direction) SKIPPED — harvest still in flight")
            view?.statusText = "\(transcript.rows.count) rows  ·  catching up…"
            return
        }

        scrollsSinceChange += 1
        DebugLog.log("scroll \(direction) step=\(scrollStep.current) "
            + "route=\(useHIDScroll ? "HID" : "pid") sinceChange=\(scrollsSinceChange)")

        if useHIDScroll {
            // HID events are hit-tested by location, so the overlay has to be transparent to them
            // or it swallows its own scroll. When locked it already is; mid-drag it is not, so the
            // transparency is lifted only for the moment the event is posted.
            let wasLocked = (view?.mode == .locked)
            window?.ignoresMouseEvents = true
            Scroller.scrollViaHID(
                direction, step: scrollStep.current,
                at: CGPoint(x: regionCG.midX, y: regionCG.midY)
            )
            if !wasLocked {
                DispatchQueue.main.async { [weak self] in
                    self?.window?.ignoresMouseEvents = false
                }
            }
        } else {
            Scroller.scroll(direction, step: scrollStep.current, toPID: target.pid)
        }
        // Shorter than the trackpad debounce: a keypress is one discrete move, so there is nothing
        // to coalesce — just enough delay for the app to lay out the newly revealed rows.
        scheduleHarvest(after: 0.09)
    }

    func overlayDidFinish() {
        guard let target else {
            Notifier.warn("Nothing captured.")
            teardown()
            return
        }
        // One last harvest so content revealed by the final scroll isn't dropped. Synchronous on
        // purpose: the async path would return after this method has already read the rows and
        // emitted. Blocking is acceptable here because the capture is over and every request is
        // bounded by the accessibility messaging timeout.
        if let windowElement, regionCG.width > 1, regionCG.height > 1 {
            ingest(AXHarvester.harvest(window: windowElement, region: regionCG))
        }
        // A capture where the user never scrolled leaves the first snapshot held for comparison
        // that never came. Releasing it unfiltered is the honest result — with no movement there
        // is no evidence about what was chrome.
        let held = contentFilter.flush()
        if !held.isEmpty { transcript.ingest(held, commandedDisplacement: commandedDisplacement) }
        DebugLog.log("FINISH rows=\(transcript.rows.count) gaps=\(transcript.gapCount) "
            + "flushed=\(held.count) route=\(useHIDScroll ? "HID" : "pid")")

        let rows = transcript.rows
        if rows.isEmpty {
            // No accessibility text at all — a canvas-rendered surface. Fall back to pixels.
            finishViaOCR(target: target)
            return
        }
        emit(rows: rows, target: target, mode: usedOCR ? .mixed : .accessibility, image: nil)
    }

    func overlayDidCancel() {
        teardown()
    }

    // MARK: - Capture

    private func resolveTarget(at point: CGPoint) {
        guard let found = WindowResolver.window(at: point) else { return }
        if found.windowID != target?.windowID {
            target = found
            windowElement = AXHarvester.windowElement(for: found)
        }
        // Scrolling only becomes meaningful once there is a window to scroll *and* an element tree
        // to read back from it; without the tree a scroll moves content we cannot capture.
        view?.scrollAvailable = (windowElement != nil)
    }

    private func lockRegion() {
        guard let view, let window else { return }
        view.mode = .locked
        // Mouse-transparent from here on, so the trackpad scrolls the app underneath while the
        // overlay keeps keyboard focus. Both input paths stay live at once.
        window.ignoresMouseEvents = true

        // Size the scroll step to the region rather than creeping up from a small constant.
        //
        // Under run alignment a big step was dangerous: overshoot the shared run and the merge
        // failed. Geometry only needs *one* row visible in both samples, so the real limit is
        // simply "less than a viewport", and a step well under that is both safe and far faster —
        // measured on WhatsApp, 300px captured 83 rows to 150px's 39, with no gaps either way.
        let step = Int32(max(60, min(600, regionCG.height * 0.6)))
        scrollStep = Scroller.AdaptiveScrollStep(
            start: step, minimum: 20, maximum: Int32(max(80, regionCG.height * 0.85))
        )

        DebugLog.log("region locked \(Int(regionCG.width))x\(Int(regionCG.height)) "
            + "target=\(target?.appName ?? "nil") axElement=\(windowElement != nil) step=\(step)")

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaY = event.scrollingDeltaY
            let deltaX = event.scrollingDeltaX
            Task { @MainActor in
                guard let self else { return }
                // A manual scroll carries the same directional information a keypress does, and the
                // accumulator needs it to place unalignable rows on the correct side. Positive
                // deltaY means the content moved down, i.e. the view went toward the start.
                if abs(deltaY) >= abs(deltaX), deltaY != 0 {
                    self.lastHint = deltaY > 0 ? .towardStart : .towardEnd
                    self.pendingEdge = deltaY > 0 ? .top : .bottom
                } else if deltaX != 0 {
                    self.lastHint = .unknown
                    self.pendingEdge = deltaX > 0 ? .left : .right
                }
                DebugLog.log("trackpad scroll dy=\(Int(deltaY)) dx=\(Int(deltaX))")
                self.lastActivity = Date()
                self.scheduleHarvest()
            }
        }
        harvestNow()
    }

    /// Coalesce harvests: a trackpad flick emits dozens of scroll events, and the app needs a beat
    /// to lay out the newly revealed rows before there is anything worth reading.
    private func scheduleHarvest(after delay: TimeInterval = 0.14) {
        harvestWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.harvestNow() }
        }
        harvestWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Serializes harvests; a slow one must not have a newer one land on top of it.
    private var harvestInFlight = false
    /// A harvest asked for while one was already running.
    ///
    /// It must be remembered rather than dropped. Discarding it means the position the content was
    /// in at that moment is never read, and since the accumulator can only join snapshots that
    /// share a run of rows, a skipped read shows up as a hole between where the content started and
    /// where it ended up.
    private var harvestQueued = false

    private func harvestNow() {
        guard let windowElement, regionCG.width > 1, regionCG.height > 1 else { return }
        if harvestInFlight {
            harvestQueued = true
            return
        }
        harvestInFlight = true
        // Off the main thread: a tree walk is thousands of synchronous round trips into another
        // process, and stalling the main thread would freeze the overlay the user needs to dismiss.
        AXHarvester.harvestAsync(window: windowElement, region: regionCG) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.harvestInFlight = false
                self.ingest(snapshot)
                if self.harvestQueued {
                    self.harvestQueued = false
                    self.harvestNow()
                }
            }
        }
    }

    private func ingest(_ snapshot: [CapturedRow]) {
        guard !snapshot.isEmpty else {
            DebugLog.log("harvest → 0 rows")
            return
        }
        usedAX = true
        var outcome = ScrollTranscript.Outcome.unchanged
        let releases = contentFilter.accept(snapshot)
        for release in releases {
            outcome = transcript.ingest(release, commandedDisplacement: commandedDisplacement)
        }
        DebugLog.log("harvest → \(snapshot.count) rows, filter released \(releases.count) "
            + "(chrome=\(contentFilter.staticIdentities.count)), outcome=\(outcome), "
            + "total=\(transcript.rows.count)")
        if case .unchanged = outcome {
            // Two scrolls that changed nothing means the events are not reaching the app. Switch
            // routing once, and say so — a silent switch makes the two paths impossible to tell
            // apart when diagnosing a thin capture later.
            // One dead scroll is enough. Waiting for a second means the first two keypresses of
            // every capture in an app like WhatsApp — which ignores per-process scroll events
            // entirely — do visibly nothing, which reads as the keys being broken. A false switch
            // costs nothing: HID routing works in apps that accept either.
            if scrollsSinceChange >= 1, !useHIDScroll {
                useHIDScroll = true
                scrollsSinceChange = 0
                DebugLog.log("SWITCHED to HID scroll routing")
                Notifier.info("Switched to system scroll events for \(target?.appName ?? "this app")")
                // Replay the scroll that was swallowed by the dead route, so the keypress that
                // triggered the switch still does what the user asked for.
                if let direction = lastScrollDirection {
                    overlayDidRequestScroll(direction)
                }
            }
        } else {
            scrollsSinceChange = 0
        }

        switch outcome {
        case .estimated(let added, _):
            // No shared row, so the join is unverified — this is the only way content can be
            // missed now, and the answer is a smaller step so an anchor survives the next one.
            scrollStep.registerGap()
            if added > 0, let edge = pendingEdge { view?.noteCapturedEdge(edge) }
        case .merged(let added, _, _):
            scrollStep.registerCleanMerge()
            if added > 0, let edge = pendingEdge { view?.noteCapturedEdge(edge) }
        case .seeded, .unchanged:
            break
        }
        pendingEdge = nil
        view?.rowCount = transcript.rows.count
        updateStatus(outcome: outcome)
    }

    private func updateStatus(outcome: ScrollTranscript.Outcome) {
        var status = "\(transcript.rows.count) rows"
        if transcript.gapCount > 0 {
            status += "  ·  \(transcript.gapCount) gap(s) — scroll in smaller steps"
        }
        if case .estimated = outcome {
            status += "  ·  skipped content, step → \(scrollStep.current)px"
        }
        view?.statusText = status
    }

    /// How far the last scroll asked the view to move, in screen-space sign (positive = content
    /// moved down). Used only when no shared row exists to measure the true displacement.
    private var commandedDisplacement: Double {
        guard let direction = lastScrollDirection else { return 0 }
        switch direction {
        case .up: return Double(scrollStep.current)
        case .down: return -Double(scrollStep.current)
        case .left, .right: return 0
        }
    }

    private func finishViaOCR(target: WindowTarget) {
        guard Permissions.hasScreenRecording else {
            Notifier.warn(
                "No accessibility text in that region, and Screen Recording isn't granted for the "
                + "OCR fallback. Enable it in System Settings > Privacy & Security."
            )
            Permissions.requestScreenRecording()
            teardown()
            return
        }
        let region = regionCG
        let keep = keepImage
        Task { @MainActor in
            let capture = await OCRHarvester.capture(target: target, region: region, keepImage: keep)
            guard !capture.rows.isEmpty else {
                Notifier.warn("Couldn't read any text from that region.")
                self.teardown()
                return
            }
            var ocrAccumulator = ScrollAccumulator()
            ocrAccumulator.ingest(capture.rows)
            self.usedOCR = true
            self.emit(
                rows: ocrAccumulator.rows,
                target: target,
                mode: .ocr,
                image: capture.image
            )
        }
    }

    private func emit(rows: [CapturedRow], target: WindowTarget, mode: HarvestMode, image: CGImage?) {
        let context = ClipContext(
            appName: target.appName,
            windowTitle: target.title,
            url: WindowResolver.browserURL(for: target),
            capturedAt: Date(),
            regionDescription: "\(Int(regionCG.width))x\(Int(regionCG.height))"
                + " @ (\(Int(regionCG.minX)),\(Int(regionCG.minY)))"
        )
        let document = ClipDocument(
            context: context,
            rows: rows,
            gapIndices: transcript.gapIndices(),
            mode: mode
        )
        let markdown = document.render()
        let saved = ClipWriter.write(markdown: markdown, image: image, context: context)
        ClipWriter.copyToPasteboard(markdown: markdown, path: saved)

        Notifier.info("Copied \(rows.count) rows from \(target.appName)", subtitle: saved?.path)
        teardown()
    }

    // MARK: - Coordinate helpers

    /// View space → AppKit screen space. The overlay covers the union of all displays, which on a
    /// multi-monitor setup has a non-zero (often negative) origin.
    private func screenRect(from rect: NSRect) -> NSRect {
        guard let window else { return rect }
        return NSRect(origin: window.convertPoint(toScreen: rect.origin), size: rect.size)
    }

    private func screenPoint(from point: NSPoint) -> NSPoint {
        window?.convertPoint(toScreen: point) ?? point
    }

    private func viewRect(fromScreen rect: NSRect) -> NSRect {
        guard let window else { return rect }
        let origin = window.convertPoint(fromScreen: rect.origin)
        return NSRect(origin: origin, size: rect.size)
    }
}
