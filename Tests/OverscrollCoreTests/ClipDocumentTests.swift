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

@Suite("ClipDocument OCR noise")
struct ClipDocumentOCRNoiseTests {

    private func context() -> ClipContext {
        ClipContext(appName: "Helium", capturedAt: Date(timeIntervalSince1970: 1_770_000_000))
    }

    private func render(_ texts: [String]) -> [String] {
        let rows = texts.map { CapturedRow(text: $0, role: "OCRLine") }
        return ClipDocument(context: context(), rows: rows, mode: .ocr)
            .render()
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("---") && !$0.contains(":") || $0.hasPrefix("- ") == false }
    }

    // Recognised text is not stable frame to frame: the same line returns with its list number in
    // one pass and without it in the next, so both survive positional de-duplication.
    @Test("an adjacent repeat missing its list prefix is collapsed, keeping the fuller one")
    func collapsesPrefixVariant() {
        let out = render([
            "5. Markers/overlay circling or identifying what it is referencing",
            "Markers/overlay circling or identifying what it is referencing",
            "6. Responses can be very long winded sometimes",
        ])
        #expect(out.contains("5. Markers/overlay circling or identifying what it is referencing"))
        #expect(!out.contains("Markers/overlay circling or identifying what it is referencing"))
        #expect(out.contains("6. Responses can be very long winded sometimes"))
    }

    @Test("an exact adjacent repeat is collapsed")
    func collapsesExactRepeat() {
        let out = render([
            "- Not the end of the world but we can play with it a bit",
            "- Not the end of the world but we can play with it a bit",
        ])
        #expect(out.filter { $0.contains("end of the world") }.count == 1)
    }

    // The same line legitimately appearing twice, far apart, must survive.
    @Test("a repeat that is not adjacent is kept")
    func keepsNonAdjacentRepeat() {
        let out = render(["Overview of the thing", "something else entirely here", "Overview of the thing"])
        #expect(out.filter { $0.contains("Overview of the thing") }.count == 2)
    }

    // Short strings contain one another by coincidence constantly.
    @Test("short adjacent rows are not collapsed on coincidental containment")
    func keepsShortRows() {
        let out = render(["Yes", "Yes and no", "No"])
        #expect(out.contains("Yes"))
        #expect(out.contains("Yes and no"))
    }
}

@Suite("ClipDocument wrapped lines")
struct ClipDocumentWrapTests {

    private func body(_ texts: [String], role: String = "OCRLine") -> [String] {
        let rows = texts.map { CapturedRow(text: $0, role: role) }
        let out = ClipDocument(
            context: ClipContext(appName: "Helium", capturedAt: Date(timeIntervalSince1970: 1)),
            rows: rows, mode: .ocr
        ).render()
        // Body only: drop the YAML block.
        let parts = out.components(separatedBy: "---\n")
        return (parts.last ?? "").split(separator: "\n").map(String.init)
    }

    // The exact case from a Google Doc capture: the sentence's tail stranded on its own line.
    @Test("a lowercase continuation is rejoined to the line above")
    func rejoinsWrappedTail() {
        let out = body([
            "- When trying to zoom in, it zooms the full browser. Should be able to zoom like camera",
            "app",
            "3. Being able to record demo with audio",
        ])
        #expect(out.contains { $0.hasSuffix("zoom like camera app") })
        #expect(!out.contains("app"))
        #expect(out.contains("3. Being able to record demo with audio"))
    }

    @Test("a line after terminal punctuation is left alone")
    func respectsSentenceEnd() {
        let out = body(["That is the end.", "another thought entirely"])
        #expect(out.contains("That is the end."))
        #expect(out.contains("another thought entirely"))
    }

    @Test("a new list item is never absorbed, whatever its case")
    func neverAbsorbsListItems() {
        let out = body([
            "4. Voice seems a bit robotic sometimes",
            "- not the end of the world but we can play with it",
        ])
        #expect(out.contains("4. Voice seems a bit robotic sometimes"))
        #expect(out.contains { $0.contains("not the end of the world") && $0.hasPrefix("-") })
    }

    @Test("an uppercase start is treated as a new line, not a continuation")
    func uppercaseStartsNewLine() {
        let out = body(["Something without punctuation", "Another separate line"])
        #expect(out.contains("Something without punctuation"))
        #expect(out.contains("Another separate line"))
    }

    // Accessibility rows already arrive as whole paragraphs, so joining them would be wrong.
    @Test("accessibility rows are never rejoined")
    func leavesAccessibilityRowsAlone() {
        let out = body(["a line with no full stop", "continuation looking text"], role: "AXStaticText")
        #expect(out.contains("a line with no full stop"))
        #expect(out.contains("continuation looking text"))
    }
}
