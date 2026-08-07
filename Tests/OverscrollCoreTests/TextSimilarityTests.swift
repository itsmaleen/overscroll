import Testing
@testable import OverscrollCore

@Suite("TextSimilarity")
struct TextSimilarityTests {

    @Test("identical strings are identical")
    func identical() {
        #expect(TextSimilarity.ratio("hello world", "hello world") == 1)
    }

    // The real case: the same document line read with its list marker in one pass and a
    // misrecognised marker in the next. Neither contains the other, so containment cannot group
    // them and only a tolerance does.
    @Test("a line differing only in its list marker is the same line")
    func listMarkerVariant() {
        let a = "5. Markers/overlay circling or identifying what it is referencing"
        let b = "• Markers/overlay circling or identifying what it is referencing"
        #expect(TextSimilarity.areSameLine(a, b))
    }

    @Test("a line missing its bullet prefix is the same line")
    func missingPrefix() {
        let a = "- Putting something to show user what Ironhand is referencing"
        let b = "Putting something to show user what Ironhand is referencing"
        #expect(TextSimilarity.areSameLine(a, b))
    }

    @Test("a single substituted glyph is the same line")
    func glyphSubstitution() {
        #expect(TextSimilarity.areSameLine(
            "capturing full context of message",
            "capturlng full context of message"
        ))
    }

    // Merging two genuinely different lines would corrupt the transcript, so the threshold has to
    // reject things that merely look alike.
    @Test("different sentences are not the same line")
    func differentSentences() {
        #expect(!TextSimilarity.areSameLine(
            "1. Bigger button for quick chat showing core feature",
            "2. Zooming in on just the camera"
        ))
    }

    @Test("very different lengths short-circuit to no match")
    func lengthMismatch() {
        #expect(TextSimilarity.ratio("short", "a very much longer line of text entirely") == 0)
    }

    @Test("an empty string matches nothing")
    func empties() {
        #expect(TextSimilarity.ratio("", "something") == 0)
        #expect(TextSimilarity.ratio("something", "") == 0)
    }
}
