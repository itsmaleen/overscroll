import AppKit
import CoreGraphics

/// A window we're capturing from, resolved from the window server.
public struct WindowTarget {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let title: String?
    /// Bounds in CoreGraphics screen space: origin top-left of the main display, y growing downward.
    public let bounds: CGRect

    public init(
        windowID: CGWindowID, pid: pid_t, appName: String, title: String?, bounds: CGRect
    ) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.title = title
        self.bounds = bounds
    }

    public var isBrowser: Bool {
        // Chromium forks are numerous and keep appearing; matching only an exact list means each
        // new one silently loses the DOM path, which is the best path a browser has.
        let browsers = ["Safari", "Google Chrome", "Arc", "Firefox", "Microsoft Edge",
                        "Brave Browser", "Chromium", "Orion", "Dia", "Comet", "Helium",
                        "Vivaldi", "Opera", "Zen", "Sidekick", "Thorium"]
        return browsers.contains { appName.localizedCaseInsensitiveContains($0) }
    }
}

/// Invisible bidirectional and formatting marks, stripped wherever app-supplied strings enter.
func stripInvisibles(_ value: String) -> String {
    let marks: Set<Character> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}", "\u{200B}",
    ]
    return String(value.filter { !marks.contains($0) })
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum WindowResolver {
    /// Topmost normal window containing `point`, skipping our own overlay.
    ///
    /// `point` is in CoreGraphics screen space (top-left origin), which is what
    /// `CGWindowListCopyWindowInfo` reports bounds in — deliberately not AppKit's bottom-left space.
    public static func window(at point: CGPoint) -> WindowTarget? {
        candidates().first { $0.bounds.contains(point) }
    }

    public static func window(withID id: CGWindowID) -> WindowTarget? {
        candidates().first { $0.windowID == id }
    }

    /// On-screen windows in front-to-back order, filtered to real application windows.
    public static func candidates() -> [WindowTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return raw.compactMap { info -> WindowTarget? in
            // Layer 0 is the normal window layer. Anything above it is a panel, menu, dock tile, or
            // our own overlay — never the content the user means to capture.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { return nil }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            // Sub-window slivers are almost always shadows or helper surfaces.
            guard rect.width > 40, rect.height > 40 else { return nil }

            // App names and window titles carry the same invisible bidi marks as the accessibility
            // labels do — WhatsApp reports its own name as "\u{200E}WhatsApp" — and these end up in
            // the clip's front matter, so they're stripped at the boundary.
            let owner = stripInvisibles(info[kCGWindowOwnerName as String] as? String ?? "Unknown")
            let title = (info[kCGWindowName as String] as? String).map(stripInvisibles)

            return WindowTarget(windowID: id, pid: pid, appName: owner, title: title, bounds: rect)
        }
    }

    /// Frontmost tab URL, for browsers only. AppleScript is the only route that works across the
    /// major browsers; the accessibility tree exposes the address bar's *displayed* text, which is
    /// increasingly abbreviated (scheme dropped, path hidden) and so is not the real URL.
    public static func browserURL(for target: WindowTarget) -> String? {
        guard target.isBrowser else { return nil }
        let script: String
        switch target.appName {
        case "Safari", "Orion":
            script = "tell application \"\(target.appName)\" to return URL of front document"
        default:
            script = "tell application \"\(target.appName)\" to return URL of active tab of front window"
        }
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return nil }
        let result = apple.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}

/// Coordinate conversion between AppKit (bottom-left origin, per-screen) and CoreGraphics screen
/// space (top-left origin of the main display). Getting this wrong silently captures the wrong
/// region on multi-display setups, which is why it lives in one place.
public enum ScreenSpace {
    /// Height of the main display, the reference for the flip.
    public static var mainHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    public static func cgPoint(fromAppKit point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    public static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKitRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
