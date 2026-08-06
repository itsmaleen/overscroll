import AppKit
import ApplicationServices
import CoreGraphics

/// The two TCC grants this tool cannot work without.
///
/// Accessibility is the load-bearing one: it authorizes both reading other apps' element trees and
/// posting synthetic scroll events into them. Screen Recording is only needed for the OCR fallback
/// and for keeping the image alongside a clip.
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for accessibility. macOS shows the System Settings pane but does not grant
    /// synchronously — the user has to toggle it and, because TCC keys on the code signature, the
    /// grant is invalidated by every rebuild of an ad-hoc signed binary.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Returns nil when everything needed is granted, otherwise a message naming what is missing.
    static func missingDescription(requireScreenRecording: Bool) -> String? {
        var missing: [String] = []
        if !hasAccessibility { missing.append("Accessibility") }
        if requireScreenRecording && !hasScreenRecording { missing.append("Screen Recording") }
        guard !missing.isEmpty else { return nil }
        return "overscroll needs \(missing.joined(separator: " and ")) access. "
            + "Grant it in System Settings > Privacy & Security, then relaunch."
    }

    static func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
