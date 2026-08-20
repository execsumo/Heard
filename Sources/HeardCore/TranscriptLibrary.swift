import Foundation

// MARK: - Transcript Library (contract)
//
// Frozen API contract for the transcript-library feature: the backend
// (scan/parse) and the Meetings settings tab are built against this surface
// in parallel. Do not change public signatures without coordinating both.

/// One prior meeting transcript on disk, parsed from the file header
/// (with filename/mtime fallback when the header is missing or malformed).
public struct TranscriptRecord: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    /// Header `**Date:**` start timestamp; file modification date when absent.
    public let date: Date
    /// Header `**Duration:**` in seconds; nil when absent or malformed.
    public let duration: TimeInterval?
    /// Header `**Participants:**` names; empty when absent.
    public let participants: [String]

    public init(
        url: URL,
        title: String,
        date: Date,
        duration: TimeInterval?,
        participants: [String]
    ) {
        self.url = url
        self.title = title
        self.date = date
        self.duration = duration
        self.participants = participants
    }
}

/// Scans the configured output directory for meeting transcripts.
/// Pure scan/parse core (static, unit-testable) plus a thin
/// `ObservableObject` wrapper the Meetings tab observes.
@MainActor
public final class TranscriptLibrary: ObservableObject {
    @Published public private(set) var records: [TranscriptRecord] = []

    public init() {}

    /// Returns the participant names that should be shown in the Meetings tab.
    /// The local speaker is always present in a recording, so keep both the
    /// configured name and the legacy `Me` label out of this summary.
    nonisolated static func participantsExcludingCurrentUser(
        _ participants: [String],
        userName: String
    ) -> [String] {
        let namesToHide = Set(["Me", userName].compactMap { name in
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        })

        return participants.filter { participant in
            let normalized = participant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !namesToHide.contains(normalized)
        }
    }

    /// Rescan `directory` and publish the result, sorted newest-first.
    public func refresh(directory: URL) {
        records = Self.scan(directory: directory)
    }

    public nonisolated static func scan(directory: URL) -> [TranscriptRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var records: [TranscriptRecord] = []
        for url in entries {
            let filename = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard ext == "md" else { continue }
            
            if filename.hasSuffix("_note.md") { continue }

            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mdate = attrs?.contentModificationDate ?? Date()

            var header = ""
            do {
                let fh = try FileHandle(forReadingFrom: url)
                if let data = try fh.read(upToCount: 1024) {
                    header = String(decoding: data, as: UTF8.self)
                }
                try fh.close()
            } catch {
                // Ignore, pass empty string to fallback
            }

            if let record = parseRecord(url: url, header: header, modificationDate: mdate) {
                records.append(record)
            }
        }

        records.sort {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        return records
    }

    /// Parse one transcript's metadata from the first ~1 KB of its content
    /// (`header`) plus file attributes. Never throws on malformed content —
    /// falls back to a filename-derived title and `modificationDate`.
    /// Returns nil only for files that should not appear in the library
    /// (e.g. standalone `*_note.md` files).
    public nonisolated static func parseRecord(
        url: URL,
        header: String,
        modificationDate: Date
    ) -> TranscriptRecord? {
        let filename = url.lastPathComponent
        guard filename.lowercased().hasSuffix(".md") else { return nil }
        
        let stem = (filename as NSString).deletingPathExtension
        if stem.hasSuffix("_note") { return nil }

        var fallbackTitle = stem
        if let range = fallbackTitle.range(of: "^\\d{4}-\\d{2}-\\d{2}_", options: .regularExpression) {
            fallbackTitle.removeSubrange(range)
        }
        if let range = fallbackTitle.range(of: "_\\d+$", options: .regularExpression) {
            fallbackTitle.removeSubrange(range)
        }

        var parsedTitle: String?
        var parsedDate: Date?
        var parsedDuration: TimeInterval?
        var parsedParticipants: [String]?

        let lines = header.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("# ") {
                if parsedTitle == nil {
                    parsedTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("**Date:**") {
                let content = line.dropFirst("**Date:**".count).trimmingCharacters(in: .whitespaces)
                if content.count >= 16 {
                    let startStr = String(content.prefix(16))
                    if let date = Formatting.transcriptDateFormatter.date(from: startStr) {
                        parsedDate = date
                    }
                }
            } else if line.hasPrefix("**Duration:**") {
                let content = line.dropFirst("**Duration:**".count).trimmingCharacters(in: .whitespaces)
                let hRegex = try? NSRegularExpression(pattern: "(\\d+)\\s*h")
                let mRegex = try? NSRegularExpression(pattern: "(\\d+)\\s*m")
                
                var h = 0
                if let m = hRegex?.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                    if let range = Range(m.range(at: 1), in: content), let val = Int(content[range]) {
                        h = val
                    }
                }
                var mPart = 0
                if let m = mRegex?.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                    if let range = Range(m.range(at: 1), in: content), let val = Int(content[range]) {
                        mPart = val
                    }
                }
                if h > 0 || mPart > 0 || content.contains("0h") || content.contains("0m") {
                    parsedDuration = TimeInterval(h * 3600 + mPart * 60)
                }
            } else if line.hasPrefix("**Participants:**") {
                let content = line.dropFirst("**Participants:**".count).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    parsedParticipants = content.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            }
        }

        return TranscriptRecord(
            url: url,
            title: parsedTitle ?? fallbackTitle,
            date: parsedDate ?? modificationDate,
            duration: parsedDuration,
            participants: parsedParticipants ?? []
        )
    }
}
