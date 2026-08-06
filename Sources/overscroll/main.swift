import AppKit
import Carbon.HIToolbox

/// Menu-bar presence and the global hotkey.
@MainActor
final class StatusItemController {
    static var shared: StatusItemController?

    private let statusItem: NSStatusItem
    private let controller: CaptureController
    private var resetTitleWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    /// Last observed trust state, so the icon only changes when it actually flips.
    private var lastTrusted: Bool?

    init(controller: CaptureController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✂︎"

        let menu = NSMenu()
        let capture = NSMenuItem(
            title: "Capture…", action: #selector(startCapture), keyEquivalent: "2"
        )
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        // A visible way out that does not depend on keyboard focus at all. The overlay covers the
        // screen, so "quit the app" must never be the user's only recourse.
        let cancel = NSMenuItem(title: "Cancel Capture", action: #selector(cancelCapture), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        menu.addItem(.separator())

        let clips = NSMenuItem(title: "Open Clips Folder", action: #selector(openClips), keyEquivalent: "")
        clips.target = self
        menu.addItem(clips)

        let permissions = NSMenuItem(
            title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: ""
        )
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Trust state is polled rather than read once at launch. `AXIsProcessTrusted()` is a
        // snapshot, and the grant usually arrives *after* the app is already running — the user
        // flips the switch in System Settings while it sits there. Without polling the app keeps
        // insisting it has no access long after it does, which is indistinguishable from a real
        // failure and sends you back to a settings pane that already looks correct.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionState() }
        }
        refreshPermissionState()
    }

    /// Reflect Accessibility state in the menu-bar icon: `✂︎` ready, `✂︎⚠` not trusted.
    func refreshPermissionState() {
        let trusted = Permissions.hasAccessibility
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        statusItem.button?.title = trusted ? "✂︎" : "✂︎⚠"
        statusItem.button?.toolTip = trusted
            ? "overscroll — ready (⌘⇧2)"
            : "overscroll — needs Accessibility access"
        if trusted { Notifier.info("Accessibility granted — ready") }
    }

    @objc func startCapture() {
        controller.begin()
    }

    @objc func cancelCapture() {
        controller.cancelIfActive()
    }

    @objc func openClips() {
        try? FileManager.default.createDirectory(
            at: ClipWriter.directory, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(ClipWriter.directory)
    }

    @objc func checkPermissions() {
        // Print the signing identity alongside the verdict. When the switch is on in System
        // Settings but the app still reports no access, the cause is almost always that the binary
        // was rebuilt under a different signature — TCC keys on the signature, so the old grant no
        // longer matches and the stale entry has to be cleared with:
        //     tccutil reset Accessibility com.itsmaleen.overscroll
        let report = "overscroll: bundle=\(Bundle.main.bundleIdentifier ?? "?")"
            + " accessibility=\(Permissions.hasAccessibility)"
            + " screenRecording=\(Permissions.hasScreenRecording)\n"
        FileHandle.standardError.write(Data(report.utf8))
        if let missing = Permissions.missingDescription(requireScreenRecording: true) {
            Notifier.warn(missing)
            if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
            if !Permissions.hasScreenRecording { Permissions.requestScreenRecording() }
        } else {
            Notifier.info("Accessibility and Screen Recording are both granted.")
        }
        refreshPermissionState()
    }

    /// Briefly replace the menu-bar title with a status message. A status item is the only surface
    /// this app owns, so it doubles as the notification channel.
    func flash(_ message: String) {
        resetTitleWork?.cancel()
        statusItem.button?.title = "✂︎ \(message)"
        let work = DispatchWorkItem { [weak self] in
            // Restore whichever base icon reflects current trust, not an unconditional "✂︎".
            self?.lastTrusted = nil
            self?.refreshPermissionState()
        }
        resetTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CaptureController()
    private var statusItemController: StatusItemController?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItemController = StatusItemController(controller: controller)
        self.statusItemController = statusItemController
        StatusItemController.shared = statusItemController

        registerHotKey()

        if let missing = Permissions.missingDescription(requireScreenRecording: false) {
            Notifier.warn(missing)
            Permissions.requestAccessibility()
        }
    }

    /// Carbon's hot-key API is still the only way to get a system-wide shortcut without a TCC grant
    /// of its own. `NSEvent.addGlobalMonitorForEvents` would work too, but it is gated on the very
    /// accessibility permission the user may not have granted yet — leaving no way to launch the
    /// capture that prompts for it.
    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async {
                    StatusItemController.shared?.startCapture()
                }
                return noErr
            },
            1, &eventType, nil, nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x53434C50), id: 1)  // 'SCLP'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_2),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

let app = NSApplication.shared
// Menu-bar only: no Dock icon, no app menu. Also keeps the overlay from stealing focus in a way
// that would reshuffle the window order we're about to read.
app.setActivationPolicy(.accessory)
// Top-level code runs on the main thread but isn't statically main-actor isolated in Swift 5 mode.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
