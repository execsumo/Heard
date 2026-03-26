import Combine
import Foundation

struct MeetingSnapshot {
    var title: String
    var startedAt: Date
}

struct RecordingSession {
    let title: String
    let startTime: Date
    let appAudioPath: URL
    let micAudioPath: URL
}

@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var statuses: [ModelStatusItem] = ModelKind.allCases.map {
        let detail = $0 == .streamingPlaceholder ? "Reserved for v2 dictation" : "Download required"
        return ModelStatusItem(modelKind: $0, availability: .notDownloaded, detail: detail)
    }

    func markDownloading(_ kind: ModelKind) {
        update(kind, availability: .downloading, detail: "Downloading")
    }

    func markReady(_ kind: ModelKind) {
        update(kind, availability: .ready, detail: "Ready")
    }

    private func update(_ kind: ModelKind, availability: ModelAvailability, detail: String) {
        guard let index = statuses.firstIndex(where: { $0.modelKind == kind }) else { return }
        statuses[index] = ModelStatusItem(modelKind: kind, availability: availability, detail: detail)
    }
}

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var statuses: [PermissionStatus] = [
        PermissionStatus(id: "microphone", title: "Microphone", purpose: "Capture your local voice during meetings.", state: .recommended),
        PermissionStatus(id: "screen", title: "Screen Recording", purpose: "Best-effort Teams window title extraction.", state: .recommended),
        PermissionStatus(id: "accessibility", title: "Accessibility", purpose: "Roster inference and future dictation workflows.", state: .recommended)
    ]

    func markGranted(_ id: String) {
        guard let index = statuses.firstIndex(where: { $0.id == id }) else { return }
        statuses[index].state = .granted
    }
}

@MainActor
final class MeetingDetector {
    private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private var activeSnapshot: MeetingSnapshot?

    init(
        onMeetingStarted: @escaping @MainActor (MeetingSnapshot) -> Void,
        onMeetingEnded: @escaping @MainActor (MeetingSnapshot) -> Void
    ) {
        self.onMeetingStarted = onMeetingStarted
        self.onMeetingEnded = onMeetingEnded
    }

    func startWatching() { isWatching = true }
    func stopWatching() { isWatching = false }

    func simulateMeetingStart(title: String) {
        let snapshot = MeetingSnapshot(title: title, startedAt: Date())
        activeSnapshot = snapshot
        onMeetingStarted(snapshot)
    }

    func simulateMeetingEnd() {
        guard let snapshot = activeSnapshot else { return }
        activeSnapshot = nil
        onMeetingEnded(snapshot)
    }
}

@MainActor
final class RecordingManager: ObservableObject {
    @Published private(set) var activeSession: RecordingSession?

    func startRecording(title: String) throws {
        guard activeSession == nil else { return }
        let stamp = Formatting.recordingFileFormatter.string(from: Date())
        let base = FileManager.default.meetingTranscriberAppSupportDirectory.appendingPathComponent("recordings", isDirectory: true)
        activeSession = RecordingSession(
            title: title,
            startTime: Date(),
            appAudioPath: base.appendingPathComponent("\(stamp)_app.wav"),
            micAudioPath: base.appendingPathComponent("\(stamp)_mic.wav")
        )
    }

    func stopRecording() -> RecordingSession? {
        defer { activeSession = nil }
        return activeSession
    }
}

enum TranscriptWriter {
    static func write(document: TranscriptDocument, outputDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let prefix = Formatting.transcriptDatePrefixFormatter.string(from: document.startTime)
        let title = document.title.sanitizedFileName()
        var candidate = outputDirectory.appendingPathComponent("\(prefix)_\(title).md")
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(prefix)_\(title)_\(suffix).md")
            suffix += 1
        }

        let duration = document.endTime.timeIntervalSince(document.startTime)
        let header = """
        # \(document.title)

        **Date:** \(Formatting.transcriptDateFormatter.string(from: document.startTime)) – \(Formatting.transcriptDateFormatter.string(from: document.endTime).suffix(5))
        **Duration:** \(Int(duration) / 3600)h \((Int(duration) % 3600) / 60)m
        **Participants:** \(document.participants.joined(separator: ", "))

        ---

        """

        let body = document.segments.map { segment in
            "[\(segment.startTime.timestampString)] **\(segment.speaker):** \(segment.text)"
        }.joined(separator: "\n\n")

        try (header + body + "\n").write(to: candidate, atomically: true, encoding: .utf8)
        return candidate
    }
}

@MainActor
final class PipelineProcessor: ObservableObject {
    @Published private(set) var isProcessing = false

    private let queueStore: PipelineQueueStore
    private let speakerStore: SpeakerStore
    private let settingsStore: SettingsStore
    private let modelCatalog: ModelCatalog
    private let onNamingRequired: @MainActor ([NamingCandidate]) -> Void

    init(
        queueStore: PipelineQueueStore,
        speakerStore: SpeakerStore,
        settingsStore: SettingsStore,
        modelCatalog: ModelCatalog,
        onNamingRequired: @escaping @MainActor ([NamingCandidate]) -> Void
    ) {
        self.queueStore = queueStore
        self.speakerStore = speakerStore
        self.settingsStore = settingsStore
        self.modelCatalog = modelCatalog
        self.onNamingRequired = onNamingRequired
    }

    func enqueueFinishedRecording(_ session: RecordingSession, endedAt: Date) {
        let job = PipelineJob(
            id: UUID(),
            meetingTitle: session.title,
            startTime: session.startTime,
            endTime: endedAt,
            appAudioPath: session.appAudioPath,
            micAudioPath: session.micAudioPath,
            transcriptPath: nil,
            stage: .queued,
            stageStartTime: nil,
            error: nil,
            retryCount: 0
        )
        queueStore.enqueue(job)
        runNextIfNeeded()
    }

    func retryFailedJob(_ job: PipelineJob) {
        var retry = job
        retry.stage = .queued
        retry.error = nil
        queueStore.update(retry)
        runNextIfNeeded()
    }

    func runNextIfNeeded() {
        guard !isProcessing else { return }
        guard let next = queueStore.jobs.first(where: { $0.stage == .queued || $0.stage == .failed }) else { return }
        isProcessing = true
        Task {
            await process(next)
            await MainActor.run {
                self.isProcessing = false
                self.runNextIfNeeded()
            }
        }
    }

    private func process(_ job: PipelineJob) async {
        do {
            var working = job
            try await advance(&working, to: .preprocessing)
            modelCatalog.markDownloading(.batchVad)
            modelCatalog.markReady(.batchVad)

            try await advance(&working, to: .transcribing)
            modelCatalog.markDownloading(.batchParakeet)
            modelCatalog.markReady(.batchParakeet)

            try await advance(&working, to: .diarizing)
            modelCatalog.markDownloading(.diarization)
            modelCatalog.markReady(.diarization)

            try await advance(&working, to: .assigning)
            let transcript = buildTranscript(for: working)
            let outputDirectory = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
            let outputURL = try TranscriptWriter.write(document: transcript, outputDirectory: outputDirectory)
            working.transcriptPath = outputURL
            working.stage = .complete
            working.stageStartTime = nil
            queueStore.update(working)

            let unmatched = transcript.participants.filter { $0.hasPrefix("Speaker ") }
            if !unmatched.isEmpty {
                onNamingRequired(unmatched.map { NamingCandidate(id: UUID(), temporaryName: $0, suggestedName: nil) })
            }
        } catch {
            var failed = job
            failed.stage = .failed
            failed.error = error.localizedDescription
            failed.retryCount += 1
            queueStore.update(failed)
        }
    }

    private func advance(_ job: inout PipelineJob, to stage: PipelineStage) async throws {
        job.stage = stage
        job.stageStartTime = Date()
        job.error = nil
        queueStore.update(job)
        try await Task.sleep(for: .milliseconds(250))
    }

    private func buildTranscript(for job: PipelineJob) -> TranscriptDocument {
        let me = settingsStore.settings.userName.isEmpty ? "Me" : settingsStore.settings.userName
        let remote = speakerStore.speakers.first?.name ?? "Speaker 1"
        let segments = [
            TranscriptSegment(speaker: me, startTime: 0, endTime: 4, text: "Started the discussion and set context for the meeting."),
            TranscriptSegment(speaker: remote, startTime: 5, endTime: 10, text: "Shared updates and open questions from the remote track."),
            TranscriptSegment(speaker: me, startTime: 12, endTime: 18, text: "Summarized next steps and assigned follow-up actions.")
        ]

        return TranscriptDocument(
            title: job.meetingTitle.isEmpty ? "Meeting" : job.meetingTitle,
            startTime: job.startTime,
            endTime: job.endTime,
            participants: Array(Set(segments.map(\.speaker))).sorted(),
            segments: segments
        )
    }
}
