import AppKit

/// Scores how much a recognised line looks like real language.
///
/// Exists because the recogniser's own confidence turned out to be useless for this. Measured over
/// a full page, `VNRecognizedText.confidence` came back as exactly **1.00 for every line**,
/// including `"concurrenty, camuna rournier a Albe developea ine Uptopnone, a nananela scanner"`.
/// Ranking readings by a constant is the same as not ranking them.
///
/// What does separate a good reading from a bad one is that OCR failures produce *non-words*.
/// "todav" for "today", "vou" for "you", "developea" for "developed" — the substitutions are
/// visually plausible and lexically nonsense, so the proportion of real words is a direct measure
/// of how badly a line was read.
enum LexicalQuality {

    /// Fraction of word-like tokens that the system dictionary recognises, 0…1.
    ///
    /// Lines with nothing to check — pure numbers, symbols, a stray glyph — score neutrally rather
    /// than badly, since there is no evidence either way and a zero would rank them below genuine
    /// garbage.
    @MainActor
    static func score(_ text: String) -> Double {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            // Two-letter tokens are mostly noise in both directions and dominate short lines.
            .filter { $0.count >= 3 && $0.contains(where: \.isLetter) }

        guard !words.isEmpty else { return 0.5 }

        let checker = NSSpellChecker.shared
        var recognised = 0
        for word in words {
            let range = checker.checkSpelling(of: word, startingAt: 0)
            if range.location == NSNotFound { recognised += 1 }
        }
        return Double(recognised) / Double(words.count)
    }
}
