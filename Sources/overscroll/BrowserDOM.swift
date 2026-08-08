import AppKit
import OverscrollAX
import OverscrollCore

/// Reads a web page from the browser's own DOM rather than from the screen.
///
/// For a browser tab this is strictly better than every other path here, and it is not close. The
/// accessibility tree exposes only what is *rendered* — the viewport — so a long article has to be
/// scrolled past a moving window and reassembled. The DOM has the whole document at once, with the
/// exact text and the real `href` of every link, and needs no scrolling, no geometry, no consensus
/// and no gap accounting.
///
/// It is reached through AppleScript, which means the user must have allowed JavaScript from Apple
/// Events (Safari: Develop menu; Chromium: View → Developer) and granted Automation for the
/// browser. Both are one-off, and when either is missing this returns nil and the capture falls
/// back to the paths that need no permission at all.
enum BrowserDOM {

    /// Extract the current tab as rows, or nil if this is not a scriptable browser or the script
    /// was refused.
    static func extract(from target: WindowTarget) -> [CapturedRow]? {
        guard target.isBrowser else {
            note("\(target.appName) is not a known browser")
            return nil
        }
        guard let script = script(for: target.appName) else { return nil }

        var error: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return nil }
        let result = apple.executeAndReturnError(&error)

        if let error {
            // Common and expected: Automation not granted, or "Allow JavaScript from Apple Events"
            // switched off. Neither is worth interrupting a capture over — the fallback works.
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
            note("\(target.appName): \(message)")
            return nil
        }
        guard let payload = result.stringValue, !payload.isEmpty else { return nil }
        return rows(from: payload)
    }

    /// Record why the DOM path was unavailable, to both the capture trace and stderr.
    ///
    /// Two destinations because the two readers differ: a capture writes to the trace file, while
    /// the diagnostic flags are run from a terminal where nobody thinks to go looking for a log.
    private static func note(_ reason: String) {
        DebugLog.log("BrowserDOM unavailable — \(reason)")
        FileHandle.standardError.write(Data("BrowserDOM unavailable — \(reason)\n".utf8))
    }

    private static func script(for appName: String) -> String? {
        let escaped = extractionJS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        switch appName {
        case "Safari", "Orion":
            return "tell application \"\(appName)\" to do JavaScript \"\(escaped)\" in front document"
        default:
            // Chrome and its forks share this scripting suite.
            return "tell application \"\(appName)\" to execute active tab of front window javascript \"\(escaped)\""
        }
    }

    /// Walks block-level elements and emits one tab-separated record per line.
    ///
    /// Only leaf blocks are emitted — an element containing another block is a container, and
    /// taking both would print every paragraph twice, once inside its own `<li>` or `<div>`. Uses
    /// single quotes throughout so the whole thing survives being embedded in an AppleScript string
    /// literal.
    private static let extractionJS = """
    (function(){
      var sel = 'h1,h2,h3,h4,h5,h6,p,li,td,th,blockquote,pre,dt,dd,figcaption';
      var nodes = document.body ? document.body.querySelectorAll(sel) : [];
      var out = [];
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        if (el.querySelector(sel)) continue;
        if (el.offsetParent === null && el.tagName !== 'BODY') continue;
        var text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
        if (!text) continue;
        var link = el.querySelector('a[href]');
        var href = link ? link.href : '';
        out.push(el.tagName.toLowerCase() + '\\t' + href + '\\t' + text);
      }
      return out.join('\\n');
    })()
    """

    private static func rows(from payload: String) -> [CapturedRow] {
        payload.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            let tag = parts[0]
            let href = parts[1]
            let text = parts[2...].joined(separator: "\t")
            guard !text.isEmpty else { return nil }

            return CapturedRow(
                text: text,
                role: role(for: tag),
                links: href.isEmpty ? [] : [href],
                // Document order is the only ordering that matters here, and the DOM already
                // provides it — there is no geometry to reconcile because nothing was scrolled.
                y: Double(index),
                x: 0
            )
        }
    }

    private static func role(for tag: String) -> String {
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6": return "AXHeading"
        case "li", "dt", "dd": return "AXStaticText"
        case "td", "th": return "AXCell"
        default: return "AXStaticText"
        }
    }
}
