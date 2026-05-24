import Foundation

/// Append-only debug logger that writes to a known file path. Used when
/// NSLog/unified-log diagnostics aren't reaching `log stream` reliably and
/// we need a guaranteed observation channel for live debugging.
///
/// Tail it with:
///   tail -F ~/Library/Application\ Support/Heard/dict-debug.log
public enum DebugFileLog {
    private static let queue = DispatchQueue(label: "com.execsumo.heard.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static var fileURL: URL {
        FileManager.default.heardAppSupportDirectory.appendingPathComponent("dict-debug.log")
    }

    public static func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        // Mirror to NSLog too in case unified-log is working.
        NSLog("Heard: [DICT-DBG] \(message)")
        queue.async {
            let url = fileURL
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url)
            }
        }
    }
}
