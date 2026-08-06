import AppKit
import ApplicationServices
import OverscrollAX
import OverscrollCore

/// Diagnostic CLI: point it at an app and see exactly what the harvester sees.
///
/// Exists because "the accessibility tree has the text" is an assumption until measured, and it
/// differs per app — Catalyst, Electron, and AppKit clients each put message bodies somewhere
/// different. Driving the GUI tells you only that a capture came back empty; this tells you why.
///
///   axprobe WhatsApp                  full window
///   axprobe WhatsApp --rows 40        cap printed rows
///   axprobe WhatsApp --scroll down:5  scroll N times, showing the merge outcome each step

struct Options {
    var appName = ""
    var maxRows = 25
    var scrollDirection: Scroller.Direction?
    var scrollCount = 0
    var listWindows = false
    /// Route scroll events through the HID tap (hit-tested by location) instead of to the process.
    var useHID = false
    var verbose = false
    /// Render the finished ClipDocument, exactly as the app would put it on the clipboard.
    var emit = false
    var adaptive = false
    var burst = 1
    var step = Scroller.defaultStep
    /// Sub-region as fractions of the window: minX,minY,maxX,maxY. Chat apps put navigation chrome
    /// in a sidebar, so probing the whole window measures the wrong thing.
    var regionFractions: (CGFloat, CGFloat, CGFloat, CGFloat)?
}

func parseArguments() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--list":
            options.listWindows = true
        case "--hid":
            options.useHID = true
        case "--verbose":
            options.verbose = true
        case "--emit":
            options.emit = true
        case "--adaptive":
            options.adaptive = true
        case "--burst":
            // Scrolls per harvest. Reproduces what happens when harvests are dropped: the content
            // moves further than any single pair of snapshots can bridge.
            if let value = arguments.first, let parsed = Int(value) {
                options.burst = max(1, parsed)
                arguments.removeFirst()
            }
        case "--step":
            if let value = arguments.first, let parsed = Int32(value) {
                options.step = parsed
                arguments.removeFirst()
            }
        case "--rows":
            if let value = arguments.first, let parsed = Int(value) {
                options.maxRows = parsed
                arguments.removeFirst()
            }
        case "--scroll":
            if let value = arguments.first {
                arguments.removeFirst()
                let parts = value.split(separator: ":")
                let directions: [String: Scroller.Direction] = [
                    "up": .up, "down": .down, "left": .left, "right": .right,
                ]
                options.scrollDirection = directions[String(parts[0])]
                options.scrollCount = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            }
        case "--region":
            if let value = arguments.first {
                arguments.removeFirst()
                let parts = value.split(separator: ",").compactMap { Double($0) }
                if parts.count == 4 {
                    options.regionFractions = (
                        CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]), CGFloat(parts[3])
                    )
                }
            }
        default:
            if options.appName.isEmpty { options.appName = argument }
        }
    }
    return options
}

func printDiagnostics(_ diagnostics: AXHarvester.Diagnostics) {
    print("  nodes visited:     \(diagnostics.nodesVisited)\(diagnostics.hitNodeCap ? "  ⚠️ HIT NODE CAP" : "")")
    print("  links found:       \(diagnostics.linksFound)")
    print("  scroll areas:      \(diagnostics.containersFound)"
        + (diagnostics.selectedContainer.map { "  → using #\($0), discarded \(diagnostics.rowsOutsideDominantContainer) rows outside it" } ?? "  (no disambiguation needed)"))

    if !diagnostics.roleWithTextCounts.isEmpty {
        print("  roles with text:")
        for (role, count) in diagnostics.roleWithTextCounts.sorted(by: { $0.value > $1.value }).prefix(12) {
            let accepted = diagnostics.rejectedWithText[role] == nil
            print("    \(accepted ? "✓" : "✗") \(role.padding(toLength: 24, withPad: " ", startingAt: 0)) \(count)")
        }
    }
    if !diagnostics.rejectedWithText.isEmpty {
        print("  REJECTED roles carrying text (candidates for AXHarvester.textRoles):")
        for (role, count) in diagnostics.rejectedWithText.sorted(by: { $0.value > $1.value }).prefix(8) {
            let sample = diagnostics.rejectedSamples[role] ?? ""
            print("    \(role) ×\(count)  e.g. \(sample.replacingOccurrences(of: "\n", with: " "))")
        }
    }
}

let options = parseArguments()

guard AXIsProcessTrusted() else {
    print("""
    ✗ This process does not have Accessibility permission.

    The probe inherits the grant of whatever launched it. Give your terminal Accessibility access
    in System Settings > Privacy & Security > Accessibility, then run it again. Granting the
    Overscroll app does not cover a separate binary.
    """)
    exit(1)
}

let windows = WindowResolver.candidates()

if options.listWindows || options.appName.isEmpty {
    print("On-screen windows (front to back):\n")
    for window in windows {
        let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
        print("  \(window.appName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(window.title ?? "")")
    }
    exit(0)
}

guard let target = windows.first(where: {
    $0.appName.localizedCaseInsensitiveContains(options.appName)
}) else {
    print("✗ No on-screen window for '\(options.appName)'. Run with --list to see what's available.")
    exit(1)
}

print("Target: \(target.appName) — \(target.title ?? "(untitled)")")
print("Bounds: \(Int(target.bounds.width))x\(Int(target.bounds.height)) @ (\(Int(target.bounds.minX)),\(Int(target.bounds.minY)))")
print("PID:    \(target.pid)\n")

guard let element = AXHarvester.windowElement(for: target) else {
    print("✗ Could not resolve an accessibility element for that window.")
    print("  The app may not expose an AX tree at all — that's the canvas-rendered case the OCR fallback exists for.")
    exit(1)
}

var contentFilter = ScrollingContentFilter()
var adaptiveStep = Scroller.AdaptiveScrollStep()
/// Run both merge strategies over the identical snapshot stream, so the comparison is not
/// confounded by the target having scrolled differently between two separate runs.
var transcript = ScrollTranscript()
let region: CGRect
if let fractions = options.regionFractions {
    let bounds = target.bounds
    region = CGRect(
        x: bounds.minX + bounds.width * fractions.0,
        y: bounds.minY + bounds.height * fractions.1,
        width: bounds.width * (fractions.2 - fractions.0),
        height: bounds.height * (fractions.3 - fractions.1)
    )
    print("Region: \(Int(region.width))x\(Int(region.height)) @ (\(Int(region.minX)),\(Int(region.minY)))\n")
} else {
    region = target.bounds
}
var accumulator = ScrollAccumulator()

let (rows, diagnostics) = AXHarvester.harvestWithDiagnostics(window: element, region: region)
print("=== initial harvest ===")
print("  rows: \(rows.count)")
printDiagnostics(diagnostics)
for release in contentFilter.accept(rows) {
    accumulator.ingest(release)
    transcript.ingest(release)
}

if let direction = options.scrollDirection, options.scrollCount > 0 {
    let center = CGPoint(x: region.midX, y: region.midY)
    print("\n=== scrolling \(options.scrollCount)× via \(options.useHID ? "HID tap at (\(Int(center.x)),\(Int(center.y)))" : "postToPid") ===")
    for step in 1...options.scrollCount {
        let previous = accumulator.rows
        let effectiveStep = options.adaptive ? adaptiveStep.current : options.step
        for _ in 0..<options.burst {
            if options.useHID {
                Scroller.scrollViaHID(direction, step: effectiveStep, at: center)
            } else {
                Scroller.scroll(direction, step: effectiveStep, toPID: target.pid)
            }
            if options.burst > 1 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        // Give the app a beat to lay out the newly revealed rows before reading again.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let (stepRows, _) = AXHarvester.harvestWithDiagnostics(window: element, region: region)
        let hint: ScrollHint = (direction == .up) ? .towardStart : .towardEnd
        // Sign matches screen space: scrolling toward the start moves content down (positive).
        let commanded = Double(effectiveStep) * (direction == .up ? 1 : -1)
        let releases = contentFilter.accept(stepRows)
        var outcomes: [MergeOutcome] = []
        for release in releases {
            outcomes.append(accumulator.ingest(release, hint: hint))
            transcript.ingest(release, commandedDisplacement: commanded)
        }
        for outcome in outcomes {
            switch outcome {
            case .gap: adaptiveStep.registerGap()
            case .appended, .prepended: adaptiveStep.registerCleanMerge()
            case .unchanged: break
            }
        }
        let described = outcomes.isEmpty ? "held" : outcomes.map { "\($0)" }.joined(separator: ", ")
        print("  step \(step): saw \(stepRows.count) rows"
            + " (\(stepRows.count - contentFilter.strip(stepRows).count) chrome)"
            + " → \(described), total \(accumulator.rows.count)")

        if options.verbose {
            // When a merge comes back as a gap, the question is always the same: did the two
            // snapshots really share nothing, or did the shared rows fail to compare equal?
            let previousIdentities = Set(previous.map(\.identity))
            let shared = stepRows.filter { previousIdentities.contains($0.identity) }
            print("      shared with transcript so far: \(shared.count)/\(stepRows.count)")
            for row in stepRows.prefix(3) {
                print("      head: \(row.text.prefix(70))")
            }
        }
    }
}

print("\n=== transcript (\(accumulator.rows.count) rows, showing \(min(options.maxRows, accumulator.rows.count))) ===")
for row in accumulator.rows.prefix(options.maxRows) {
    let links = row.links.isEmpty ? "" : "  → \(row.links.joined(separator: " "))"
    print("  [\(row.role)] \(row.text.replacingOccurrences(of: "\n", with: " ").prefix(110))\(links)")
}

if !accumulator.gapIndices.isEmpty {
    print("\n⚠️  \(accumulator.gapIndices.count) gap(s) — scroll steps outran the viewport.")
}

print("\n=== strategy comparison (same snapshot stream) ===")
print("  run-alignment (ScrollAccumulator): \(accumulator.rows.count) rows, \(accumulator.gapIndices.count) gaps")
print("  geometry      (ScrollTranscript):  \(transcript.rows.count) rows, \(transcript.gapCount) gaps")

if options.emit {
    // Anything still held by the filter (no scrolling ever observed) belongs in the output too.
    let remaining = contentFilter.flush()
    if !remaining.isEmpty { accumulator.ingest(remaining) }

    let document = ClipDocument(
        context: ClipContext(
            appName: target.appName.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}")),
            windowTitle: target.title,
            url: WindowResolver.browserURL(for: target),
            regionDescription: "\(Int(region.width))x\(Int(region.height))"
        ),
        rows: accumulator.rows,
        gapIndices: accumulator.gapIndices,
        mode: .accessibility
    )
    print("\n=== rendered clip ===")
    print(document.render())
}
