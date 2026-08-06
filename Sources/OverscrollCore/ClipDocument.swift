import Foundation

/// How the content was pulled off the screen. Recorded in the output because it tells the reader
/// how much to trust it: the accessibility path carries real link targets and exact text, the OCR
/// path is a best-effort transcription of pixels.
public enum HarvestMode: String, Sendable, Codable {
    case accessibility
    case ocr
    case mixed
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

        for (index, row) in rows.enumerated() {
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

    private func line(for row: CapturedRow) -> String {
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
