import AppKit
import ScreenCaptureKit
import OverscrollAX
import OverscrollCore
import Vision

/// Pixel-path fallback: capture the target window and read text off it with Vision.
///
/// Used only when the accessibility tree yields nothing — canvas-rendered surfaces (some Electron
/// apps, remote desktops, games, PDFs rendered as images) expose no element tree at all. Everything
/// this path recovers is display text, so link targets are already gone by the time we see it. That
/// is the cost of the fallback, and the reason it is not the default.
enum OCRHarvester {

    struct Capture {
        let rows: [CapturedRow]
        let image: CGImage?
    }

    /// Capture `region` (CoreGraphics screen space) from the given window and recognize its text.
    ///
    /// Filtering to the window rather than the display is what keeps our own overlay out of the
    /// shot — the overlay sits above the target, so a display capture would photograph the dimming
    /// layer and the selection chrome along with the content.
    static func capture(target: WindowTarget, region: CGRect, keepImage: Bool) async -> Capture {
        guard let image = await windowImage(target: target, region: region) else {
            return Capture(rows: [], image: nil)
        }
        let rows = recognize(image: image, regionOrigin: region.origin)
        return Capture(rows: rows, image: keepImage ? image : nil)
    }

    private static func windowImage(target: WindowTarget, region: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = content.windows.first(where: { $0.windowID == target.windowID })
            else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(target.bounds.width * 2)
            config.height = Int(target.bounds.height * 2)
            config.showsCursor = false

            let full = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            // The capture is window-relative and at 2x; the region is in screen space at 1x.
            let scaleX = CGFloat(full.width) / target.bounds.width
            let scaleY = CGFloat(full.height) / target.bounds.height
            let cropRect = CGRect(
                x: (region.minX - target.bounds.minX) * scaleX,
                y: (region.minY - target.bounds.minY) * scaleY,
                width: region.width * scaleX,
                height: region.height * scaleY
            ).intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))

            guard !cropRect.isNull, cropRect.width >= 1, cropRect.height >= 1 else { return full }
            return full.cropping(to: cropRect) ?? full
        } catch {
            return nil
        }
    }

    private static func recognize(image: CGImage, regionOrigin: CGPoint) -> [CapturedRow] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        let height = CGFloat(image.height)
        let rows: [(row: CapturedRow, y: CGFloat)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision reports a normalized, bottom-left-origin box; flip it so ordering matches the
            // accessibility path (ascending y = down the screen).
            let y = (1 - observation.boundingBox.maxY) * height
            let row = CapturedRow(
                text: candidate.string,
                role: "OCRLine",
                links: urls(in: candidate.string),
                y: Double(regionOrigin.y + y)
            )
            return (row, y)
        }

        return rows.sorted { $0.y < $1.y }.map(\.row)
    }

    /// Best-effort URL recovery from recognized text. Only finds links that were fully spelled out
    /// on screen — anything the app abbreviated or hyperlinked behind a label is unrecoverable here.
    private static func urls(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { $0.url?.absoluteString }
    }
}
