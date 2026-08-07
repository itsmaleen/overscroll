import Foundation

/// How alike two strings are, for deciding whether they are two readings of the same line.
///
/// Needed because recognised text is not stable frame to frame. The same line of a document comes
/// back as "5. Markers/overlay circling…" in one pass and "• Markers/overlay circling…" in the
/// next; exact comparison says these are different lines, and containment says so too, because
/// neither contains the other. Only a tolerance for small differences groups them correctly.
public enum TextSimilarity {

    /// Fraction of characters shared, from 0 (nothing in common) to 1 (identical).
    ///
    /// Levenshtein rather than a token or n-gram overlap: OCR errors are overwhelmingly
    /// character-level — a substituted glyph, a dropped prefix, a split word — and edit distance
    /// measures exactly that. Strings here are single lines, so the quadratic cost is trivial.
    public static func ratio(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }

        let a = Array(lhs)
        let b = Array(rhs)
        // Length alone rules out most pairs, and cheaply — no point building a matrix to discover
        // that a 10-character line is not a reading of a 200-character one.
        let longer = Double(max(a.count, b.count))
        let shorter = Double(min(a.count, b.count))
        if shorter / longer < 0.5 { return 0 }

        let distance = levenshtein(a, b)
        return 1 - Double(distance) / longer
    }

    /// True when two strings are close enough to be the same line seen twice.
    public static func areSameLine(_ lhs: String, _ rhs: String, threshold: Double = 0.8) -> Bool {
        ratio(lhs, rhs) >= threshold
    }

    /// Two-row Levenshtein: the full matrix is never needed, only the previous row.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
