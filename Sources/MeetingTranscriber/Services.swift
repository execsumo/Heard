import AppKit
import AudioToolbox
import AVFAudio
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Data Types

struct MeetingSnapshot {
    var title: String
    var startedAt: Date
    var teamsPID: pid_t?
}

struct RecordingSession {
    let title: String
    let startTime: Date
    let appAudioPath: URL
    let micAudioPath: URL
    var micDelaySeconds: TimeInterval
}

// MARK: - Meeting Detection

@MainActor
final class MeetingDetector {
    private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private var activeSnapshot: MeetingSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var consecutiveDetections = 0
    private var cooldownUntil: Date?

    private static let teamsProcessNames: Set<String> = [
        "Microsoft Teams",
        "Microsoft Teams (work or school)",
        "Microsoft Teams classic",
    ]

    init(
        onMeetingStarted: @escaping @MainActor (MeetingSnapshot) -> Void,
        onMeetingEnded: @escaping @MainActor (MeetingSnapshot) -> Void
    ) {
        self.onMeetingStarted = onMeetingStarted
        self.onMeetingEnded = onMeetingEnded
    }

    func startWatching() {
        isWatching = true
        startPolling()
    }

    func stopWatching() {
        isWatching = false
        pollingTask?.cancel()
        pollingTask = nil
        consecutiveDetections = 0
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { break }
                self.poll()
            }
        }
    }

    private func poll() {
        if let cooldown = cooldownUntil, Date() < cooldown { return }
        cooldownUntil = nil

        let result = Self.detectTeamsMeeting()

        if result.detected {
            consecutiveDetections += 1
            if consecutiveDetections >= 2, activeSnapshot == nil {
                let title = Self.extractTeamsWindowTitle() ?? ""
                let snapshot = MeetingSnapshot(
                    title: title,
                    startedAt: Date(),
                    teamsPID: result.pid
                )
                activeSnapshot = snapshot
                onMeetingStarted(snapshot)
            }
        } else {
            consecutiveDetections = 0
            if let snapshot = activeSnapshot {
                activeSnapshot = nil
                cooldownUntil = Date().addingTimeInterval(5)
                onMeetingEnded(snapshot)
            }
        }
    }

    /// Poll IOPMCopyAssertionsByProcess for Teams holding a PreventUserIdleDisplaySleep assertion.
    private static func detectTeamsMeeting() -> (detected: Bool, pid: pid_t?) {
        let runningApps = NSWorkspace.shared.runningApplications
        let teamsApps = runningApps.filter { app in
            guard let name = app.localizedName else { return false }
            return teamsProcessNames.contains(name)
        }
        guard !teamsApps.isEmpty else { return (false, nil) }

        var assertionsByPid: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsByPid) == kIOReturnSuccess,
              let dict = assertionsByPid?.takeRetainedValue() as NSDictionary?
        else {
            return (false, nil)
        }

        for app in teamsApps {
            let pid = app.processIdentifier
            guard let assertions = dict[NSNumber(value: pid)] as? [[String: Any]] else { continue }
            for assertion in assertions {
                if let type = assertion["AssertionType"] as? String,
                   type == "PreventUserIdleDisplaySleep"
                {
                    return (true, pid)
                }
            }
        }
        return (false, nil)
    }

    /// Extract the meeting title from the Teams window via CGWindowListCopyWindowInfo.
    /// Requires Screen Recording permission; returns nil if unavailable.
    private static func extractTeamsWindowTitle() -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  teamsProcessNames.contains(ownerName),
                  let title = window[kCGWindowName as String] as? String,
                  title.contains(" | Microsoft Teams")
            else { continue }
            let cleaned = title.replacingOccurrences(of: #"\s*\|\s*Microsoft Teams.*$"#, with: "", options: .regularExpression)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    // MARK: - Simulation (development only)

    func simulateMeetingStart(title: String) {
        let snapshot = MeetingSnapshot(title: title, startedAt: Date(), teamsPID: nil)
        activeSnapshot = snapshot
        onMeetingStarted(snapshot)
    }

    func simulateMeetingEnd() {
        guard let snapshot = activeSnapshot else { return }
        activeSnapshot = nil
        onMeetingEnded(snapshot)
    }
}

// MARK: - Audio Recording

@MainActor
final class RecordingManager: ObservableObject {
    @Published private(set) var activeSession: RecordingSession?

    private var micEngine: AVAudioEngine?
    private var appEngine: AVAudioEngine?
    private var micAudioFile: AVAudioFile?
    private var appAudioFile: AVAudioFile?
    private var tapObjectID: AudioObjectID = 0
    private var maxDurationTask: Task<Void, Never>?
    private var micStartTime: Date?
    private var appStartTime: Date?

    /// AsyncStream publisher for mic buffers — v2 dictation will subscribe to this.
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var micBufferStream: AsyncStream<AVAudioPCMBuffer>?

    func startRecording(title: String, teamsPID: pid_t?) throws {
        guard activeSession == nil else { return }

        let stamp = Formatting.recordingFileFormatter.string(from: Date())
        let base = FileManager.default.meetingTranscriberAppSupportDirectory
            .appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let appPath = base.appendingPathComponent("\(stamp)_app.wav")
        let micPath = base.appendingPathComponent("\(stamp)_mic.wav")

        // Set up mic recording first
        try setupMicRecording(to: micPath)

        // Set up app audio recording if we have a Teams PID
        if let pid = teamsPID {
            do {
                try setupAppAudioRecording(pid: pid, to: appPath)
            } catch {
                // App audio is best-effort — continue with mic-only if tap fails
                NSLog("MeetingTranscriber: App audio tap failed: \(error.localizedDescription)")
            }
        }

        let micDelay: TimeInterval
        if let mic = micStartTime, let app = appStartTime {
            micDelay = mic.timeIntervalSince(app)
        } else {
            micDelay = 0
        }

        activeSession = RecordingSession(
            title: title,
            startTime: Date(),
            appAudioPath: appPath,
            micAudioPath: micPath,
            micDelaySeconds: micDelay
        )

        // 4-hour max recording duration
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4 * 3600))
            guard let self, !Task.isCancelled else { return }
            self.handleMaxDurationReached()
        }
    }

    func stopRecording() -> RecordingSession? {
        maxDurationTask?.cancel()
        maxDurationTask = nil

        teardownMicRecording()
        teardownAppAudioRecording()

        micBufferContinuation?.finish()
        micBufferContinuation = nil
        micBufferStream = nil
        micStartTime = nil
        appStartTime = nil

        defer { activeSession = nil }
        return activeSession
    }

    // MARK: - Mic Recording (AVAudioEngine)

    private func setupMicRecording(to url: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Create the output file at the hardware format (will be resampled to 16kHz in pipeline)
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: hwFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        micAudioFile = file

        // Set up AsyncStream for v2 dictation
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        micBufferStream = stream
        micBufferContinuation = continuation

        // Mono conversion format matching the file
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: monoFormat) {
            [weak self] buffer, _ in
            try? file.write(from: buffer)
            self?.micBufferContinuation?.yield(buffer)
        }

        engine.prepare()
        try engine.start()
        micEngine = engine
        micStartTime = Date()
    }

    private func teardownMicRecording() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micAudioFile = nil
    }

    // MARK: - App Audio Recording (CATapDescription + Process Tap)

    private func setupAppAudioRecording(pid: pid_t, to url: URL) throws {
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(pid)])
        tapDesc.name = "MeetingTranscriber"

        var objectID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(tapDesc, &objectID)
        guard status == noErr else {
            throw RecordingError.processTapFailed(status)
        }
        tapObjectID = objectID

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Point the engine's input to the process tap device
        var deviceID = objectID
        let audioUnit = inputNode.audioUnit!
        let setErr = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard setErr == noErr else {
            AudioHardwareDestroyProcessTap(objectID)
            tapObjectID = 0
            throw RecordingError.deviceSetupFailed(setErr)
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: hwFormat.sampleRate,
            AVNumberOfChannelsKey: hwFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        appAudioFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            try? file.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        appEngine = engine
        appStartTime = Date()
    }

    private func teardownAppAudioRecording() {
        appEngine?.inputNode.removeTap(onBus: 0)
        appEngine?.stop()
        appEngine = nil
        appAudioFile = nil

        if tapObjectID != 0 {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = 0
        }
    }

    private func handleMaxDurationReached() {
        // TODO: enqueue current session and restart recording if meeting still active
        _ = stopRecording()
    }
}

enum RecordingError: LocalizedError {
    case processTapFailed(OSStatus)
    case deviceSetupFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .processTapFailed(let code):
            return "Failed to create process audio tap (error \(code))"
        case .deviceSetupFailed(let code):
            return "Failed to configure tap audio device (error \(code))"
        }
    }
}

// MARK: - Model Catalog

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

// MARK: - Permission Center

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var statuses: [PermissionStatus] = []

    init() {
        refresh()
    }

    func refresh() {
        statuses = [
            PermissionStatus(
                id: "microphone",
                title: "Microphone",
                purpose: "Record your voice during meetings.",
                state: microphoneState()
            ),
            PermissionStatus(
                id: "screen",
                title: "Screen Recording",
                purpose: "Read Teams window title for meeting names.",
                state: screenRecordingState()
            ),
            PermissionStatus(
                id: "accessibility",
                title: "Accessibility",
                purpose: "Read Teams roster for automatic speaker naming.",
                state: accessibilityState()
            ),
        ]
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .recommended
        default: return .unknown
        }
    }

    private func screenRecordingState() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .recommended
    }

    private func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .recommended
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Temp File Cleanup

enum TempFileCleanup {
    /// Delete recording WAVs older than 48 hours. Called on app launch.
    static func cleanStaleRecordings(activeJobPaths: Set<URL> = []) {
        let recordingsDir = FileManager.default.meetingTranscriberAppSupportDirectory
            .appendingPathComponent("recordings", isDirectory: true)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-48 * 3600)

        for fileURL in contents where fileURL.pathExtension == "wav" {
            // Don't delete files referenced by active pipeline jobs
            if activeJobPaths.contains(fileURL) { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }

            try? fm.removeItem(at: fileURL)
        }
    }
}

// MARK: - Launch at Login

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MeetingTranscriber: Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Transcript Writer

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

// MARK: - Pipeline Processor

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
                onNamingRequired(unmatched.map {
                    NamingCandidate(id: UUID(), temporaryName: $0, suggestedName: nil)
                })
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
        // TODO: Replace with real pipeline stage execution
        try await Task.sleep(for: .milliseconds(250))
    }

    private func buildTranscript(for job: PipelineJob) -> TranscriptDocument {
        // TODO: Replace with real transcription + diarization output
        let me = settingsStore.settings.userName.isEmpty ? "Me" : settingsStore.settings.userName
        let remote = speakerStore.speakers.first?.name ?? "Speaker 1"
        let segments = [
            TranscriptSegment(speaker: me, startTime: 0, endTime: 4, text: "Started the discussion and set context for the meeting."),
            TranscriptSegment(speaker: remote, startTime: 5, endTime: 10, text: "Shared updates and open questions from the remote track."),
            TranscriptSegment(speaker: me, startTime: 12, endTime: 18, text: "Summarized next steps and assigned follow-up actions."),
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
