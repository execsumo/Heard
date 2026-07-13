import Combine
import Foundation

// MARK: - TranscriptRecord
//
// One archive record per completed meeting. This is the Library's backing
// store, decoupled from the ephemeral `PipelineQueueStore` (a *processing*
// queue whose jobs are dismissed via `remove()`). A record is written when a
// pipeline job reaches `.complete`, and it must survive both the queue's
// removal of that job and an app restart.
//
// Phase 1 (this file): metadata only — enough to list, search, open externally,
// rename, delete, and reconcile against the folder. In-app rendering is
// deferred (the Library "Open" action launches the `.md` in the default app).
// Phase 2 adds `participantSpeakerIDs` to power the People cross-link.

public struct TranscriptRecord: Codable, Identifiable, Equatable {
    /// Matches the originating `PipelineJob.id` for traceability and idempotent
    /// upserts (a retry/rewrite updates the existing record, never duplicates).
    public let id: UUID
    public var title: String
    public let start: Date
    public let end: Date
    /// Stored rather than recomputed from `start`/`end` at read time.
    public var duration: TimeInterval
    public var transcriptPath: URL
    /// Participant names captured during the meeting (for display chips). The
    /// speaker-ID join that powers "this person's meetings" is Phase 2.
    public var rosterNames: [String]
    public var notesCount: Int
    public var hasUnnamedSpeakers: Bool
    /// Set by `TranscriptStore.reconcile` when the `.md` no longer exists on
    /// disk (user moved/renamed/deleted it outside the app). Such a record
    /// renders disabled with a "File missing" badge; reconciliation never
    /// deletes records on its own.
    public var fileMissing: Bool

    public init(
        id: UUID,
        title: String,
        start: Date,
        end: Date,
        duration: TimeInterval,
        transcriptPath: URL,
        rosterNames: [String] = [],
        notesCount: Int = 0,
        hasUnnamedSpeakers: Bool = false,
        fileMissing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.duration = duration
        self.transcriptPath = transcriptPath
        self.rosterNames = rosterNames
        self.notesCount = notesCount
        self.hasUnnamedSpeakers = hasUnnamedSpeakers
        self.fileMissing = fileMissing
    }

    /// Build a record from a completed pipeline job. Returns `nil` if the job
    /// has no transcript path (i.e. it never reached `.complete`), so the call
    /// site can simply skip non-completed jobs. This is the intended Phase 1
    /// write path — call it when a job finishes and `upsert` the result.
    public init?(completedJob job: PipelineJob, hasUnnamedSpeakers: Bool) {
        guard let path = job.transcriptPath else { return nil }
        self.init(
            id: job.id,
            title: job.meetingTitle,
            start: job.startTime,
            end: job.endTime,
            duration: job.endTime.timeIntervalSince(job.startTime),
            transcriptPath: path,
            rosterNames: job.rosterNames,
            notesCount: job.notes.count,
            hasUnnamedSpeakers: hasUnnamedSpeakers,
            fileMissing: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, duration, transcriptPath
        case rosterNames, notesCount, hasUnnamedSpeakers, fileMissing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        transcriptPath = try c.decode(URL.self, forKey: .transcriptPath)
        // Additive fields decode defensively so records written by an older or
        // newer schema (e.g. once Phase 2 lands) still load.
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
            ?? end.timeIntervalSince(start)
        rosterNames = try c.decodeIfPresent([String].self, forKey: .rosterNames) ?? []
        notesCount = try c.decodeIfPresent(Int.self, forKey: .notesCount) ?? 0
        hasUnnamedSpeakers = try c.decodeIfPresent(Bool.self, forKey: .hasUnnamedSpeakers) ?? false
        fileMissing = try c.decodeIfPresent(Bool.self, forKey: .fileMissing) ?? false
    }
}

// MARK: - List logic (pure)
//
// Filtering/sorting kept independent of the store and any view so it can be
// unit-tested directly.

public enum TranscriptLibrary {
    /// Newest-first, optionally filtered by a case-insensitive query over the
    /// meeting title and participant names. An empty/whitespace query returns
    /// everything (still newest-first).
    public static func meetings(from records: [TranscriptRecord], search: String = "") -> [TranscriptRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [TranscriptRecord]
        if query.isEmpty {
            filtered = records
        } else {
            filtered = records.filter { record in
                record.title.lowercased().contains(query)
                    || record.rosterNames.contains { $0.lowercased().contains(query) }
            }
        }
        return filtered.sorted { $0.start > $1.start }
    }
}

// MARK: - TranscriptStore

@MainActor
public final class TranscriptStore: ObservableObject {
    @Published public private(set) var records: [TranscriptRecord]

    private let store = JSONStore()
    private let url: URL

    public init(url: URL = AppPaths.transcriptsFile) {
        self.url = url
        records = store.load([TranscriptRecord].self, from: url, defaultValue: [])
    }

    /// Insert a new record or update the existing one with the same `id`.
    /// Idempotent: re-running a finished job's write path overwrites in place
    /// rather than duplicating.
    public func upsert(_ record: TranscriptRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist()
    }

    public func rename(id: UUID, to title: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].title = title
        persist()
    }

    /// Drop the index record. Does **not** delete the `.md` file — the caller
    /// owns that decision (the Library's "Delete" removes both; "Remove from
    /// Library" on a missing-file row removes only the record).
    public func remove(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    /// Reconcile the index against the filesystem, flipping `fileMissing` for
    /// records whose transcript file has appeared/disappeared. Never deletes a
    /// record. `fileExists` is injectable so the logic is testable without
    /// touching disk. Returns the ids whose missing-state actually changed.
    @discardableResult
    public func reconcile(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [UUID] {
        var changed: [UUID] = []
        for index in records.indices {
            let missing = !fileExists(records[index].transcriptPath)
            if records[index].fileMissing != missing {
                records[index].fileMissing = missing
                changed.append(records[index].id)
            }
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    private func persist() {
        try? store.save(records, to: url)
    }
}
