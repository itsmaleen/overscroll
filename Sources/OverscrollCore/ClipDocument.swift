import Foundation

/// How the content was pulled off the screen. Recorded in the output because it tells the reader
/// how much to trust it: the accessibility path carries real link targets and exact text, the OCR
/// path is a best-effort transcription of pixels.
public enum HarvestMode: String, Sendable, Codable {
    case accessibility
    case ocr
    case mixed
    /// Read from the page source. The best of the three: exact text and real link targets,
    /// with no reliance on what happened to be rendered.
    case dom
}

/// Ambient context captured alongside the content, so a clip pasted into a session three days
/// later still says what it is and where it came from.
public struct ClipContext: Sendable, Codable {
    public var appName: String
    public var windowTitle: String?
    /// Present for browsers, where the frontmost tab's address is worth more than its title.
    public var url: String?
    public var capturedAt: Date
    public var regionDescription: String?

    public init(
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil,
        capturedAt: Date = Date(),
        regionDescription: String? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.capturedAt = capturedAt
        self.regionDescription = regionDescription
    }
}

/// Renders an accumulated transcript into the markdown that lands on the clipboard.
public struct ClipDocument: Sendable {
    public let context: ClipContext
    public let rows: [CapturedRow]
    public let gapIndices: Set<Int>
    public let mode: HarvestMode

    public init(context: ClipContext, rows: [CapturedRow], gapIndices: [Int] = [], mode: HarvestMode) {
        self.context = context
        self.rows = rows
        self.gapIndices = Set(gapIndices)
        self.mode = mode
    }

    public func render() -> String {
        var out = frontMatter()
        out += "\n"

        for (index, row) in rejoinWrappedLines(collapseNearDuplicates(rows)).enumerated() {
            out += line(for: row)
            out += "\n"
            if gapIndices.contains(index) {
                // Marked inline rather than only in the header: whoever reads this needs to know
                // the hole is *here*, not merely that one exists somewhere.
                out += "\n> [overscroll] content skipped — scrolled past a full viewport\n\n"
            }
        }

        let collected = collectedLinks()
        if !collected.isEmpty {
            out += "\n## Links\n\n"
            for link in collected { out += "- \(link)\n" }
        }

        return out
    }

    /// Collapse adjacent rows that are the same line read twice.
    ///
    /// Positional de-duplication cannot catch this. Recognised text is not stable frame to frame —
    /// the same line comes back with its bullet or list number in one pass and without it in the
    /// next — so the two have different identities *and* land a few points apart, and both survive.
    /// Observed on a Google Doc: "5. Markers/overlay circling…" immediately followed by
    /// "Markers/overlay circling…".
    ///
    /// Only adjacent rows are compared, and only when one contains the other, so distinct lines
    /// that merely repeat elsewhere in the document are untouched. The longer wins, since it is the
    /// one that kept its prefix.
    private func collapseNearDuplicates(_ rows: [CapturedRow]) -> [CapturedRow] {
        var result: [CapturedRow] = []
        for row in rows {
            guard let previous = result.last else {
                result.append(row)
                continue
            }
            let a = previous.identity
            let b = row.identity
            // Guard on length: short strings contain each other by coincidence far too easily.
            let overlapping = min(a.count, b.count) >= 8 && (a.contains(b) || b.contains(a))
            guard overlapping else {
                result.append(row)
                continue
            }
            if b.count > a.count { result[result.count - 1] = row }
        }
        return result
    }

    /// Rejoin a sentence that the renderer broke across visual lines.
    ///
    /// OCR reports what it sees, and what it sees is *lines*, not paragraphs. A wrapped sentence
    /// therefore arrives as several rows and its tail is orphaned — a Google Doc capture ended with
    /// "…should be able to zoom like camera" and then "app" alone on the next line, and a bullet's
    /// second half detached from the bullet entirely.
    ///
    /// The join is deliberately conservative, because wrongly merging two real lines is worse than
    /// leaving a fragment: it requires the continuation to begin lowercase *and* the previous line
    /// to end without terminal punctuation. Both hold for a wrap and rarely for anything else. Only
    /// recognised text is touched; accessibility rows already arrive as whole paragraphs.
    private func rejoinWrappedLines(_ rows: [CapturedRow]) -> [CapturedRow] {
        var result: [CapturedRow] = []
        for row in rows {
            guard let previous = result.last,
                  previous.role == "OCRLine", row.role == "OCRLine",
                  continuesPreviousLine(previous: previous.text, next: row.text)
            else {
                result.append(row)
                continue
            }
            result[result.count - 1] = CapturedRow(
                text: previous.text + " " + row.text.trimmingCharacters(in: .whitespaces),
                role: previous.role,
                links: previous.links + row.links,
                y: previous.y,
                x: previous.x,
                isSelected: previous.isSelected
            )
        }
        return result
    }

    private func continuesPreviousLine(previous: String, next: String) -> Bool {
        guard let tail = previous.trimmingCharacters(in: .whitespaces).last,
              let head = next.trimmingCharacters(in: .whitespaces).first
        else { return false }
        // A sentence that ended is not continued.
        guard !".!?:;•".contains(tail) else { return false }
        // A list marker starts something new, whatever its case.
        guard !"-•*".contains(head), !head.isNumber else { return false }
        // Lowercase start is the signal that carries the most weight and the least risk.
        return head.isLowercase
    }

    private func line(for row: CapturedRow) -> String {
        // Controls render as their form meaning rather than as bare labels. On a form the answer
        // *is* the selection state, so "Software Engineering" and "Research" are indistinguishable
        // without it — and which one is chosen is usually the only part worth capturing.
        if let isSelected = row.isSelected {
            return "- [\(isSelected ? "x" : " ")] \(row.text)"
        }
        switch row.role {
        case "AXButton", "AXPopUpButton":
            return "[\(row.text)]"
        case "AXHeading":
            return "## \(row.text)"
        default:
            break
        }

        // A link row whose text differs from its target is written as a real markdown link, which
        // is the payload the pixel path structurally cannot produce.
        if row.role == "AXLink", let target = row.links.first {
            let label = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { return target }
            if label == target { return target }
            return "[\(label)](\(target))"
        }

        var text = row.text
        // Inline any link targets that the element exposed but that aren't already spelled out in
        // the visible text — the truncated-URL case ("linkedin.com/in/some…").
        let hidden = row.links.filter { !text.contains($0) }
        if !hidden.isEmpty {
            text += " " + hidden.map { "<\($0)>" }.joined(separator: " ")
        }
        return text
    }

    private func collectedLinks() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            for link in row.links where !seen.contains(link) {
                seen.insert(link)
                ordered.append(link)
            }
        }
        return ordered
    }

    private func frontMatter() -> String {
        var out = "---\n"
        out += "source: \(yamlScalar(context.appName))\n"
        if let title = context.windowTitle, !title.isEmpty {
            out += "window: \(yamlScalar(title))\n"
        }
        if let url = context.url, !url.isEmpty {
            out += "url: \(yamlScalar(url))\n"
        }
        out += "captured: \(ISO8601DateFormatter().string(from: context.capturedAt))\n"
        if let region = context.regionDescription {
            out += "region: \(yamlScalar(region))\n"
        }
        out += "mode: \(mode.rawValue)\n"
        out += "rows: \(rows.count)\n"
        if !gapIndices.isEmpty {
            out += "gaps: \(gapIndices.count)\n"
        }
        out += "---\n"
        return out
    }

    /// Quote anything that would otherwise break the YAML block. Window titles are arbitrary user
    /// text and routinely contain colons, quotes, and leading dashes.
    private func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
