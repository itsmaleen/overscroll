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
    static func extract(from target: WindowTarget, region: CGRect? = nil) -> [CapturedRow]? {
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
        return rows(from: payload, region: region)
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
      var chromeH = window.outerHeight - window.innerHeight;
      var out = ['@' + window.screenX + '\\t' + (window.screenY + chromeH)];
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        if (el.querySelector(sel)) continue;
        if (el.offsetParent === null && el.tagName !== 'BODY') continue;
        var text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
        if (!text) continue;
        var r = el.getBoundingClientRect();
        var link = el.querySelector('a[href]');
        var href = link ? link.href : '';
        out.push(el.tagName.toLowerCase() + '\\t' + href + '\\t' +
                 Math.round(r.left) + '\\t' + Math.round(r.top) + '\\t' + text);
      }
      return out.join('\\n');
    })()
    """

    /// Parse the payload into rows positioned in screen space.
    ///
    /// Screen positions matter because the user dragged a *region*, not "this tab". Returning the
    /// whole document would answer a question they did not ask — the region is the request, and the
    /// DOM's advantage is exact text and real links within it, not more of it. The page reports its
    /// own viewport origin so element rects can be lifted into the same coordinate space the
    /// selection is in.
    private static func rows(from payload: String, region: CGRect?) -> [CapturedRow] {
        var lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, header.hasPrefix("@") else { return [] }
        lines.removeFirst()

        let originParts = header.dropFirst().components(separatedBy: "\t")
        let originX = Double(originParts.first ?? "") ?? 0
        let originY = originParts.count > 1 ? (Double(originParts[1]) ?? 0) : 0

        return lines.compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { return nil }
            let tag = parts[0]
            let href = parts[1]
            let left = Double(parts[2]) ?? 0
            let top = Double(parts[3]) ?? 0
            let text = parts[4...].joined(separator: "\t")
            guard !text.isEmpty else { return nil }

            let screenX = originX + left
            let screenY = originY + top
            if let region {
                // A generous vertical margin: rects are for the element's box, and a heading or a
                // list item can start slightly above the text the user was aiming at.
                let expanded = region.insetBy(dx: -20, dy: -20)
                guard expanded.contains(CGPoint(x: screenX, y: screenY)) else { return nil }
            }

            return CapturedRow(
                text: text,
                role: role(for: tag),
                links: href.isEmpty ? [] : [href],
                y: screenY,
                x: screenX
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
