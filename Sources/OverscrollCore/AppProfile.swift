import Foundation

/// What is already known about how a particular app behaves under capture.
///
/// Every entry here was paid for once by measurement, and without a registry the cost is paid again
/// on every capture. Overscroll can discover that WhatsApp ignores per-process scroll events — it
/// does, after one dead keypress — and that a Google Doc has no accessibility text, after an
/// unnecessary tree probe. Both are known in advance; recording them turns a discovery into a
/// setting.
///
/// Deliberately small. A profile may only *start* the capture in the right state; it never disables
/// the detection that would have got there anyway. An app that changes behaviour, or a title match
/// that fires on the wrong page, then costs nothing worse than the round-trip it was meant to save.
public struct AppProfile: Sendable, Equatable {

    public enum ScrollRoute: Sendable, Equatable {
        /// Try per-process events first and fall back on evidence.
        case automatic
        /// Skip straight to the HID tap — this app is known to ignore per-process scroll events.
        case hidOnly
    }

    public let name: String
    public let scrollRoute: ScrollRoute
    /// Start on the pixel path: this app draws its content and exposes no usable tree.
    public let prefersOCR: Bool
    /// Why the profile exists, so a future reader can tell whether it still applies.
    public let rationale: String

    public init(
        name: String,
        scrollRoute: ScrollRoute = .automatic,
        prefersOCR: Bool = false,
        rationale: String
    ) {
        self.name = name
        self.scrollRoute = scrollRoute
        self.prefersOCR = prefersOCR
        self.rationale = rationale
    }
}

public enum AppProfiles {

    /// The profile for a window, or nil to let detection decide everything.
    ///
    /// Matched on the window *title* as well as the app, because the app is often the wrong unit:
    /// a browser is a perfectly good accessibility citizen on most pages and completely blind on a
    /// Google Doc, and only the title distinguishes them.
    public static func profile(appName: String, windowTitle: String?) -> AppProfile? {
        let title = windowTitle ?? ""

        // Canvas-rendered editors. These draw their content, so no amount of coaxing the
        // accessibility tree will produce the document; the pixel path is the only one there is.
        for editor in ["Google Docs", "Google Sheets", "Google Slides"] where title.contains(editor) {
            return AppProfile(
                name: editor,
                prefersOCR: true,
                rationale: "Draws its content to a canvas — measured at 4 accessibility rows "
                    + "against 49 from OCR on the same window."
            )
        }

        if appName.localizedCaseInsensitiveContains("WhatsApp") {
            return AppProfile(
                name: "WhatsApp",
                scrollRoute: .hidOnly,
                rationale: "Ignores per-process scroll events entirely — twelve steps, zero "
                    + "movement — while responding normally to the HID tap."
            )
        }

        return nil
    }
}
