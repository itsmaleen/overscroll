import Foundation
import Testing
@testable import OverscrollCore

@Suite("ClipDocument")
struct ClipDocumentTests {

    private func context(
        app: String = "WhatsApp",
        title: String? = "Sarah Chen",
        url: String? = nil
    ) -> ClipContext {
        ClipContext(
            appName: app,
            windowTitle: title,
            url: url,
            capturedAt: Date(timeIntervalSince1970: 1_770_000_000),
            regionDescription: "620x880 @ (340,180)"
        )
    }

    @Test("front matter records provenance and harvest mode")
    func frontMatter() {
        let doc = ClipDocument(
            context: context(),
            rows: [CapturedRow(text: "hello")],
            mode: .accessibility
        )
        let out = doc.render()
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("source: \"WhatsApp\""))
        #expect(out.contains("window: \"Sarah Chen\""))
        #expect(out.contains("mode: accessibility"))
        #expect(out.contains("rows: 1"))
    }

    // Window titles are arbitrary user text. An unquoted colon silently corrupts the YAML block,
    // which is the one part of the output another tool is most likely to parse.
    @Test("window titles containing YAML metacharacters stay parseable")
    func escapesYAML() {
        let doc = ClipDocument(
            context: context(title: "Re: \"urgent\" — 3:15pm"),
            rows: [CapturedRow(text: "x")],
            mode: .accessibility
        )
        let line = doc.render()
            .split(separator: "\n")
            .first { $0.hasPrefix("window:") }
        #expect(line == #"window: "Re: \"urgent\" — 3:15pm""#)
    }

    // The payload the pixel path structurally cannot produce.
    @Test("a link row renders its real target, not the display text")
    func linkRowUsesRealTarget() {
        let row = CapturedRow(
            text: "linkedin.com/in/some…",
            role: "AXLink",
            links: ["https://www.linkedin.com/in/someone-real-12345/"]
        )
        let out = ClipDocument(context: context(), rows: [row], mode: .accessibility).render()
        #expect(out.contains("[linkedin.com/in/some…](https://www.linkedin.com/in/someone-real-12345/)"))
    }

    @Test("a link whose text already is the target renders bare")
    func barelink() {
        let row = CapturedRow(text: "https://example.com", role: "AXLink", links: ["https://example.com"])
        let out = ClipDocument(context: context(), rows: [row], mode: .accessibility).render()
        #expect(out.contains("\nhttps://example.com\n"))
        #expect(!out.contains("]("))
    }

    @Test("a non-link row carrying a hidden target has it appended")
    func hiddenTargetOnPlainRow() {
        let row = CapturedRow(
            text: "check this out",
            role: "AXStaticText",
            links: ["https://example.com/deep/link"]
        )
        let out = ClipDocument(context: context(), rows: [row], mode: .accessibility).render()
        #expect(out.contains("check this out <https://example.com/deep/link>"))
    }

    @Test("links are collected once, in order, without duplicates")
    func linkIndex() {
        let rows = [
            CapturedRow(text: "a", links: ["https://one.example"]),
            CapturedRow(text: "b", links: ["https://two.example"]),
            CapturedRow(text: "c", links: ["https://one.example"]),
        ]
        let out = ClipDocument(context: context(), rows: rows, mode: .accessibility).render()
        let index = out.range(of: "## Links")!
        let tail = String(out[index.upperBound...])
        #expect(tail.contains("- https://one.example"))
        #expect(tail.contains("- https://two.example"))
        #expect(tail.components(separatedBy: "- https://one.example").count - 1 == 1)
    }

    @Test("no Links section when there are no links")
    func noLinkSection() {
        let out = ClipDocument(
            context: context(), rows: [CapturedRow(text: "plain")], mode: .accessibility
        ).render()
        #expect(!out.contains("## Links"))
    }

    // A transcript with an unmarked hole reads as complete, which is worse than one that admits it.
    @Test("gaps are marked inline at the point content was skipped")
    func gapsMarkedInline() {
        let rows = [CapturedRow(text: "a"), CapturedRow(text: "b"), CapturedRow(text: "c")]
        let out = ClipDocument(
            context: context(), rows: rows, gapIndices: [1], mode: .accessibility
        ).render()
        #expect(out.contains("gaps: 1"))

        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        let marker = lines.firstIndex { $0.contains("content skipped") }
        let b = lines.firstIndex { $0 == "b" }
        let c = lines.firstIndex { $0 == "c" }
        #expect(b! < marker!)
        #expect(marker! < c!)
    }

    @Test("OCR mode is labelled so the reader knows links may be lost")
    func ocrModeLabelled() {
        let out = ClipDocument(
            context: context(), rows: [CapturedRow(text: "x", role: "OCRLine")], mode: .ocr
        ).render()
        #expect(out.contains("mode: ocr"))
    }

    @Test("browser URL is recorded when present")
    func browserURL() {
        let out = ClipDocument(
            context: context(app: "Safari", title: "Some Page", url: "https://example.com/article"),
            rows: [CapturedRow(text: "x")],
            mode: .accessibility
        ).render()
        #expect(out.contains("url: \"https://example.com/article\""))
    }
}
