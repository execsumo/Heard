import AppKit
import AudioToolbox
import AVFAudio
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import FluidAudio
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Data Types

public struct MeetingSnapshot {
    public var title: String
    public var startedAt: Date
    public var teamsPID: pid_t?

    public init(title: String, startedAt: Date, teamsPID: pid_t?) {
        self.title = title
        self.startedAt = startedAt
        self.teamsPID = teamsPID
    }
}

public struct RecordingSession {
    public let title: String
    public let startTime: Date
    public let appAudioPath: URL
    public let micAudioPath: URL
    public var micDelaySeconds: TimeInterval

    public init(title: String, startTime: Date, appAudioPath: URL, micAudioPath: URL, micDelaySeconds: TimeInterval) {
        self.title = title
        self.startTime = startTime
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.micDelaySeconds = micDelaySeconds
    }
}

// MARK: - Meeting Detection

@MainActor
public final class MeetingDetector {
    public private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private var activeSnapshot: MeetingSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var consecutiveDetections = 0
    private var cooldownUntil: Date?
    private var isSimulated = false

    private static let teamsProcessNames: Set<String> = [
        "Microsoft Teams",
        "Microsoft Teams (work or school)",
        "Microsoft Teams classic",
    ]

    public init(
        onMeetingStarted: @escaping @MainActor (MeetingSnapshot) -> Void,
        onMeetingEnded: @escaping @MainActor (MeetingSnapshot) -> Void
    ) {
        self.onMeetingStarted = onMeetingStarted
        self.onMeetingEnded = onMeetingEnded
    }

    public func startWatching() {
        isWatching = true
        startPolling()
    }

    public func stopWatching() {
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
        // Don't interfere with simulated meetings
        if isSimulated { return }
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

    public func simulateMeetingStart(title: String) {
        isSimulated = true
        let snapshot = MeetingSnapshot(title: title, startedAt: Date(), teamsPID: nil)
        activeSnapshot = snapshot
        onMeetingStarted(snapshot)
    }

    public func simulateMeetingEnd() {
        guard let snapshot = activeSnapshot else { return }
        isSimulated = false
        activeSnapshot = nil
        onMeetingEnded(snapshot)
    }
}

// MARK: - Audio Recording

@MainActor
public final class RecordingManager: ObservableObject {
    @Published public private(set) var activeSession: RecordingSession?

    public init() {}

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

    /// Callback for max-duration split: enqueue current session, optionally restart.
    public var onMaxDurationReached: (@MainActor (RecordingSession) -> Void)?

    /// The Teams PID and title for the current recording (needed for re-start on split).
    private var currentTeamsPID: pid_t?
    private var currentTitle: String = ""

    public func startRecording(title: String, teamsPID: pid_t?) throws {
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

        currentTeamsPID = teamsPID
        currentTitle = title

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

    public func stopRecording() -> RecordingSession? {
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
        guard let session = stopRecording() else { return }

        // Enqueue the finished session
        onMaxDurationReached?(session)

        // Restart recording if we had a Teams PID (meeting still active)
        let pid = currentTeamsPID
        let title = currentTitle
        if pid != nil {
            do {
                try startRecording(title: title + " (cont.)", teamsPID: pid)
            } catch {
                NSLog("MeetingTranscriber: Failed to restart recording after max duration: \(error)")
            }
        }
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
public final class ModelCatalog: ObservableObject {
    @Published public private(set) var statuses: [ModelStatusItem] = ModelKind.allCases.map {
        let detail = $0 == .streamingPlaceholder ? "Reserved for v2 dictation" : "Download required"
        return ModelStatusItem(modelKind: $0, availability: .notDownloaded, detail: detail)
    }

    public init() {}

    public func markDownloading(_ kind: ModelKind) {
        update(kind, availability: .downloading, detail: "Downloading")
    }

    public func markReady(_ kind: ModelKind) {
        update(kind, availability: .ready, detail: "Ready")
    }

    private func update(_ kind: ModelKind, availability: ModelAvailability, detail: String) {
        guard let index = statuses.firstIndex(where: { $0.modelKind == kind }) else { return }
        statuses[index] = ModelStatusItem(modelKind: kind, availability: availability, detail: detail)
    }
}

// MARK: - Permission Center

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var statuses: [PermissionStatus] = []

    public init() {
        refresh()
    }

    public func refresh() {
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

    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public func openAccessibilitySettings() {
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

public enum TempFileCleanup {
    /// Delete recording WAVs older than 48 hours. Called on app launch.
    public static func cleanStaleRecordings(activeJobPaths: Set<URL> = []) {
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

public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
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

public enum TranscriptWriter {
    public static func write(document: TranscriptDocument, outputDirectory: URL) throws -> URL {
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

/// Processes recorded meetings through: preprocessing → transcription → diarization → speaker assignment → output.
/// Jobs are processed sequentially (one at a time) to avoid ANE contention.
/// Failed stages retry up to 3 times with exponential backoff (5s, 30s, 5min).
@MainActor
public final class PipelineProcessor: ObservableObject {
    @Published public private(set) var isProcessing = false

    private let queueStore: PipelineQueueStore
    private let speakerStore: SpeakerStore
    private let settingsStore: SettingsStore
    private let modelCatalog: ModelCatalog
    private let onNamingRequired: @MainActor ([NamingCandidate]) -> Void

    /// In-memory state for the current pipeline job.
    private var appTrack: PreprocessedTrack?
    private var micTrack: PreprocessedTrack?
    private var appTranscription: ASRResult?
    private var micTranscription: ASRResult?
    private var appDiarization: DiarizationResult?
    private var micDiarization: DiarizationResult?

    private static let retryDelays: [TimeInterval] = [5, 30, 300]
    private static let maxRetries = 3

    public init(
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

    public func enqueueFinishedRecording(_ session: RecordingSession, endedAt: Date) {
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

    public func retryFailedJob(_ job: PipelineJob) {
        var retry = job
        retry.stage = .queued
        retry.error = nil
        queueStore.update(retry)
        runNextIfNeeded()
    }

    public func runNextIfNeeded() {
        guard !isProcessing else { return }
        guard let next = queueStore.jobs.first(where: { $0.stage == .queued }) else { return }
        isProcessing = true
        Task {
            await processWithRetry(next)
            await MainActor.run {
                self.isProcessing = false
                self.clearJobState()
                self.runNextIfNeeded()
            }
        }
    }

    private func clearJobState() {
        appTrack = nil
        micTrack = nil
        appTranscription = nil
        micTranscription = nil
        appDiarization = nil
        micDiarization = nil
    }

    // MARK: - Retry Logic

    private func processWithRetry(_ job: PipelineJob) async {
        var working = job
        for attempt in 0..<Self.maxRetries {
            do {
                try await process(&working)
                return
            } catch is CancellationError {
                return
            } catch {
                working.error = error.localizedDescription
                working.retryCount = attempt + 1
                queueStore.update(working)

                if attempt < Self.maxRetries - 1 {
                    let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                    NSLog("MeetingTranscriber: Stage \(working.stage.rawValue) failed (attempt \(attempt + 1)), retrying in \(Int(delay))s: \(error)")
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    NSLog("MeetingTranscriber: Exhausted retries for job \(working.id): \(error)")
                    working.stage = .failed
                    queueStore.update(working)
                }
            }
        }
    }

    // MARK: - Pipeline Stages

    private func process(_ job: inout PipelineJob) async throws {

        // Stage 1: Preprocessing — load WAV, resample to 16kHz mono, Silero VAD trim
        if job.stage == .queued || job.stage == .preprocessing {
            try await advanceTo(&job, stage: .preprocessing)
            modelCatalog.markDownloading(.batchVad)
            try await runPreprocessing(job)
            modelCatalog.markReady(.batchVad)
        }

        // Stage 2: Transcription — Parakeet TDT on both tracks
        if job.stage == .preprocessing || job.stage == .transcribing {
            try await advanceTo(&job, stage: .transcribing)
            modelCatalog.markDownloading(.batchParakeet)
            try await runTranscription(job)
            modelCatalog.markReady(.batchParakeet)
        }

        // Stage 3: Diarization — LS-EEND + WeSpeaker on both tracks
        if job.stage == .transcribing || job.stage == .diarizing {
            try await advanceTo(&job, stage: .diarizing)
            modelCatalog.markDownloading(.diarization)
            try await runDiarization(job)
            modelCatalog.markReady(.diarization)
        }

        // Stage 4: Speaker Assignment + Output
        if job.stage == .diarizing || job.stage == .assigning {
            try await advanceTo(&job, stage: .assigning)
            let transcript = runSpeakerAssignment(job)
            let outputDirectory = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
            let outputURL = try TranscriptWriter.write(document: transcript, outputDirectory: outputDirectory)

            job.transcriptPath = outputURL
            job.stage = .complete
            job.stageStartTime = nil
            job.error = nil
            queueStore.update(job)

            let unmatched = transcript.participants.filter { $0.hasPrefix("Speaker ") }
            if !unmatched.isEmpty {
                onNamingRequired(unmatched.map {
                    NamingCandidate(id: UUID(), temporaryName: $0, suggestedName: nil)
                })
            }
        }
    }

    private func advanceTo(_ job: inout PipelineJob, stage: PipelineStage) async throws {
        job.stage = stage
        job.stageStartTime = Date()
        job.error = nil
        queueStore.update(job)
    }

    // MARK: - Stage 1: Preprocessing (AudioConverter + Silero VAD)

    private func runPreprocessing(_ job: PipelineJob) async throws {
        let fm = FileManager.default
        let appExists = fm.fileExists(atPath: job.appAudioPath.path)
        let micExists = fm.fileExists(atPath: job.micAudioPath.path)

        guard appExists || micExists else { throw PipelineError.noAudioFiles }

        // Skip files that are too small to contain meaningful audio (< 1KB)
        let appUsable = appExists && (try? fm.attributesOfItem(atPath: job.appAudioPath.path)[.size] as? Int).flatMap({ $0 > 1024 }) ?? false
        let micUsable = micExists && (try? fm.attributesOfItem(atPath: job.micAudioPath.path)[.size] as? Int).flatMap({ $0 > 1024 }) ?? false

        guard appUsable || micUsable else { throw PipelineError.noAudioFiles }

        // Preprocess both tracks concurrently on background threads
        try await withThrowingTaskGroup(of: (String, PreprocessedTrack).self) { group in
            if appUsable {
                group.addTask {
                    let track = try await AudioPreprocessor.preprocess(wavURL: job.appAudioPath)
                    return ("app", track)
                }
            }
            if micUsable {
                group.addTask {
                    let track = try await AudioPreprocessor.preprocess(wavURL: job.micAudioPath)
                    return ("mic", track)
                }
            }
            for try await (label, track) in group {
                if label == "app" { appTrack = track }
                else { micTrack = track }
            }
        }
    }

    // MARK: - Stage 2: Transcription (Parakeet TDT V2)

    private func runTranscription(_ job: PipelineJob) async throws {
        // Load Parakeet model from FluidAudio's cache (auto-downloads on first use)
        let models = try await AsrModels.loadFromCache(version: .v2)
        let asrManager = AsrManager()
        try await asrManager.initialize(models: models)

        // Configure custom vocabulary if set
        let vocab = settingsStore.settings.customVocabulary
        if !vocab.isEmpty {
            // Custom vocabulary requires CTC models — skip if not available
            // Min 3 chars, max 50 terms (enforced in UI)
        }

        // Minimum 16,000 samples (1 second at 16kHz) required by Parakeet
        let minSamples = 16_000

        // Transcribe app track (remote participants)
        if let track = appTrack, track.samples.count >= minSamples {
            appTranscription = try await asrManager.transcribe(track.samples, source: .system)
        }

        // Transcribe mic track (local user)
        if let track = micTrack, track.samples.count >= minSamples {
            micTranscription = try await asrManager.transcribe(track.samples, source: .microphone)
        }

        // Models are released when asrManager goes out of scope
    }

    // MARK: - Stage 3: Diarization (LS-EEND + WeSpeaker)

    private func runDiarization(_ job: PipelineJob) async throws {
        // Diarization needs meaningful audio (at least a few seconds)
        let minSamples = 16_000 * 2 // 2 seconds at 16kHz

        let hasAppAudio = appTrack.map { $0.samples.count >= minSamples } ?? false
        let hasMicAudio = micTrack.map { $0.samples.count >= minSamples } ?? false

        guard hasAppAudio || hasMicAudio else {
            // Too short for diarization — skip, speaker assignment will use defaults
            return
        }

        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()

        // Diarize app track (may have multiple remote speakers)
        if hasAppAudio, let track = appTrack {
            appDiarization = try await diarizer.process(audio: track.samples)
        }

        // Diarize mic track (expect 1 speaker = local user)
        if hasMicAudio, let track = micTrack {
            micDiarization = try await diarizer.process(audio: track.samples)
        }

        // Models are released when diarizer goes out of scope
    }

    // MARK: - Stage 4: Speaker Assignment

    private func runSpeakerAssignment(_ job: PipelineJob) -> TranscriptDocument {
        let me = settingsStore.settings.userName.isEmpty ? "Me" : settingsStore.settings.userName

        // Build transcription segments from ASR results with timestamp remapping
        var allSegments: [TranscriptSegment] = []

        // App track segments (remote participants)
        if let asr = appTranscription, let track = appTrack, let timings = asr.tokenTimings {
            let segments = buildSegmentsFromTimings(timings, vadMap: track.vadMap, defaultSpeaker: "Remote")
            allSegments.append(contentsOf: segments)
        } else if let asr = appTranscription, let track = appTrack, !asr.text.isEmpty {
            allSegments.append(TranscriptSegment(
                speaker: "Remote",
                startTime: 0,
                endTime: track.duration,
                text: asr.text
            ))
        }

        // Mic track segments (local user)
        if let asr = micTranscription, let track = micTrack, let timings = asr.tokenTimings {
            let segments = buildSegmentsFromTimings(timings, vadMap: track.vadMap, defaultSpeaker: me)
            allSegments.append(contentsOf: segments)
        } else if let asr = micTranscription, let track = micTrack, !asr.text.isEmpty {
            allSegments.append(TranscriptSegment(
                speaker: me,
                startTime: 0,
                endTime: track.duration,
                text: asr.text
            ))
        }

        // Apply diarization speaker labels
        if let appDiar = appDiarization {
            let diarSegments = appDiar.segments.map { seg in
                DiarizationSegment(
                    speakerID: "R_\(seg.speakerId)",
                    startTime: appTrack?.vadMap.toOriginalTime(TimeInterval(seg.startTimeSeconds)) ?? TimeInterval(seg.startTimeSeconds),
                    endTime: appTrack?.vadMap.toOriginalTime(TimeInterval(seg.endTimeSeconds)) ?? TimeInterval(seg.endTimeSeconds)
                )
            }

            // Build speaker name map from embeddings
            let embeddings: [SpeakerEmbedding] = appDiar.segments.compactMap { seg in
                guard !seg.embedding.isEmpty else { return nil }
                return SpeakerEmbedding(speakerID: "R_\(seg.speakerId)", vector: seg.embedding)
            }
            // Deduplicate by speakerID
            var seenIDs = Set<String>()
            let uniqueEmbeddings = embeddings.filter { seenIDs.insert($0.speakerID).inserted }

            let matches = SpeakerMatcher.matchSpeakers(
                embeddings: uniqueEmbeddings,
                database: speakerStore.speakers,
                localUserName: me
            )

            var nameMap: [String: String] = [:]
            for match in matches {
                nameMap[match.detectedSpeakerID] = match.assignedName
            }

            // Apply diarization labels to app track segments
            for i in allSegments.indices where allSegments[i].speaker == "Remote" {
                if let best = SegmentMerger.findBestOverlapPublic(
                    start: allSegments[i].startTime,
                    end: allSegments[i].endTime,
                    diarizationSegments: diarSegments
                ), let name = nameMap[best] {
                    allSegments[i].speaker = name
                }
            }

            // Update speaker database
            SpeakerMatcher.updateDatabase(matches: matches, speakerStore: speakerStore)
        }

        // Sort by start time and merge consecutive same-speaker segments
        allSegments.sort { $0.startTime < $1.startTime }
        let merged = SegmentMerger.mergeConsecutive(allSegments)

        // Handle empty result
        let finalSegments = merged.isEmpty
            ? [TranscriptSegment(speaker: me, startTime: 0, endTime: 0, text: "[No speech detected]")]
            : merged

        return TranscriptDocument(
            title: job.meetingTitle.isEmpty ? "Meeting" : job.meetingTitle,
            startTime: job.startTime,
            endTime: job.endTime,
            participants: Array(Set(finalSegments.map(\.speaker))).sorted(),
            segments: finalSegments
        )
    }

    /// Convert token timings from ASR into TranscriptSegments, grouping tokens into sentences.
    private func buildSegmentsFromTimings(
        _ timings: [TokenTiming],
        vadMap: VadSegmentMap,
        defaultSpeaker: String
    ) -> [TranscriptSegment] {
        guard !timings.isEmpty else { return [] }

        // Group tokens into sentence-level segments (split on sentence-ending punctuation)
        var segments: [TranscriptSegment] = []
        var currentTokens: [TokenTiming] = []

        for token in timings {
            currentTokens.append(token)

            let text = token.token.trimmingCharacters(in: .whitespaces)
            let isSentenceEnd = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")

            if isSentenceEnd && currentTokens.count >= 3 {
                let sentenceText = currentTokens.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentenceText.isEmpty else { continue }

                let start = vadMap.toOriginalTime(currentTokens.first!.startTime)
                let end = vadMap.toOriginalTime(currentTokens.last!.endTime)

                segments.append(TranscriptSegment(
                    speaker: defaultSpeaker,
                    startTime: start,
                    endTime: end,
                    text: sentenceText
                ))
                currentTokens.removeAll()
            }
        }

        // Flush remaining tokens
        if !currentTokens.isEmpty {
            let sentenceText = currentTokens.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentenceText.isEmpty {
                let start = vadMap.toOriginalTime(currentTokens.first!.startTime)
                let end = vadMap.toOriginalTime(currentTokens.last!.endTime)
                segments.append(TranscriptSegment(
                    speaker: defaultSpeaker,
                    startTime: start,
                    endTime: end,
                    text: sentenceText
                ))
            }
        }

        return segments
    }
}

enum PipelineError: LocalizedError {
    case noAudioFiles

    var errorDescription: String? {
        switch self {
        case .noAudioFiles: return "No audio files found for this recording"
        }
    }
}
