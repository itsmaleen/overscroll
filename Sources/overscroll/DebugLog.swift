import Foundation

/// Append-only trace of a capture, written to `~/Documents/Overscroll/debug.log`.
///
/// A menu-bar app has no console anyone reads, and the finished clip only shows the end state — it
/// cannot distinguish "the scroll never moved" from "the harvest never ran" from "the filter held
/// everything back", which are three different bugs with the same symptom. This records the
/// sequence so the answer comes from evidence rather than from re-reading the code and guessing.
enum DebugLog {
    private static let queue = DispatchQueue(label: "overscroll.debuglog")
    private static var url: URL {
        ClipWriter.directory.appendingPathComponent("debug.log")
    }

    static func start(_ message: String) {
        write("\n===== \(stamp()) \(message) =====")
    }

    static func log(_ message: String) {
        write("[\(stamp())] \(message)")
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func write(_ line: String) {
        queue.async {
            let directory = ClipWriter.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
