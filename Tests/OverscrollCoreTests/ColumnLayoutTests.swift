import Testing
@testable import OverscrollCore

private func rows(_ items: [(Double, Double)]) -> [ColumnLayout.Row] {
    items.map { ColumnLayout.Row(x: $0.0, y: $0.1) }
}

@Suite("ColumnLayout")
struct ColumnLayoutTests {

    // The job-posting case: description on the left, application form on the right, occupying the
    // same vertical span. A y-major sort interleaves them line by line.
    @Test("two side-by-side columns are detected")
    func detectsTwoColumns() {
        var items: [(Double, Double)] = []
        for index in 0..<10 {
            items.append((40, Double(index) * 30))       // left column
            items.append((600, Double(index) * 30 + 12)) // right column, same vertical span
        }
        let boundary = ColumnLayout.columnBoundary(for: rows(items))
        #expect(boundary != nil)
        if let boundary { #expect(boundary > 40 && boundary < 600) }
    }

    // The dangerous false positive: splitting an indented list would scatter every bullet away
    // from its own continuation lines.
    @Test("an indented list is not two columns")
    func indentedListIsNotColumns() {
        var items: [(Double, Double)] = []
        for index in 0..<10 {
            items.append((40, Double(index) * 40))       // bullet
            items.append((62, Double(index) * 40 + 18))  // its continuation, indented 22pt
        }
        #expect(ColumnLayout.columnBoundary(for: rows(items)) == nil)
    }

    @Test("a single column of prose is not split")
    func singleColumn() {
        let items = (0..<20).map { (40.0, Double($0) * 24) }
        #expect(ColumnLayout.columnBoundary(for: rows(items)) == nil)
    }

    // A few rows to the right are a caption or a set of timestamps, not a column.
    @Test("a sparse right-hand group is not a column")
    func sparseRightGroup() {
        var items = (0..<20).map { (40.0, Double($0) * 24) }
        items.append((700, 40))
        items.append((700, 120))
        #expect(ColumnLayout.columnBoundary(for: rows(items)) == nil)
    }

    // Content that moves right partway down is one column that changed indent, not two.
    @Test("groups that follow one another vertically are not columns")
    func sequentialGroupsAreNotColumns() {
        var items: [(Double, Double)] = []
        for index in 0..<8 { items.append((40, Double(index) * 30)) }
        for index in 0..<8 { items.append((700, 400 + Double(index) * 30)) }
        #expect(ColumnLayout.columnBoundary(for: rows(items)) == nil)
    }

    @Test("too few rows to judge is not a split")
    func tooFewRows() {
        #expect(ColumnLayout.columnBoundary(for: rows([(40, 0), (600, 10)])) == nil)
    }

    @Test("identical x positions cannot be split")
    func degenerate() {
        let items = (0..<15).map { (100.0, Double($0) * 20) }
        #expect(ColumnLayout.columnBoundary(for: rows(items)) == nil)
    }
}

@Suite("ScrollTranscript column ordering")
struct TranscriptColumnOrderingTests {

    // End to end: the failure from a real job-posting capture, where the description and the
    // application form alternated line by line.
    @Test("a two-column page reads one column at a time")
    func readsColumnsSeparately() {
        var transcript = ScrollTranscript()
        var snapshot: [CapturedRow] = []
        for index in 0..<8 {
            snapshot.append(CapturedRow(text: "left \(index)", y: Double(index) * 30, x: 40))
            snapshot.append(CapturedRow(text: "right \(index)", y: Double(index) * 30 + 10, x: 700))
        }
        transcript.ingest(snapshot)

        let texts = transcript.rows.map(\.text)
        let firstRight = texts.firstIndex { $0.hasPrefix("right") } ?? texts.count
        let lastLeft = texts.lastIndex { $0.hasPrefix("left") } ?? 0
        #expect(lastLeft < firstRight)
        #expect(texts.first == "left 0")
    }

    // Ordinary prose must keep reading top to bottom.
    @Test("single-column prose keeps its natural order")
    func singleColumnUnchanged() {
        var transcript = ScrollTranscript()
        let snapshot = (0..<10).map {
            CapturedRow(text: "line \($0)", y: Double($0) * 24, x: 40)
        }
        transcript.ingest(snapshot)
        #expect(transcript.rows.map(\.text) == (0..<10).map { "line \($0)" })
    }

    // The regression that would hurt most: a bullet separated from its own continuation lines.
    @Test("an indented list keeps each bullet with its continuation")
    func indentedListStaysInOrder() {
        var transcript = ScrollTranscript()
        var snapshot: [CapturedRow] = []
        for index in 0..<8 {
            snapshot.append(CapturedRow(text: "- bullet \(index)", y: Double(index) * 40, x: 40))
            snapshot.append(CapturedRow(text: "continuation \(index)", y: Double(index) * 40 + 18, x: 62))
        }
        transcript.ingest(snapshot)

        let texts = transcript.rows.map(\.text)
        for index in 0..<8 {
            let bullet = texts.firstIndex(of: "- bullet \(index)")!
            let continuation = texts.firstIndex(of: "continuation \(index)")!
            #expect(continuation == bullet + 1)
        }
    }
}
