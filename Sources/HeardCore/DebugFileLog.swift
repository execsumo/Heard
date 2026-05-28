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
    private static var heartbeatTimer: Timer?

    public static var fileURL: URL {
        FileManager.default.heardAppSupportDirectory.appendingPathComponent("dict-debug.log")
    }

    /// Installs a Timer on the main RunLoop that logs every second. Gaps in
    /// these heartbeat lines correspond directly to main-thread stalls — if
    /// you see "heartbeat tick=12" followed by "heartbeat tick=13" 8 seconds
    /// later, main was unresponsive for those 8 seconds.
    @MainActor
    public static func startMainThreadHeartbeat() {
        guard heartbeatTimer == nil else { return }
        var tick = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            tick += 1
            DebugFileLog.log("heartbeat tick=\(tick)")
        }
        if let timer = heartbeatTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        log("heartbeat installed")
    }

    public static func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
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
