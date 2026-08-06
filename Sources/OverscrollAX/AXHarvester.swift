import AppKit
import ApplicationServices
import OverscrollCore

/// Pulls text out of another app's accessibility tree, restricted to a screen region.
///
/// This is the path that justifies the whole tool. A pixel capture of the same region yields an
/// image whose links have already been reduced to display text — "linkedin.com/in/some…" is
/// unrecoverable once rendered. The accessibility tree still holds the real target in `AXURL`.
public enum AXHarvester {

    /// Walking a large app's tree is unbounded work; Electron and Catalyst apps in particular nest
    /// deeply and wide. These caps keep one harvest inside a scroll gesture's worth of time.
    private static let maxDepth = 60
    private static let maxNodes = 20_000

    /// Text-bearing leaf roles. Containers are excluded deliberately — their value often repeats
    /// their children's text, which would duplicate every row.
    ///
    /// Spelled as literals rather than the `kAX…Role` constants because two of the roles that
    /// matter most here — `AXLink` and `AXHeading` — are emitted by WebKit and web-derived views
    /// but never declared in the ApplicationServices headers.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXLink",
        "AXValueIndicator", "AXHeading", "AXCell", "AXMenuItem",
    ]

    /// Ceiling on any single accessibility request, in seconds.
    ///
    /// These calls are synchronous IPC into another process. The default has no useful bound, so a
    /// busy or beachballing target blocks the caller indefinitely — and since the overlay covers
    /// the screen, a blocked main thread means the user cannot even press Esc to get out. A short
    /// timeout converts a hang into a few missing rows.
    private static let messagingTimeout: Float = 0.4

    /// Resolve the accessibility element for a window we found via the window server.
    ///
    /// There is no public API mapping a `CGWindowID` to an `AXUIElement`, so this matches on
    /// geometry: the app's AX windows are compared against the known bounds. Ambiguity is rare
    /// because two windows of one app seldom share an origin and size exactly.
    public static func windowElement(for target: WindowTarget) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        // Applies to every message sent to this application, including via derived elements.
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        enableFullAccessibility(for: app)
        guard let windows = copyValue(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return nil
        }
        if windows.count == 1 { return windows[0] }

        var best: (element: AXUIElement, distance: CGFloat)?
        for window in windows {
            guard let frame = frame(of: window) else { continue }
            let delta = abs(frame.minX - target.bounds.minX)
                + abs(frame.minY - target.bounds.minY)
                + abs(frame.width - target.bounds.width)
                + abs(frame.height - target.bounds.height)
            if best == nil || delta < best!.distance {
                best = (window, delta)
            }
        }
        // A few points of slop absorbs shadow/titlebar accounting differences between the two APIs.
        guard let best, best.distance < 20 else { return windows.first }
        AXUIElementSetMessagingTimeout(best.element, messagingTimeout)
        return best.element
    }

    /// Ask an application to build its full accessibility tree.
    ///
    /// Chromium and Electron apps do not populate web-content accessibility until an assistive
    /// technology signals that it needs it — the tree is expensive to maintain, so it stays off by
    /// default. Without this a browser window reports a window element with **no children at all**,
    /// which is indistinguishable from "this app has no text" and was exactly why browsers appeared
    /// unsupported.
    ///
    /// Two attributes, because the apps disagree on which they honour:
    /// - `AXEnhancedUserInterface` is the long-standing signal set by VoiceOver; Electron and
    ///   several native apps respond to it.
    /// - `AXManualAccessibility` was added by Chromium specifically for automation tools that are
    ///   not screen readers, precisely this case.
    ///
    /// Both are set unconditionally: they are harmless no-ops on apps that already expose a full
    /// tree, and there is no reliable way to detect in advance which an app needs.
    public static func enableFullAccessibility(for app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Whether the element currently exposes any children — used to decide whether an app needs a
    /// moment after being asked to build its tree.
    public static func hasChildren(_ element: AXUIElement) -> Bool {
        guard let children = copyValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return false
        }
        return !children.isEmpty
    }

    /// One line per element for a structural dump of the tree.
    public struct TreeNode: Sendable {
        public let depth: Int
        public let role: String
        public let text: String?
        public let childCount: Int
        public let frame: CGRect?
    }

    /// Walk the tree recording structure rather than content.
    ///
    /// When a harvest comes back empty the question is *where the content isn't* — a browser that
    /// returns only its toolbar looks identical to one whose web area is nested somewhere the walk
    /// never reached. Roles and child counts answer that; extracted text does not.
    public static func dumpTree(
        element: AXUIElement, maxDepth limit: Int = 12, maxNodes cap: Int = 400
    ) -> [TreeNode] {
        var nodes: [TreeNode] = []
        var visited = 0
        walk(element: element, depth: 0, limit: limit, cap: cap, visited: &visited, into: &nodes)
        return nodes
    }

    private static func walk(
        element: AXUIElement, depth: Int, limit: Int, cap: Int,
        visited: inout Int, into nodes: inout [TreeNode]
    ) {
        guard depth <= limit, visited < cap else { return }
        visited += 1

        let role = (copyValue(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
        let children = (copyValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        nodes.append(TreeNode(
            depth: depth,
            role: role,
            text: text(of: element).map { String($0.prefix(60)) },
            childCount: children.count,
            frame: frame(of: element)
        ))
        for child in children {
            walk(element: child, depth: depth + 1, limit: limit, cap: cap, visited: &visited, into: &nodes)
        }
    }

    /// Harvest off the main thread.
    ///
    /// Even bounded, a full tree walk is thousands of synchronous round trips and can take long
    /// enough to visibly stall the overlay. Running it on a background queue keeps the UI — and the
    /// Esc key — responsive while a capture is in progress.
    public static func harvestAsync(
        window: AXUIElement, region: CGRect, completion: @escaping @Sendable ([CapturedRow]) -> Void
    ) {
        let box = UncheckedBox(window)
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = harvest(window: box.value, region: region)
            completion(rows)
        }
    }

    /// `AXUIElement` is a CoreFoundation type that is safe to use across threads but is not
    /// annotated `Sendable`, so it needs an explicit escape hatch to cross a queue boundary.
    private struct UncheckedBox: @unchecked Sendable {
        let value: AXUIElement
        init(_ value: AXUIElement) { self.value = value }
    }

    /// Harvest every text row inside `region` (CoreGraphics screen space).
    public static func harvest(window: AXUIElement, region: CGRect) -> [CapturedRow] {
        harvestWithDiagnostics(window: window, region: region).rows
    }

    private struct PositionedRow {
        let row: CapturedRow
        let y: Double
        let x: Double
        /// Index of the nearest scrollable ancestor, assigned during the walk. `nil` for rows that
        /// sit outside any scroll area (static chrome).
        let container: Int?
    }

    /// Roles that own an independent scroll position.
    ///
    /// Identifying these is not a refinement — it is required for correctness. A dragged region
    /// routinely spans more than one of them (a chat window's sidebar and its message list), and
    /// those areas scroll independently. Ordering their rows together by y produces a sequence that
    /// reshuffles every time one area moves and the other doesn't, which destroys the contiguous
    /// run the accumulator needs and makes every merge look like a gap.
    private static let scrollableRoles: Set<String> = [
        "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXWebArea", "AXGrid",
    ]

    private struct Container {
        let index: Int
        /// How much of the selected region this container covers. Used to pick the dominant one:
        /// stable across scrolling, unlike row counts, which fluctuate as content virtualizes.
        let coverage: CGFloat
    }

    // MARK: - Diagnostics

    /// What a walk of the tree actually found, for tuning `textRoles` against a specific app.
    ///
    /// Chat clients disagree about where a message body lives — `AXValue` on a static text node,
    /// or `AXDescription` on a group — and there is no way to know which without looking. This is
    /// the tool for looking.
    public struct Diagnostics: Sendable {
        public var nodesVisited = 0
        /// Every role seen inside the region, with how many carried text.
        public var roleCounts: [String: Int] = [:]
        public var roleWithTextCounts: [String: Int] = [:]
        /// Roles that carried text but were rejected because they aren't in `textRoles`.
        public var rejectedWithText: [String: Int] = [:]
        /// Sample text from rejected roles, to judge whether they should be admitted.
        public var rejectedSamples: [String: String] = [:]
        public var linksFound = 0
        public var hitNodeCap = false
        /// Independent scroll areas overlapping the region. More than one means the region spans
        /// areas that scroll separately, and only one of them can produce a stable sequence.
        public var containersFound = 0
        public var selectedContainer: Int?
        public var rowsOutsideDominantContainer = 0
    }

    /// Walk the tree collecting both rows and statistics about what was seen and skipped.
    public static func harvestWithDiagnostics(
        window: AXUIElement, region: CGRect
    ) -> (rows: [CapturedRow], diagnostics: Diagnostics) {
        var rows: [PositionedRow] = []
        var visited = 0
        var containers: [Container] = []
        var diagnostics = Diagnostics()
        _ = collect(
            element: window, region: region, depth: 0, container: nil,
            nodes: &visited, into: &rows, containers: &containers, diagnostics: &diagnostics
        )
        diagnostics.nodesVisited = visited
        diagnostics.hitNodeCap = visited >= maxNodes
        diagnostics.containersFound = containers.count

        // Rows are deliberately NOT filtered to a "dominant" scroll area any more.
        //
        // That heuristic existed to separate a sidebar from a message list, picking whichever
        // container covered most of the region. Two things killed it. WhatsApp exposes no scroll
        // areas at all, so it never fired where it was designed to help; and in a browser it fired
        // and was *wrong* — scroll areas nest, rows get tagged with the innermost, and coverage
        // picks an outer one, so a PDF's text was discarded as "outside the dominant container"
        // (19 of 25 rows).
        //
        // `ScrollingContentFilter` solves the same problem from a better angle — content that
        // scrolls moves, chrome doesn't — and needs no cooperation from the app's tree. The
        // container count is still reported, because knowing a region spans several independently
        // scrolling areas is useful when diagnosing a capture.
        diagnostics.linksFound = rows.reduce(0) { $0 + $1.row.links.count }
        rows.sort { lhs, rhs in
            if abs(lhs.y - rhs.y) < 4 { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
        return (rows.map(\.row), diagnostics)
    }

    /// Depth-first walk. Returns true when this subtree produced any row.
    ///
    /// A node only emits its own text if no descendant did. That single rule is what keeps
    /// container text from being duplicated on top of the leaves it contains — a chat bubble group
    /// whose `AXDescription` repeats the message body would otherwise print every message twice.
    private static func collect(
        element: AXUIElement,
        region: CGRect,
        depth: Int,
        container: Int?,
        nodes: inout Int,
        into rows: inout [PositionedRow],
        containers: inout [Container],
        diagnostics: inout Diagnostics
    ) -> Bool {
        guard depth < maxDepth, nodes < maxNodes else { return false }
        nodes += 1

        let elementFrame = frame(of: element)
        var container = container

        // Entering a scroll area starts a new grouping for everything beneath it. Nesting takes the
        // innermost, which is the one whose scroll position actually governs these rows.
        if let elementFrame,
           let role = copyValue(element, kAXRoleAttribute) as? String,
           scrollableRoles.contains(role) {
            let overlap = elementFrame.intersection(region)
            if !overlap.isNull, overlap.width > 0, overlap.height > 0 {
                let index = containers.count
                containers.append(Container(index: index, coverage: overlap.width * overlap.height))
                container = index
            }
        }

        // Prune whole subtrees that cannot contribute. Children are laid out inside their parent,
        // so a parent disjoint from the region has nothing to offer. Elements with no frame at all
        // are traversed anyway — some containers don't report geometry but their children do.
        if let elementFrame, elementFrame.width > 0, elementFrame.height > 0,
           !elementFrame.intersects(region) {
            return false
        }

        var childProduced = false
        if let children = copyValue(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                if collect(
                    element: child, region: region, depth: depth + 1, container: container,
                    nodes: &nodes, into: &rows, containers: &containers, diagnostics: &diagnostics
                ) {
                    childProduced = true
                }
            }
        }
        if childProduced { return true }

        guard let elementFrame, elementFrame.intersects(region) else { return false }

        let role = (copyValue(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
        diagnostics.roleCounts[role, default: 0] += 1

        guard let text = text(of: element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        diagnostics.roleWithTextCounts[role, default: 0] += 1

        guard textRoles.contains(role) || hasURL(element) else {
            // Recorded rather than dropped silently: a role holding real message text but missing
            // from `textRoles` is the single most likely reason a given app comes back empty.
            diagnostics.rejectedWithText[role, default: 0] += 1
            if diagnostics.rejectedSamples[role] == nil {
                diagnostics.rejectedSamples[role] = String(text.prefix(80))
            }
            return false
        }

        rows.append(PositionedRow(
            row: CapturedRow(
                text: text, role: role,
                links: links(of: element, text: text),
                y: Double(elementFrame.minY)
            ),
            y: Double(elementFrame.minY),
            x: Double(elementFrame.minX),
            container: container
        ))
        return true
    }

    // MARK: - Attribute reads

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Invisible bidirectional and formatting marks that apps sprinkle through accessibility
    /// labels. WhatsApp prefixes essentially every string with U+200E. They render as nothing,
    /// survive a copy-paste, and quietly defeat text comparison — including the accumulator's
    /// overlap matching, which is why they're stripped at the source rather than on output.
    private static let invisibleMarks: Set<Character> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}", "\u{200B}",
    ]

    private static func clean(_ value: String) -> String {
        let stripped = value.filter { !invisibleMarks.contains($0) }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(of element: AXUIElement) -> String? {
        // Order matters. `AXValue` is the actual content for text elements; `AXTitle` is the label
        // for controls; `AXDescription` is where Catalyst and Electron chat clients tend to put
        // message bodies when they don't expose them as static text.
        if let value = copyValue(element, kAXValueAttribute) as? String {
            let cleaned = clean(value)
            if !cleaned.isEmpty { return cleaned }
        }
        if let title = copyValue(element, kAXTitleAttribute) as? String {
            let cleaned = clean(title)
            if !cleaned.isEmpty { return cleaned }
        }
        if let desc = copyValue(element, kAXDescriptionAttribute) as? String {
            let cleaned = clean(desc)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    private static func hasURL(_ element: AXUIElement) -> Bool {
        copyValue(element, kAXURLAttribute) != nil
    }

    /// Link targets for an element, from two independent sources.
    ///
    /// `AXURL` is the good one — a real target, present even when the visible label is something
    /// else entirely. But it is far from universal: WhatsApp's Catalyst client exposes no `AXURL`
    /// on message rows at all, and instead puts the **full, unabbreviated** URL inside the message
    /// text. That still beats the pixel path, which only ever sees whatever the UI chose to render
    /// (routinely an ellipsised `docs.google.com/spreadsheets/d/1gQD…`), so text scanning is a real
    /// second source rather than a consolation prize.
    private static func links(of element: AXUIElement, text: String) -> [String] {
        var found: [String] = []

        if let url = copyValue(element, kAXURLAttribute) {
            if let nsurl = url as? NSURL, let string = nsurl.absoluteString {
                found.append(string)
            } else if let string = url as? String {
                found.append(string)
            }
        }

        for detected in detectURLs(in: text) where !found.contains(detected) {
            found.append(detected)
        }
        return found
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func detectURLs(in text: String) -> [String] {
        guard let linkDetector, text.contains(":/") || text.contains("www.") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return linkDetector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url else { return nil }
            // The detector happily reports `mailto:` for bare addresses and `x-apple-data-detectors`
            // for dates; only real web links are useful as clip targets.
            guard let scheme = url.scheme, ["http", "https"].contains(scheme) else { return nil }

            // Require the scheme to have been written, not inferred. The detector turns any bare
            // domain-looking token into a URL, so prose like "Factors.ai: the ABM platform" becomes
            // `http://Factors.ai` — a link that was never in the message.
            guard let matchRange = Range(match.range, in: text) else { return nil }
            guard text[matchRange].lowercased().hasPrefix("http") else { return nil }
            return url.absoluteString
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyValue(element, kAXPositionAttribute),
              let sizeValue = copyValue(element, kAXSizeAttribute)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // Force-cast through AXValue is required: these arrive as opaque CFTypes, not CGPoint/CGSize.
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
