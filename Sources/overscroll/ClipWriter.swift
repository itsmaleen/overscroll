import AppKit
import OverscrollCore
import UniformTypeIdentifiers

/// Writes a clip to disk and puts it on the clipboard.
///
/// Both, deliberately. The markdown goes on the pasteboard for the ordinary paste, and the file
/// exists so a coding agent can be pointed at a path instead — a lazy-loaded attachment rather than
/// a context dump, which matters once a clip runs to a few thousand tokens.
enum ClipWriter {

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Overscroll", isDirectory: true)
    }

    @discardableResult
    static func write(markdown: String, image: CGImage?, context: ClipContext) -> URL? {
        let directory = self.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let stamp = filenameFormatter.string(from: context.capturedAt)
        let slug = slugify(context.windowTitle ?? context.appName)
        let base = "\(stamp)-\(slug)"

        let markdownURL = directory.appendingPathComponent("\(base).md")
        do {
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        if let image {
            let imageURL = directory.appendingPathComponent("\(base).png")
            writePNG(image, to: imageURL)
        }
        return markdownURL
    }

    static func copyToPasteboard(markdown: String, path: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        // The file URL rides along as a second representation, so dragging or pasting into
        // something file-aware yields the file rather than a wall of text.
        if let path {
            pasteboard.writeObjects([path as NSURL])
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static func slugify(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .lowercased()
        return slug.isEmpty ? "clip" : String(slug.prefix(48))
    }
}

/// User-facing messages. A menu-bar app has no window to put them in, and this stays in one place
/// so it can be swapped for UserNotifications later without touching call sites.
@MainActor
enum Notifier {
    static func info(_ message: String, subtitle: String? = nil) {
        StatusItemController.shared?.flash(message)
        log(message, subtitle: subtitle)
    }

    static func warn(_ message: String) {
        StatusItemController.shared?.flash(message)
        log("WARN: \(message)", subtitle: nil)
    }

    private static func log(_ message: String, subtitle: String?) {
        if let subtitle {
            FileHandle.standardError.write("overscroll: \(message) — \(subtitle)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("overscroll: \(message)\n".data(using: .utf8)!)
        }
    }
}
