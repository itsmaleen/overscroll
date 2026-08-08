import AppKit
import OverscrollAX
import OverscrollCore

/// Pulls a document out through the app's own copy command.
///
/// Some content has a lossless route out and screen-scraping it is simply the wrong tool. A Google
/// Doc will not give up a word to the accessibility tree and has to be OCR'd character by
/// character — but select-all-and-copy returns the entire document, exactly, in one keystroke. The
/// same is true of a spreadsheet, which copies as TSV, and of most editors.
///
/// This is never automatic, and the reason is that it is the only path here that *writes*. Every
/// other route observes: it reads a tree, or photographs pixels, and the target app cannot tell the
/// difference. This one drives the keyboard of another application, replaces the clipboard, and
/// changes the user's selection. Those are side effects on someone's working state, so they happen
/// only when explicitly asked for, and each one is undone afterwards:
///
/// - the clipboard is captured before and restored after, across all its types rather than just
///   the string, since a copied image or file reference would otherwise be destroyed;
/// - the selection is collapsed once the copy is taken, because leaving a whole document selected
///   arms the next keystroke to replace it.
enum ClipboardExport {

    enum Failure: Error {
        case notFrontmost
        case copyProducedNothing
    }

    /// Select all, copy, read, and put everything back as it was.
    static func export(from target: WindowTarget) async -> Result<[CapturedRow], Failure> {
        let pasteboard = NSPasteboard.general
        let saved = snapshotPasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            return .failure(.notFrontmost)
        }
        // Keyboard events go to whichever app is frontmost, and ours currently is.
        app.activate()
        try? await Task.sleep(nanoseconds: 350_000_000)

        postCommandKey(0)   // ⌘A
        try? await Task.sleep(nanoseconds: 120_000_000)
        postCommandKey(8)   // ⌘C

        // Wait for the copy rather than guessing at a delay: the pasteboard's change counter is the
        // only reliable signal that the target actually did something.
        var waited = 0
        while pasteboard.changeCount == changeCountBefore, waited < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        let copied = pasteboard.string(forType: .string)
        collapseSelection()
        restorePasteboard(pasteboard, from: saved)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.copyProducedNothing)
        }
        return .success(rows(from: copied))
    }

    // MARK: - Restoring what we disturbed

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type.rawValue] = data }
            }
            return stored
        } ?? []
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, from saved: [[String: Data]]) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Collapse a whole-document selection to a caret.
    ///
    /// Not cosmetic. Leaving every word of a document selected means the user's next keystroke
    /// replaces all of it — a capture must not leave the target one keypress away from being
    /// destroyed. Right-arrow collapses to the end of the selection in every text view.
    private static func collapseSelection() {
        postKey(124, flags: [])  // →
    }

    // MARK: - Key events

    private static func postCommandKey(_ keyCode: CGKeyCode) {
        postKey(keyCode, flags: .maskCommand)
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Rows

    /// One row per line, positioned by document order.
    ///
    /// No geometry to reconcile: the copy is the document, in order, so the index *is* the position.
    private static func rows(from text: String) -> [CapturedRow] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                CapturedRow(text: line, role: "AXStaticText", y: Double(index), x: 0)
            }
    }
}
