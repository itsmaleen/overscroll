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
        lastSnapshotRowCount = 0
        emptyAXHarvests = 0
        usedAX = false
        scrollsSinceChange = 0
        useHIDScroll = false
        // Every one of these is per-capture. Leaving them set carried the previous capture's OCR
        // mode into the next one, so the first `O` press *disabled* the pixel path instead of
        // enabling it — and a stale scroll counter made OCR fire before anything had been tried.
        forceOCR = false
        scrollsWithoutGrowth = 0
        rowCountAtLastScroll = 0
        lastScrollDirection = nil
        trackpadDisplacement = 0
        trackpadHorizontal = 0
        harvestQueued = false
        harvestModeDecided = false
        appliedProfile = nil
        domAttempted = false
        usedDOM = false
        usedExport = false
        exportInFlight = false
        autoScrolling = false
        pacer.reset()
        rowsBeforeAutoStep = 0
        view?.autoScrolling = false
        view?.ocrMode = false

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

    /// Scroll to the end without being driven.
    ///
    /// Each step is issued from the *completion* of the previous harvest, never on a timer, so the
    /// scroll can never outrun the read — which is the failure a person cannot avoid by hand.
    func overlayDidToggleAutoScroll() {
        guard target != nil else { return }
        autoScrolling.toggle()
        view?.autoScrolling = autoScrolling
        DebugLog.log("autoScroll = \(autoScrolling)")

        guard autoScrolling else {
            Notifier.info("Auto-scroll stopped")
            return
        }
        pacer.reset()
        Notifier.info("Auto-scrolling to the end…")
        advanceAutoScroll()
    }

    private func advanceAutoScroll() {
        guard autoScrolling, isActive else { return }
        rowsBeforeAutoStep = transcript.rows.count
        overlayDidRequestScroll(autoScrollDirection)
    }

    /// Called once each harvest settles, which is what paces the loop.
    private func continueAutoScrollIfNeeded() {
        guard autoScrolling, isActive else { return }
        let added = transcript.rows.count - rowsBeforeAutoStep

        switch pacer.next(rowsAdded: added) {
        case .scroll:
            // A short breath so the target can finish laying out before the next step is issued.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                Task { @MainActor in self?.advanceAutoScroll() }
            }
        case .stop(let reason):
            autoScrolling = false
            view?.autoScrolling = false
            DebugLog.log("autoScroll stopped: \(reason) after \(pacer.steps) steps")
            Notifier.info("Auto-scroll \(reason) — \(transcript.rows.count) rows")
        }
    }

    /// Pull the whole document out through the app's own copy command.
    ///
    /// Bound to a key and never triggered automatically. Every other path here only observes; this
    /// one drives another app's keyboard, replaces the clipboard and moves the user's selection —
    /// side effects on their working state, which should follow from an explicit request rather
    /// than from a heuristic deciding it knows better.
    func overlayDidRequestExport() {
        guard let target, !exportInFlight else { return }
        exportInFlight = true
        Notifier.info("Copying the whole document from \(target.appName)…")
        DebugLog.log("export: select-all + copy from \(target.appName)")

        Task { @MainActor in
            let result = await ClipboardExport.export(from: target)
            self.exportInFlight = false

            switch result {
            case .success(let rows):
                // Wholesale replacement: the copy *is* the document, so anything scraped off the
                // screen beforehand is a strictly worse version of the same content.
                self.transcript = ScrollTranscript()
                self.contentFilter = ScrollingContentFilter()
                self.usedExport = true
                self.currentHarvestWasOCR = false
                self.ingest(rows)
                DebugLog.log("export → \(rows.count) rows")
                Notifier.info("Copied \(rows.count) rows — press Return to finish")
            case .failure(let error):
                DebugLog.log("export failed: \(error)")
                Notifier.warn(
                    error == .copyProducedNothing
                        ? "Nothing was copied — this app may not support select-all."
                        : "Could not reach \(target.appName) to copy from it."
                )
            }
            // The target was brought forward to receive the keystrokes; take focus back so the
            // overlay's own keys work again.
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            if let view = self.view { self.window?.makeFirstResponder(view) }
        }
    }

    func overlayDidToggleOCR() {
        guard Permissions.hasScreenRecording else {
            Notifier.warn("Reading pixels needs Screen Recording access — grant it in System Settings.")
            Permissions.requestScreenRecording()
            return
        }
        forceOCR.toggle()
        view?.ocrMode = forceOCR
        DebugLog.log("forceOCR = \(forceOCR)")
        Notifier.info(forceOCR ? "Reading pixels (OCR)" : "Reading the accessibility tree")
        harvestNow()
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
        // Track whether scrolling is actually yielding content, which is what distinguishes a
        // canvas surface from a merely slow one.
        if transcript.rows.count > rowCountAtLastScroll {
            scrollsWithoutGrowth = 0
        } else {
            scrollsWithoutGrowth += 1
        }
        rowCountAtLastScroll = transcript.rows.count

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
        // One last harvest so content revealed by the final scroll isn't dropped — but it has to
        // use whichever path the capture has been using. Hardcoding the accessibility read here
        // meant a canvas capture ended by clobbering its own work: on Google Docs the final AX
        // harvest returned a single row (the tab title) which replaced a held 14-row OCR snapshot,
        // and produced a one-line clip.
        if forceOCR || usedOCR {
            Task { @MainActor in
                let capture = await OCRHarvester.capture(
                    target: target, region: self.regionCG, keepImage: false
                )
                self.ingest(capture.rows)
                self.completeFinish(target: target)
            }
            return
        }
        if let windowElement, regionCG.width > 1, regionCG.height > 1 {
            ingest(AXHarvester.harvest(window: windowElement, region: regionCG))
        }
        completeFinish(target: target)
    }

    private func completeFinish(target: WindowTarget) {
        // A capture where the user never scrolled leaves the first snapshot held for comparison
        // that never came. Releasing it unfiltered is the honest result — with no movement there
        // is no evidence about what was chrome.
        let held = contentFilter.flush()
        if !held.isEmpty { transcript.ingest(held, commandedDisplacement: commandedDisplacement, commandedHorizontal: commandedHorizontal) }
        DebugLog.log("FINISH rows=\(transcript.rows.count) gaps=\(transcript.gapCount) "
            + "flushed=\(held.count) route=\(useHIDScroll ? "HID" : "pid")")

        let rows = transcript.rows
        if rows.isEmpty {
            // No accessibility text at all — a canvas-rendered surface. Fall back to pixels.
            finishViaOCR(target: target)
            return
        }
        // Report honestly which path produced the content, since it tells the reader how much to
        // trust it: OCR rows have already lost their link targets and exact text.
        let mode: HarvestMode
        switch (usedDOM, usedAX, usedOCR) {
        case _ where usedExport: mode = .export
        case (true, _, _): mode = .dom
        case (_, true, true): mode = .mixed
        case (_, false, true): mode = .ocr
        default: mode = .accessibility
        }
        emit(rows: rows, target: target, mode: mode, image: nil)
    }

    func overlayDidCancel() {
        // While a scroll-to-the-end is running, Esc means "stop this", not "throw the capture
        // away". Discarding a long unattended run because the user wanted it to halt early would
        // lose exactly the work the feature exists to gather; a second Esc still cancels.
        if autoScrolling {
            autoScrolling = false
            view?.autoScrolling = false
            DebugLog.log("autoScroll cancelled by Esc")
            Notifier.info("Auto-scroll stopped — \(transcript.rows.count) rows. Esc again to cancel.")
            return
        }
        teardown()
    }

    // MARK: - Capture

    private func resolveTarget(at point: CGPoint) {
        guard let found = WindowResolver.window(at: point) else { return }
        if found.windowID != target?.windowID {
            target = found
            windowElement = AXHarvester.windowElement(for: found)
        }
        applyProfileIfAny()
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

        lockedAt = Date()
        scheduleTreeWarmup()

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
                    // A trackpad delta is already in screen space and already carries the right
                    // sign, so it needs no inversion: a positive deltaY means content moved down.
                    self.lastScrollDirection = nil
                    self.trackpadDisplacement = deltaY
                    self.trackpadHorizontal = 0
                } else if deltaX != 0 {
                    self.lastHint = .unknown
                    self.pendingEdge = deltaX > 0 ? .left : .right
                    self.lastScrollDirection = nil
                    self.trackpadDisplacement = 0
                    self.trackpadHorizontal = deltaX
                }
                DebugLog.log("trackpad scroll dy=\(Int(deltaY)) dx=\(Int(deltaX))")
                self.lastActivity = Date()
                self.scheduleHarvest()
            }
        }
        harvestNow()
    }

    /// Rows returned by the most recent harvest, before filtering.
    private var lastSnapshotRowCount = 0
    /// Consecutive harvests where the accessibility tree returned nothing. Two in a row is the
    /// signal that this is a canvas surface rather than a tree still warming up.
    private var emptyAXHarvests = 0

    /// Re-harvest a few times if the first read comes back empty.
    ///
    /// Chromium and Electron apps build their web-content accessibility tree *asynchronously* after
    /// being asked for it, so the harvest that immediately follows locking a region can land before
    /// the tree exists — a browser then captures nothing at all, which is exactly how browsers came
    /// to look unsupported. Measured on a Chromium browser: the read right after the request saw a
    /// window with no children, and a moment later the same window exposed hundreds of nodes.
    ///
    /// Self-limiting: each retry is skipped once any rows have arrived.
    private func scheduleTreeWarmup() {
        for delay in [0.35, 0.9, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    guard let self, self.isActive, self.lastSnapshotRowCount == 0 else { return }
                    DebugLog.log("tree warmup retry at \(delay)s")
                    self.harvestNow()
                }
            }
        }
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
        // A browser tab is best read from its own DOM: exact text, real link targets, and the whole
        // document rather than the rendered viewport. Tried first and only once — if the browser
        // refuses (Automation not granted, or JavaScript from Apple Events switched off) the flag
        // stops it being retried on every harvest of the capture.
        if !domAttempted, let target, target.isBrowser, !forceOCR {
            domAttempted = true
            if let rows = BrowserDOM.extract(from: target, region: regionCG), !rows.isEmpty {
                usedDOM = true
                harvestModeDecided = true
                DebugLog.log("DOM harvest → \(rows.count) rows (scrolling not required)")
                Notifier.info("Read \(rows.count) rows from the page source")
                currentHarvestWasOCR = false
                ingest(rows)
                return
            }
        }

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
                // A canvas-rendered app returns nothing from the tree, every time — not just at the
                // end of a capture. Falling back per harvest is what lets Google Docs, Sheets,
                // Figma and remote desktops be *scrolled* rather than photographed once: OCR lines
                // carry positions just like accessibility rows, so they feed the same geometry.
                if self.shouldTryOCR {
                    self.harvestViaOCR()
                    return
                }
                // Decide once, from evidence, rather than making the user notice and press a key.
                if !self.harvestModeDecided, self.readyToDecideMode {
                    self.harvestModeDecided = true
                    self.decideHarvestMode(axSnapshot: snapshot)
                    return
                }
                self.harvestInFlight = false
                self.currentHarvestWasOCR = false
                self.ingest(snapshot)
                if self.harvestQueued {
                    self.harvestQueued = false
                    self.harvestNow()
                }
            }
        }
    }

    /// Whether the pixel path is worth attempting.
    ///
    /// Gating this on an *empty* accessibility harvest was wrong for the same reason the scroll
    /// fallback's original trigger was: a canvas app is not silent, it just says nothing useful.
    /// Google Docs returns its toolbar and menu bar quite happily — 4 rows where OCR finds 49 — so
    /// "empty" never happens and the fallback never fires.
    ///
    /// The honest signal is that scrolling is not producing content: the view demonstrably moves,
    /// and the transcript does not grow. That catches canvas surfaces without needing to recognise
    /// them.
    private var shouldTryOCR: Bool {
        guard Permissions.hasScreenRecording else { return false }
        return forceOCR || scrollsWithoutGrowth >= 3
    }

    /// Set by the user pressing `O`, for when they already know the target is canvas-rendered and
    /// would rather not scroll three times to prove it.
    private var autoScrolling = false
    private var autoScrollDirection: Scroller.Direction = .down
    private var pacer = AutoScrollPacer()
    private var rowsBeforeAutoStep = 0
    private var forceOCR = false
    /// Whether the harvest currently being ingested came from the pixel path.
    private var currentHarvestWasOCR = false
    /// Scrolls issued since the transcript last gained a row.
    private var scrollsWithoutGrowth = 0
    private var rowCountAtLastScroll = 0

    private var harvestModeDecided = false
    private var lockedAt = Date()
    private var appliedProfile: AppProfile?
    /// Whether the DOM path has been tried for this capture; it is worth exactly one attempt.
    private var domAttempted = false
    private var usedDOM = false
    private var usedExport = false
    private var exportInFlight = false

    /// Start the capture in the state this app is already known to need.
    ///
    /// Only ever a head start. Every setting here is one detection would have reached anyway, a
    /// keypress or a probe later — so a profile that misfires costs the round-trip it was meant to
    /// save and nothing more.
    private func applyProfileIfAny() {
        guard let target else { return }
        let profile = AppProfiles.profile(appName: target.appName, windowTitle: target.title)
        guard let profile, profile != appliedProfile else { return }
        appliedProfile = profile

        if profile.scrollRoute == .hidOnly, !useHIDScroll {
            useHIDScroll = true
            DebugLog.log("profile \(profile.name): starting on HID scroll — \(profile.rationale)")
        }
        if profile.prefersOCR, !forceOCR, Permissions.hasScreenRecording {
            forceOCR = true
            harvestModeDecided = true
            view?.ocrMode = true
            usedOCR = true
            DebugLog.log("profile \(profile.name): starting on OCR — \(profile.rationale)")
            Notifier.info("\(profile.name) draws its content — reading pixels")
        }
    }

    /// A Chromium tree is still being built for the first moment after it is asked for, so an
    /// immediate read says nothing about whether the app *has* one. Wait for the warmup window
    /// before judging — unless rows have already arrived, which settles it early.
    private var readyToDecideMode: Bool {
        lastSnapshotRowCount > 0 || Date().timeIntervalSince(lockedAt) >= 0.8
    }

    /// An accessibility read this size is clearly working; no need to spend an OCR pass comparing.
    private static let axClearlyWorkingRows = 12

    /// Choose between the tree and the pixels by running both once and comparing.
    ///
    /// A ratio, not a raw count. "Whichever returns more rows" would be wrong: OCR sees timestamps,
    /// avatars and chrome that the tree sensibly omits, so it can out-count a perfectly good
    /// accessibility read and would drag WhatsApp onto the pixel path — losing real link targets and
    /// exact text for nothing. Only a landslide indicates the tree is genuinely blind, which is what
    /// a canvas app looks like: measured on a Google Doc, 4 rows against 49.
    private func decideHarvestMode(axSnapshot: [CapturedRow]) {
        guard Permissions.hasScreenRecording,
              axSnapshot.count < Self.axClearlyWorkingRows,
              let target
        else {
            harvestInFlight = false
            currentHarvestWasOCR = false
            ingest(axSnapshot)
            return
        }

        Task { @MainActor in
            let capture = await OCRHarvester.capture(
                target: target, region: self.regionCG, keepImage: false
            )
            self.harvestInFlight = false
            let ocrWins = capture.rows.count >= max(8, axSnapshot.count * 3)
            DebugLog.log(
                "mode decision: ax=\(axSnapshot.count) ocr=\(capture.rows.count) "
                + "→ \(ocrWins ? "OCR" : "accessibility")"
            )

            guard ocrWins else {
                self.currentHarvestWasOCR = false
                self.ingest(axSnapshot)
                return
            }
            // Switch wholesale. Mixing the two sources mid-capture would put the same content into
            // the transcript twice, in two different spellings, at two different positions.
            self.forceOCR = true
            self.view?.ocrMode = true
            self.transcript = ScrollTranscript()
            self.contentFilter = ScrollingContentFilter()
            self.usedOCR = true
            self.currentHarvestWasOCR = true
            Notifier.info("No text in the accessibility tree — reading pixels")
            self.ingest(capture.rows)
        }
    }

    private func harvestViaOCR() {
        guard let target else {
            harvestInFlight = false
            return
        }
        let region = regionCG
        Task { @MainActor in
            let capture = await OCRHarvester.capture(target: target, region: region, keepImage: false)
            self.harvestInFlight = false
            if !capture.rows.isEmpty { self.usedOCR = true }
            self.currentHarvestWasOCR = true
            DebugLog.log("OCR harvest → \(capture.rows.count) rows")
            self.ingest(capture.rows)
            if self.harvestQueued {
                self.harvestQueued = false
                self.harvestNow()
            }
        }
    }

    private func ingest(_ snapshot: [CapturedRow]) {
        lastSnapshotRowCount = snapshot.count
        guard !snapshot.isEmpty else {
            emptyAXHarvests += 1
            DebugLog.log("harvest → 0 rows (empty #\(emptyAXHarvests))")
            return
        }
        // Credited independently of the OCR flag: gating this on `!usedOCR` under-reported a mixed
        // capture as pure OCR, which is exactly the case where the reader most needs to know some
        // rows came from a tree and some from pixels.
        if !currentHarvestWasOCR { usedAX = true }
        var outcome = ScrollTranscript.Outcome.unchanged
        let releases = contentFilter.accept(snapshot)
        for release in releases {
            outcome = transcript.ingest(release, commandedDisplacement: commandedDisplacement, commandedHorizontal: commandedHorizontal)
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
        updateGapIndicators()
        updateStatus(outcome: outcome)
        continueAutoScrollIfNeeded()
    }

    /// Point the arrows at where the missed content actually is, relative to what is on screen now.
    ///
    /// Gaps are spans in document space, so their position relative to the current viewport is a
    /// live quantity: scroll toward one and the arrow flips sides, then disappears once the ground
    /// has been re-observed. That is more useful than a static count, which tells the user
    /// something went wrong but not what to do about it.
    private func updateGapIndicators() {
        guard let view, regionCG.height > 0 else { return }
        let counts = transcript.gapsRelativeToViewport(
            screenRange: regionCG.minY...regionCG.maxY
        )
        view.gapsAbove = counts.above
        view.gapsBelow = counts.below
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

    /// How far the last scroll asked the view to move, used only when no shared row exists to
    /// measure the true displacement.
    ///
    /// The sign must match what `ScrollTranscript` computes from anchors, and it is the opposite of
    /// what "scroll down" suggests. Scrolling **down** moves content **up** the screen, so a row
    /// that was at y=300 reappears at y=88 and the offset has to grow by +212 to keep its document
    /// position fixed. Getting this backwards is not a small error: the offset then moves the wrong
    /// way by twice the step on every unanchored merge, scattering rows far from where they belong.
    private var commandedDisplacement: Double {
        guard let direction = lastScrollDirection else { return trackpadDisplacement }
        switch direction {
        case .up: return -Double(scrollStep.current)
        case .down: return Double(scrollStep.current)
        case .left, .right: return 0
        }
    }

    /// Horizontal counterpart, for content scrolled sideways.
    private var commandedHorizontal: Double {
        guard let direction = lastScrollDirection else { return trackpadHorizontal }
        switch direction {
        case .left: return -Double(scrollStep.current)
        case .right: return Double(scrollStep.current)
        case .up, .down: return 0
        }
    }

    private var trackpadHorizontal: Double = 0

    /// Displacement of the most recent trackpad scroll, from the event's own delta.
    ///
    /// Without this a manual scroll had no fallback at all — `lastScrollDirection` is only set by
    /// the keyboard path, so an unanchored trackpad merge assumed zero movement and stacked the new
    /// rows on top of the old ones.
    private var trackpadDisplacement: Double = 0

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
