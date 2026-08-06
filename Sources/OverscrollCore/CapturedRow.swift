import Foundation

/// One harvested line of content. Comes from either an accessibility element or an OCR text line.
///
/// `text` is what gets written out. `identity` is what alignment compares on — normalized so that
/// trivial whitespace churn between scroll steps doesn't break an overlap match.
public struct CapturedRow: Sendable, Equatable, Codable {
    /// Display text, as harvested.
    public let text: String
    /// Accessibility role (e.g. `AXStaticText`, `AXLink`) or `OCRLine` for the OCR path.
    public let role: String
    /// Real link targets. This is the whole reason the accessibility path exists — OCR only ever
    /// sees the display text, so a shortened or truncated link is lost forever on the pixel path.
    public let links: [String]
    /// Vertical position in screen coordinates at harvest time. Orders rows *within* one snapshot;
    /// meaningless across snapshots because the content moves.
    public let y: Double

    public init(text: String, role: String = "AXStaticText", links: [String] = [], y: Double = 0) {
        self.text = text
        self.role = role
        self.links = links
        self.y = y
    }

    /// Normalized comparison key: collapsed whitespace, case-folded.
    ///
    /// Deliberately excludes `y` (content moves as you scroll) and `links` (the same row can expose
    /// a link on one pass and not the next if the element was only partially realized).
    public var identity: String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Rows with no visible text carry no information and would create spurious overlap matches.
    public var isEmpty: Bool { identity.isEmpty }
}
