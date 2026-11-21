import Foundation

/// A recording that has not been queued yet. Written at recording start and on metadata
/// changes, and removed only after the pipeline queue has durably accepted its job.
public struct ActiveRecordingEntry: Codable, Equatable {
    public let id: UUID
    public var title: String
    public let startTime: Date
    public var updatedAt: Date
    public let appAudioPath: URL
    public let micAudioPath: URL
    public var micDelaySeconds: TimeInterval
    public var rosterNames: [String]
    public var notes: [MeetingNote]
    public var chatMessages: [ChatMessage]

    public init(
        id: UUID, title: String, startTime: Date, updatedAt: Date,
        appAudioPath: URL, micAudioPath: URL, micDelaySeconds: TimeInterval,
        rosterNames: [String], notes: [MeetingNote], chatMessages: [ChatMessage]
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.updatedAt = updatedAt
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.micDelaySeconds = micDelaySeconds
        self.rosterNames = rosterNames
        self.notes = notes
        self.chatMessages = chatMessages
    }

    public init(session: RecordingSession, updatedAt: Date) {
        self.init(
            id: session.id, title: session.title, startTime: session.startTime, updatedAt: updatedAt,
            appAudioPath: session.appAudioPath, micAudioPath: session.micAudioPath,
            micDelaySeconds: session.micDelaySeconds, rosterNames: session.rosterNames,
            notes: session.notes, chatMessages: session.chatMessages
        )
    }
}

public extension PipelineJob {
    /// Keeps the session id, so a repeated handoff of one session is seen as a duplicate.
    init(finishing session: RecordingSession, endedAt: Date) {
        self.init(
            id: session.id, meetingTitle: session.title, startTime: session.startTime, endTime: endedAt,
            appAudioPath: session.appAudioPath, micAudioPath: session.micAudioPath, transcriptPath: nil,
            stage: .queued, stageStartTime: nil, error: nil, retryCount: 0,
            rosterNames: session.rosterNames, notes: session.notes, chatMessages: session.chatMessages,
            micDelaySeconds: session.micDelaySeconds
        )
    }

    /// End time comes from the audio on disk; journal updatedAt can be stale.
    init(recovering entry: ActiveRecordingEntry, endedAt: Date) {
        self.init(
            id: entry.id, meetingTitle: entry.title.isEmpty ? "Recovered recording" : entry.title,
            startTime: entry.startTime, endTime: endedAt,
            appAudioPath: entry.appAudioPath, micAudioPath: entry.micAudioPath, transcriptPath: nil,
            stage: .queued, stageStartTime: nil, error: nil, retryCount: 0,
            rosterNames: entry.rosterNames, notes: entry.notes, chatMessages: entry.chatMessages,
            micDelaySeconds: entry.micDelaySeconds
        )
    }
}

public enum RecoveryOutcome: Equatable {
    case recovered(UUID)
    case alreadyQueued(UUID)
    case noUsableAudio(UUID)
    case queueWriteFailed(UUID)
}

/// What the menu bar keeps warning about until the audio is queued. Separate from
/// `errorMessage`, which every successful start clears.
public struct RecoveryWarning: Equatable {
    /// The latest journal write for the active recording failed, so a crash would lose its metadata.
    public private(set) var activeRecordingUnjournaled = false
    /// Recordings whose audio is on disk but not yet accepted by the queue.
    public private(set) var unqueuedRecordings = 0
    /// The queue's latest save failed and no enqueue has succeeded since.
    public private(set) var queueSaveFailing = false
    /// The queue file was unreadable and moved aside; cleared only by a successful queue save.
    public private(set) var queueMovedAside = false

    public init() {}

    public mutating func recordActiveJournalWrite(succeeded: Bool) { activeRecordingUnjournaled = !succeeded }
    public mutating func activeRecordingEnded() { activeRecordingUnjournaled = false }
    public mutating func setUnqueuedRecordings(_ count: Int) { unqueuedRecordings = count }
    public mutating func recordQueueSave(succeeded: Bool) {
        queueSaveFailing = !succeeded
        if succeeded { queueMovedAside = false }
    }
    public mutating func recordQueueMovedAside() { queueMovedAside = true }

    /// One line per open problem; empty when nothing needs attention.
    public var messages: [String] {
        var lines: [String] = []
        if activeRecordingUnjournaled {
            lines.append("The active recording is not protected against a crash: its recovery entry could not be saved. Capture continues.")
        }
        if unqueuedRecordings > 0 {
            lines.append("\(unqueuedRecordings) recording(s) not yet queued. Their audio is kept and queued on the next launch.")
        }
        if queueSaveFailing {
            lines.append("The processing queue could not be saved. New recordings may not be transcribed until a save succeeds.")
        }
        if queueMovedAside {
            lines.append("The processing queue file was unreadable and moved aside. Older recordings may be queued again.")
        }
        return lines
    }
}

/// WAV files a crash left behind, grouped by the start stamp that names them.
public struct OrphanRecordingGroup: Equatable {
    public let startTime: Date
    /// Conventional path even when the track is absent, matching how startRecording names it.
    public let appAudioPath: URL
    public let micAudioPath: URL

    public var audioPaths: [URL] { [appAudioPath, micAudioPath] }
}

public enum OrphanRecordingScanner {
    /// Only names Heard generates count: `yyyyMMdd_HHmmss_app.wav` and `_mic.wav`.
    public static func groups(fileNames: [String], directory: URL) -> [OrphanRecordingGroup] {
        let stamps = Set(fileNames.compactMap { stamp(of: $0) })
        return stamps.sorted().compactMap { stamp in
            guard let startTime = Formatting.recordingFileFormatter.date(from: stamp) else { return nil }
            return OrphanRecordingGroup(
                startTime: startTime,
                appAudioPath: directory.appendingPathComponent("\(stamp)_app.wav"),
                micAudioPath: directory.appendingPathComponent("\(stamp)_mic.wav")
            )
        }
    }

    static func stamp(of fileName: String) -> String? {
        for suffix in ["_app.wav", "_mic.wav"] where fileName.hasSuffix(suffix) {
            let stamp = String(fileName.dropLast(suffix.count))
            let isStamp = stamp.utf8.count == 15 && stamp.utf8.enumerated().allSatisfy { index, byte in
                index == 8 ? byte == UInt8(ascii: "_") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            }
            return isStamp ? stamp : nil
        }
        return nil
    }
}

public struct OrphanScanResult: Equatable {
    /// Queued during this scan.
    public var adopted: [UUID] = []
    /// Could not be journaled. Their audio stays on disk and cleanup must keep it.
    public var unjournaled: [OrphanRecordingGroup] = []
}

/// One JSON file per recording that is not queued yet. Without it a meeting that was
/// never stopped (quit, crash) has no record on disk that the pipeline can find.
@MainActor
public final class ActiveRecordingStore {
    /// Same floor PipelineProcessor applies before it reads a track.
    private static let minimumUsableBytes = 1024
    private static let headerReadBytes = 65_536

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL = AppPaths.activeRecordingsDirectory) {
        self.directory = directory
        // Whole-second dates would move a recovered start time away from the audio's.
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    /// Audio that journaled recordings still depend on. Cleanup must keep it.
    public var retainedAudioPaths: Set<URL> {
        Set(pendingEntries().flatMap { [$0.appAudioPath, $0.micAudioPath] })
    }

    public func save(_ entry: ActiveRecordingEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(entry).write(to: fileURL(for: entry.id), options: .atomic)
    }

    public func remove(_ id: UUID) {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("Heard: could not remove active recording entry %@: %@", id.uuidString, error.localizedDescription)
        }
    }

    /// Queues the job, then drops the entry. The entry goes only after the queue holds the job.
    public func enqueue(_ job: PipelineJob, into queue: PipelineQueueStore) -> Bool {
        // A repeated handoff of one session must not queue its audio twice.
        if !queue.jobs.contains(where: { $0.id == job.id }), !queue.enqueue(job) { return false }
        remove(job.id)
        return true
    }

    /// Queues every journaled recording the queue does not hold yet, except `activeID`.
    public func recover(into queue: PipelineQueueStore, excluding activeID: UUID? = nil) -> [RecoveryOutcome] {
        pendingEntries()
            .filter { $0.id != activeID }
            .map { recoverOne($0, into: queue) }
    }

    /// Queues WAV pairs that no journal entry or queue job references. Never deletes a file.
    public func adoptOrphans(in recordingsDir: URL, referenced: Set<URL>, into queue: PipelineQueueStore) -> OrphanScanResult {
        var result = OrphanScanResult()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        for group in OrphanRecordingScanner.groups(fileNames: names, directory: recordingsDir) {
            guard group.audioPaths.allSatisfy({ !referenced.contains($0) }),
                  group.audioPaths.contains(where: Self.isUsable)
            else { continue }
            let entry = ActiveRecordingEntry(
                id: UUID(), title: "", startTime: group.startTime, updatedAt: group.startTime,
                appAudioPath: group.appAudioPath, micAudioPath: group.micAudioPath, micDelaySeconds: 0,
                rosterNames: [], notes: [], chatMessages: []
            )
            guard (try? save(entry)) != nil else {
                result.unjournaled.append(group)
                continue
            }
            if case .recovered(let id) = recoverOne(entry, into: queue) {
                result.adopted.append(id)
            }
        }
        return result
    }

    public func pendingEntries() -> [ActiveRecordingEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(load)
    }

    /// Latest end across the tracks; the mic track starts `micDelay` seconds after the app track.
    public static func recoveredEnd(
        start: Date, micDelay: TimeInterval, appSeconds: TimeInterval?, micSeconds: TimeInterval?
    ) -> Date? {
        let ends = [appSeconds, micSeconds.map { micDelay + $0 }].compactMap { $0 }
        return ends.max().map { start.addingTimeInterval($0) }
    }

    /// Audio length from the WAV header and file size; nil when no PCM header can be read.
    public static func audioSeconds(at url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: headerReadBytes) else { return nil }
        return WAVHeaderFinalizer.durationSeconds(header: header, fileSize: Int(size))
    }

    private func recoverOne(_ entry: ActiveRecordingEntry, into queue: PipelineQueueStore) -> RecoveryOutcome {
        if queue.jobs.contains(where: { $0.id == entry.id }) {
            remove(entry.id)
            return .alreadyQueued(entry.id)
        }
        let tracks = [entry.appAudioPath, entry.micAudioPath]
        guard tracks.contains(where: Self.isUsable) else {
            remove(entry.id)
            return .noUsableAudio(entry.id)
        }
        // The journal's updatedAt predates the last audio written, so the end comes from the files.
        let end = Self.recoveredEnd(
            start: entry.startTime, micDelay: entry.micDelaySeconds,
            appSeconds: Self.audioSeconds(at: entry.appAudioPath),
            micSeconds: Self.audioSeconds(at: entry.micAudioPath)
        ) ?? entry.updatedAt
        return enqueue(PipelineJob(recovering: entry, endedAt: end), into: queue)
            ? .recovered(entry.id)
            : .queueWriteFailed(entry.id)
    }

    private func load(_ url: URL) -> ActiveRecordingEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(ActiveRecordingEntry.self, from: data)
        } catch {
            JSONStore.quarantine(url, decodeError: error)
            return nil
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func isUsable(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.size] as? Int) ?? 0) > minimumUsableBytes
    }
}
