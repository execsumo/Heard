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

    /// Rescan `directory` and publish the result, sorted newest-first.
    public func refresh(directory: URL) {
        records = Self.scan(directory: directory)
    }

    /// Enumerate top-level `.md` files in `directory` (skipping hidden files,
    /// subdirectories, and standalone `*_note.md` files), parse each via
    /// `parseRecord`, and return the records sorted newest-first
    /// (date descending, then filename descending for stability).
    /// A missing or unreadable directory returns `[]`.
    public static func scan(directory: URL) -> [TranscriptRecord] {
        // Stub — implemented by the transcript-library backend workstream.
        []
    }

    /// Parse one transcript's metadata from the first ~1 KB of its content
    /// (`header`) plus file attributes. Never throws on malformed content —
    /// falls back to a filename-derived title and `modificationDate`.
    /// Returns nil only for files that should not appear in the library
    /// (e.g. standalone `*_note.md` files).
    public static func parseRecord(
        url: URL,
        header: String,
        modificationDate: Date
    ) -> TranscriptRecord? {
        // Stub — implemented by the transcript-library backend workstream.
        nil
    }
}
