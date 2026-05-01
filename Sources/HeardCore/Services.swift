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
    public var rosterNames: [String]

    public init(title: String, startedAt: Date, teamsPID: pid_t?, rosterNames: [String] = []) {
        self.title = title
        self.startedAt = startedAt
        self.teamsPID = teamsPID
        self.rosterNames = rosterNames
    }
}

public struct RecordingSession {
    public let title: String
    public let startTime: Date
    public let appAudioPath: URL
    public let micAudioPath: URL
    public var micDelaySeconds: TimeInterval
    public var rosterNames: [String]

    public init(title: String, startTime: Date, appAudioPath: URL, micAudioPath: URL, micDelaySeconds: TimeInterval, rosterNames: [String] = []) {
        self.title = title
        self.startTime = startTime
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.micDelaySeconds = micDelaySeconds
        self.rosterNames = rosterNames
    }
}

// MARK: - Meeting Detection

/// Outcome of feeding a single poll result into the detection state machine.
public enum MeetingDetectionAction: Equatable {
    /// No state change worth acting on (waiting for debounce, in cooldown, etc.).
    case ignore
    /// Two consecutive detections observed — caller should build a snapshot and fire onMeetingStarted.
    case startMeeting
    /// Detection stopped while a meeting was active — caller should fire onMeetingEnded and stop recording.
    case endMeeting
}

/// Pure state machine for Teams meeting detection. Lives independently of IOKit so it can be
/// driven by tests with synthetic detection results and injected time.
///
/// Debounce: requires `detectionThreshold` consecutive positive polls before firing `.startMeeting`,
/// which guards against transient assertion blips (Teams briefly raises/releases its power assertion
/// during UI transitions).
///
/// Cooldown: after a `.endMeeting`, further polls within `cooldownSeconds` are ignored. This prevents
/// a recently-ended meeting from immediately re-triggering on the next poll if Teams is slow to
/// release its assertion.
public struct MeetingDetectionState: Equatable {
    public static let detectionThreshold = 2
    public static let cooldownSeconds: TimeInterval = 5

    public var consecutiveDetections: Int
    public var cooldownUntil: Date?
    public var hasActiveSnapshot: Bool

    public init(
        consecutiveDetections: Int = 0,
        cooldownUntil: Date? = nil,
        hasActiveSnapshot: Bool = false
    ) {
        self.consecutiveDetections = consecutiveDetections
        self.cooldownUntil = cooldownUntil
        self.hasActiveSnapshot = hasActiveSnapshot
    }

    /// Feed one poll result into the state machine and get the action to perform.
    public mutating func step(now: Date, detected: Bool) -> MeetingDetectionAction {
        if let cooldown = cooldownUntil, now < cooldown {
            return .ignore
        }
        cooldownUntil = nil

        if detected {
            consecutiveDetections += 1
            if consecutiveDetections >= Self.detectionThreshold, !hasActiveSnapshot {
                hasActiveSnapshot = true
                return .startMeeting
            }
            return .ignore
        } else {
            consecutiveDetections = 0
            if hasActiveSnapshot {
                hasActiveSnapshot = false
                cooldownUntil = now.addingTimeInterval(Self.cooldownSeconds)
                return .endMeeting
            }
            return .ignore
        }
    }
}

@MainActor
public final class MeetingDetector {
    public private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private var activeSnapshot: MeetingSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var rosterPollingTask: Task<Void, Never>?
    private var detectionState = MeetingDetectionState()
    private var isSimulated = false

    nonisolated private static let teamsProcessNames: Set<String> = [
        "Microsoft Teams",
        "Microsoft Teams (work or school)",
        "Microsoft Teams classic",
    ]

    /// Bundle IDs of the main Teams app (not helpers). Bundle-ID matching catches
    /// non-English macOS locales where `localizedName` is translated.
    nonisolated private static let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",   // classic
        "com.microsoft.teams2",  // new Teams
    ]

    /// True if the given app metadata identifies the main Microsoft Teams process.
    /// Matches by bundle ID first (locale-independent), then by localized name as a fallback
    /// for builds that ship under an unfamiliar bundle ID.
    nonisolated public static func isTeamsMainApp(bundleID: String?, localizedName: String?) -> Bool {
        if let bundleID, teamsBundleIDs.contains(bundleID) { return true }
        if let localizedName, teamsProcessNames.contains(localizedName) { return true }
        return false
    }

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
        detectionState = MeetingDetectionState()

        // End any active meeting so the recording stops and the transcript pipeline runs.
        // Without this, toggling watching off mid-meeting would orphan the recording —
        // the poll loop is cancelled, but activeSnapshot stays set and onMeetingEnded never fires.
        if let snapshot = activeSnapshot {
            stopRosterPolling()
            activeSnapshot = nil
            onMeetingEnded(snapshot)
        }
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

        let result = Self.detectTeamsMeeting()
        let action = detectionState.step(now: Date(), detected: result.detected)

        switch action {
        case .ignore:
            return
        case .startMeeting:
            let title = Self.extractTeamsWindowTitle(pid: result.pid) ?? ""
            let rosterNames = RosterReader.readRoster(teamsPID: result.pid)
            let snapshot = MeetingSnapshot(
                title: title,
                startedAt: Date(),
                teamsPID: result.pid,
                rosterNames: rosterNames
            )
            activeSnapshot = snapshot
            startRosterPolling()
            onMeetingStarted(snapshot)
        case .endMeeting:
            guard let snapshot = activeSnapshot else { return }
            stopRosterPolling()
            activeSnapshot = nil
            onMeetingEnded(snapshot)
        }
    }

    /// Poll IOPMCopyAssertionsByProcess for Teams holding a meeting-related power assertion.
    /// New Teams (com.microsoft.teams2) uses AssertionTrueType = PreventUserIdleDisplaySleep
    /// and/or AssertName = "Microsoft Teams Call in progress".
    private static func detectTeamsMeeting() -> (detected: Bool, pid: pid_t?) {
        let runningApps = NSWorkspace.shared.runningApplications
        let teamsApps = runningApps.filter { app in
            isTeamsMainApp(bundleID: app.bundleIdentifier, localizedName: app.localizedName)
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
                // Check multiple keys — Teams versions use different assertion formats:
                // - Classic Teams: AssertionType = "PreventUserIdleDisplaySleep"
                // - New Teams (com.microsoft.teams2): AssertionTrueType = "PreventUserIdleDisplaySleep"
                //   with AssertionType = "NoDisplaySleepAssertion"
                // - Also match by assertion name as a reliable fallback
                let assertionType = assertion["AssertionType"] as? String ?? ""
                let assertionTrueType = assertion["AssertionTrueType"] as? String ?? ""
                let assertName = assertion["AssertName"] as? String ?? ""

                let isDisplaySleep = assertionType == "PreventUserIdleDisplaySleep"
                    || assertionTrueType == "PreventUserIdleDisplaySleep"
                    || assertionType == "NoDisplaySleepAssertion"
                let isTeamsCall = assertName.lowercased().contains("call in progress")

                if isDisplaySleep || isTeamsCall {
                    return (true, pid)
                }
            }
        }
        return (false, nil)
    }

    /// Extract the meeting title from the Teams window via Accessibility API.
    /// Requires Accessibility permission; returns nil if unavailable.
    private static func extractTeamsWindowTitle(pid: pid_t?) -> String? {
        guard AXIsProcessTrusted(), let pid else { return nil }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }

        for window in windows {
            var titleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String,
                  title.contains(" | Microsoft Teams")
            else { continue }
            let cleaned = title.replacingOccurrences(of: #"\s*\|\s*Microsoft Teams.*$"#, with: "", options: .regularExpression)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    // MARK: - Roster Polling

    /// Poll the Teams roster every 15 seconds during an active meeting to accumulate participant names.
    private func startRosterPolling() {
        rosterPollingTask?.cancel()
        rosterPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, self.activeSnapshot != nil else { break }
                let names = RosterReader.readRoster(teamsPID: self.activeSnapshot?.teamsPID)
                if !names.isEmpty {
                    // Accumulate unique names across polls (participants may join/leave)
                    let existing = Set(self.activeSnapshot?.rosterNames ?? [])
                    let newNames = names.filter { !existing.contains($0) }
                    if !newNames.isEmpty {
                        self.activeSnapshot?.rosterNames.append(contentsOf: newNames)
                    }
                }
            }
        }
    }

    private func stopRosterPolling() {
        rosterPollingTask?.cancel()
        rosterPollingTask = nil
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
    /// True when the app-audio process tap failed — recording is mic-only.
    @Published public private(set) var appAudioTapFailed: Bool = false

    public init() {}

    // Context object shared between the main actor and the IOProc dispatch queue.
    // Stats fields are word-sized scalars updated from the IOProc and read from the
    // logging task; torn reads are acceptable for diagnostic output.
    private final class AppAudioInputContext: @unchecked Sendable {
        let file: AVAudioFile
        let format: AVAudioFormat
        var isStopped = false

        // Lifetime stats (monotonically increasing, written by IOProc)
        var renderCycles: Int = 0
        var renderErrorCount: Int = 0
        var lastRenderError: OSStatus = noErr
        var totalFrames: Int = 0
        var nonZeroFrames: Int = 0
        var peakAmplitude: Float = 0
        var sumSquares: Double = 0
        var firstAudioAt: CFTimeInterval = 0  // 0 = never

        init(file: AVAudioFile, format: AVAudioFormat) {
            self.file = file; self.format = format
        }
    }

    private var micEngine: AVAudioEngine?
    private var appIOProcID: AudioDeviceIOProcID?
    private var appIOProcQueue = DispatchQueue(label: "com.execsumo.heard.appaudio", qos: .userInteractive)
    private var appHALContext: AppAudioInputContext?
    private var micAudioFile: AVAudioFile?
    private var appAudioFile: AVAudioFile?
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var maxDurationTask: Task<Void, Never>?
    private var appAudioMonitorTask: Task<Void, Never>?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var micStartTime: Date?
    private var appStartTime: Date?

    /// AsyncStream publisher for mic buffers — v2 dictation will subscribe to this.
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var micBufferStream: AsyncStream<AVAudioPCMBuffer>?

    /// Callback for max-duration split: enqueue current session, optionally restart.
    public var onMaxDurationReached: (@MainActor (RecordingSession) -> Void)?
    /// Called once when the self-test confirms non-zero app audio is flowing.
    public var onAppAudioCaptureConfirmed: (() -> Void)?

    /// The Teams PID, title, and roster for the current recording (needed for re-start on split).
    private var currentTeamsPID: pid_t?
    private var currentTitle: String = ""
    private var currentRosterNames: [String] = []

    public func startRecording(title: String, teamsPID: pid_t?, rosterNames: [String] = []) throws {
        guard activeSession == nil else { return }

        let stamp = Formatting.recordingFileFormatter.string(from: Date())
        let base = FileManager.default.heardAppSupportDirectory
            .appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let appPath = base.appendingPathComponent("\(stamp)_app.wav")
        let micPath = base.appendingPathComponent("\(stamp)_mic.wav")

        // Set up mic recording first
        try setupMicRecording(to: micPath)

        // Set up app audio recording if we have a Teams PID
        appAudioTapFailed = false
        if let pid = teamsPID {
            do {
                try setupAppAudioRecording(pid: pid, to: appPath)
            } catch {
                // App audio is best-effort — continue with mic-only if tap fails
                appAudioTapFailed = true
                NSLog("Heard: App audio tap failed (recording mic-only): \(error.localizedDescription)")
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
        currentRosterNames = rosterNames

        activeSession = RecordingSession(
            title: title,
            startTime: Date(),
            appAudioPath: appPath,
            micAudioPath: micPath,
            micDelaySeconds: micDelay,
            rosterNames: rosterNames
        )

        // 4-hour max recording duration
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4 * 3600))
            guard let self, !Task.isCancelled else { return }
            self.handleMaxDurationReached()
        }
    }

    /// Update the roster names on the active session (called when meeting ends with final roster).
    public func updateRosterNames(_ names: [String]) {
        guard activeSession != nil, !names.isEmpty else { return }
        activeSession?.rosterNames = names
        currentRosterNames = names
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

        appAudioTapFailed = false
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

    // MARK: - App Audio Recording (CATapDescription + Process Tap + Raw AUHAL)

    private func setupAppAudioRecording(pid: pid_t, to url: URL, allowSelfTestRebuild: Bool = true) throws {
        // ── Step 1: Collect ALL Teams-related process object IDs ──────────────
        // Teams (Electron/Chromium) renders audio in renderer / GPU sub-processes,
        // not necessarily the main process that holds the power assertion. Tapping
        // only the reported PID misses audio from those child processes.
        let processObjectIDs = collectTeamsProcessObjectIDs(requiredPID: pid)
        guard !processObjectIDs.isEmpty else {
            NSLog("Heard: No CoreAudio process objects found for Teams (pid=%d). The Teams process(es) haven't opened audio yet — translate-PID returns 0 until they do.", pid)
            throw RecordingError.processTapFailed(kAudioHardwareBadObjectError)
        }
        NSLog("Heard: Creating process tap for %d Teams process(es)", processObjectIDs.count)
        if processObjectIDs.count == 1 {
            NSLog("Heard: WARNING — only ONE Teams audio process found. Teams 2.0 typically renders call audio in helper processes; if the captured WAV is silent, the wrong process is being tapped.")
        }

        // ── Step 2: Create the process tap ────────────────────────────────────
        // Screen Recording permission is required for AudioHardwareCreateProcessTap.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("Heard: Screen Recording permission not granted — process tap will likely fail")
        }
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDesc.uuid = UUID()
        tapDesc.name = "Heard Tap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
        guard tapErr == noErr else {
            NSLog("Heard: AudioHardwareCreateProcessTap failed (%d)", tapErr)
            throw RecordingError.processTapFailed(tapErr)
        }
        NSLog("Heard: Process tap created (id=%u)", tapObjectID)

        // ── Step 3: Tap UID ───────────────────────────────────────────────────
        // Use the UUID we set on the description directly — avoids a silent
        // failure if kAudioTapPropertyUID query returns an error (which previously
        // threw with no log, making it look like setupAppAudioRecording was never called).
        let tapUID = tapDesc.uuid.uuidString

        // ── Step 4: Locate default output device (provides the aggregate clock) ─
        var outputDeviceID: AudioObjectID = 0
        var outputDevSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var outputDevProp = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &outputDevProp, 0, nil, &outputDevSize, &outputDeviceID
        )
        var outputUIDRef: CFString = "" as CFString
        var outputUIDSize = UInt32(MemoryLayout<CFString>.size)
        var outputUIDProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafeMutablePointer(to: &outputUIDRef) { ptr in
            AudioObjectGetPropertyData(outputDeviceID, &outputUIDProp, 0, nil, &outputUIDSize, ptr)
        }
        let outputUID = outputUIDRef as String

        // Log device details for diagnostics (name + nominal sample rate).
        let outputName = copyDeviceStringProperty(outputDeviceID, selector: kAudioObjectPropertyName) ?? "?"
        var outputSampleRate: Float64 = 0
        var outputSRSize = UInt32(MemoryLayout<Float64>.size)
        var outputSRProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(outputDeviceID, &outputSRProp, 0, nil, &outputSRSize, &outputSampleRate)
        NSLog("Heard: Default output device: \"%@\" (id=%u, uid=%@, sr=%.0f)",
              outputName, outputDeviceID, outputUID, outputSampleRate)

        // ── Step 5: Create private aggregate device containing the tap ────────
        let aggregateUID = "\(AudioDeviceCleanup.heardAggregateUIDPrefix)\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Heard Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapDriftCompensationKey as String: true,
                 kAudioSubTapUIDKey as String: tapUID]
            ],
        ]
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            NSLog("Heard: AudioHardwareCreateAggregateDevice failed (%d)", aggErr)
            throw RecordingError.deviceSetupFailed(aggErr)
        }
        NSLog("Heard: Aggregate device created (id=%u)", aggregateDeviceID)

        // ── Step 6: Query aggregate device sample rate ────────────────────────
        var nominalRate: Float64 = 48000.0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(aggregateDeviceID, &rateProp, 0, nil, &rateSize, &nominalRate)
        let sampleRate = nominalRate > 0 ? nominalRate : 48000.0
        let channels: AVAudioChannelCount = 2

        // ── Step 7: Create WAV file ────────────────────────────────────────────
        // Use non-interleaved float32 — AVAudioFile.processingFormat is always
        // non-interleaved regardless of what the file format specifies.
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: fileSettings)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw error
        }
        appAudioFile = file
        // processingFormat is the format write(from:) actually expects.
        let format = file.processingFormat
        NSLog("Heard: IOProc format sr=%.0f ch=%u interleaved=%d",
              format.sampleRate, format.channelCount, format.isInterleaved ? 1 : 0)

        // ── Step 8: Create IOProc directly on the aggregate device ─────────────
        // AudioDeviceCreateIOProcIDWithBlock with a dispatch queue: CoreAudio copies
        // the audio buffers before dispatching, so inInputData is safe to read async.
        let ctx = AppAudioInputContext(file: file, format: format)
        appHALContext = ctx

        var ioProc: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(
            &ioProc, aggregateDeviceID, appIOProcQueue
        ) { [ctx, format] _, inInputData, _, _, _ in
            guard !ctx.isStopped else { return }
            ctx.renderCycles &+= 1

            let abl = inInputData.pointee
            // Tap delivers interleaved stereo float32 in a single buffer.
            guard abl.mNumberBuffers > 0,
                  let dataPtr = abl.mBuffers.mData else { return }
            let byteCount = Int(abl.mBuffers.mDataByteSize)
            guard byteCount > 0 else { return }

            let ch = Int(format.channelCount)
            let frameCount = byteCount / (ch * MemoryLayout<Float32>.size)
            guard frameCount > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frameCount)),
                  let channelData = buf.floatChannelData else { return }
            buf.frameLength = AVAudioFrameCount(frameCount)

            // Deinterleave: [L0,R0,L1,R1,...] → separate channel arrays.
            let src = dataPtr.bindMemory(to: Float32.self, capacity: frameCount * ch)
            for c in 0..<ch { channelData[c][0] = 0 } // ensure initialised
            var localPeak: Float = 0
            var localSumSq: Double = 0
            var localNonZero = 0
            for f in 0..<frameCount {
                for c in 0..<ch {
                    let s = src[f * ch + c]
                    channelData[c][f] = s
                    let a = abs(s)
                    if a > 0 { localNonZero &+= 1 }
                    if a > localPeak { localPeak = a }
                    localSumSq += Double(s) * Double(s)
                }
            }
            ctx.totalFrames &+= frameCount
            ctx.nonZeroFrames &+= localNonZero
            if localPeak > ctx.peakAmplitude { ctx.peakAmplitude = localPeak }
            ctx.sumSquares += localSumSq
            if localNonZero > 0 && ctx.firstAudioAt == 0 {
                ctx.firstAudioAt = CACurrentMediaTime()
            }

            try? ctx.file.write(from: buf)
        }
        guard ioErr == noErr, let validProc = ioProc else {
            NSLog("Heard: AudioDeviceCreateIOProcIDWithBlock failed (%d)", ioErr)
            appHALContext = nil
            appAudioFile = nil
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw RecordingError.deviceSetupFailed(ioErr)
        }

        let startErr = AudioDeviceStart(aggregateDeviceID, validProc)
        guard startErr == noErr else {
            NSLog("Heard: AudioDeviceStart failed (%d)", startErr)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, validProc)
            appHALContext = nil
            appAudioFile = nil
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw RecordingError.deviceSetupFailed(startErr)
        }

        appIOProcID = validProc
        appStartTime = Date()
        NSLog("Heard: App audio capture started (IOProc, aggregate=%u, sr=%.0f)", aggregateDeviceID, sampleRate)

        installDefaultOutputDeviceListener(initial: outputDeviceID)
        startAppAudioMonitor(context: ctx, pid: pid, appPath: url, allowRebuild: allowSelfTestRebuild)
    }

    /// Find CoreAudio process object IDs for all running Microsoft Teams processes.
    /// Teams (Electron/Chromium) can render audio from the main process OR helper
    /// processes (Teams Helper, Teams Helper (GPU), etc.). We tap all of them so that
    /// audio from any subprocess is captured regardless of which one is active.
    private func collectTeamsProcessObjectIDs(requiredPID: pid_t) -> [AudioObjectID] {
        let teamsApps = NSWorkspace.shared.runningApplications.filter { app in
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            let name   = app.localizedName?.lowercased() ?? ""
            return bundle.hasPrefix("com.microsoft.teams") ||
                   (name.hasPrefix("microsoft teams") && !bundle.isEmpty)
        }

        var pids = teamsApps.map(\.processIdentifier)
        if !pids.contains(requiredPID) { pids.insert(requiredPID, at: 0) }

        var seen = Set<pid_t>()
        var result: [AudioObjectID] = []
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for pid in pids where seen.insert(pid).inserted {
            var p = pid
            var objID: AudioObjectID = 0
            var sz = UInt32(MemoryLayout<AudioObjectID>.size)
            let err = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &prop, UInt32(MemoryLayout<pid_t>.size), &p, &sz, &objID
            )
            if err == noErr && objID != 0 {
                result.append(objID)
                NSLog("Heard: Tapping Teams process pid=%d objectID=%u (%@)",
                      pid, objID, teamsApps.first(where: { $0.processIdentifier == pid })?.localizedName ?? "?")
            }
        }
        return result
    }

    private func teardownAppAudioRecording() {
        appAudioMonitorTask?.cancel()
        appAudioMonitorTask = nil
        removeDefaultOutputDeviceListener()

        let finalContext = appHALContext
        teardownAppAudioChainOnly()
        if let ctx = finalContext {
            logAppAudioStats(prefix: "App audio capture stopped", context: ctx)
        }
    }

    /// Tear down only the audio chain (AUHAL + aggregate + tap + file), leaving the monitor
    /// task and device listener alive. Used by the self-test rebuild path so the monitor that
    /// triggered the rebuild can drive the new setup without cancelling itself mid-call.
    private func teardownAppAudioChainOnly() {
        appHALContext?.isStopped = true
        if let procID = appIOProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            appIOProcID = nil
        }
        appHALContext = nil
        appAudioFile = nil

        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapObjectID != 0 {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = 0
        }
    }

    // MARK: - App Audio Diagnostics

    /// Self-test at T+2s, optional one-shot rebuild on silence, then periodic stats logging.
    /// Cancellation: teardownAppAudioRecording cancels this task. The task also exits early after
    /// triggering a rebuild — the rebuild creates a fresh context + monitor that supersedes this one.
    private func startAppAudioMonitor(context ctx: AppAudioInputContext, pid: pid_t, appPath: URL, allowRebuild: Bool) {
        appAudioMonitorTask?.cancel()
        let started = CACurrentMediaTime()
        appAudioMonitorTask = Task { [weak self] in
            // ── T+2s self-test ─────────────────────────────────────────────────
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }

            let elapsed = CACurrentMediaTime() - started
            if ctx.nonZeroFrames > 0 {
                NSLog("Heard: Self-test PASSED at +%.1fs (%d non-zero of %d frames, peak=%.4f)",
                      elapsed, ctx.nonZeroFrames, ctx.totalFrames, ctx.peakAmplitude)
                self?.onAppAudioCaptureConfirmed?()
            } else {
                let reason = ctx.renderCycles == 0
                    ? "no render callbacks fired"
                    : "callbacks firing (cycles=\(ctx.renderCycles), frames=\(ctx.totalFrames)) but all-zero samples"
                if allowRebuild {
                    NSLog("Heard: Self-test FAILED at +%.1fs — %@. Rebuilding tap with fresh helper enumeration (one attempt).",
                          elapsed, reason)
                    self?.attemptAppAudioRebuild(pid: pid, appPath: appPath)
                    return
                } else {
                    NSLog("Heard: Self-test FAILED again at +%.1fs after rebuild — %@. Flagging recording as mic-only.",
                          elapsed, reason)
                    self?.appAudioTapFailed = true
                }
            }

            // ── Periodic stats / silence warnings ──────────────────────────────
            var tick = 0
            var warnedSilent = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                tick += 1
                let now = CACurrentMediaTime() - started

                if ctx.renderCycles == 0 {
                    NSLog("Heard: App audio — NO render callbacks fired after %.1fs (tap/aggregate not producing input)", now)
                } else if !warnedSilent && ctx.nonZeroFrames == 0 {
                    warnedSilent = true
                    NSLog("Heard: App audio — callbacks firing but still all-zero after %.1fs. Likely causes: no audio playing through Teams, wrong process tapped, or muted output.",
                          now)
                }

                if tick % 2 == 0 {
                    self?.logAppAudioStats(prefix: "App audio", context: ctx)
                }
            }
        }
    }

    /// Tear down the tap/aggregate/AUHAL and rebuild with fresh process enumeration.
    /// Called once from the self-test on silence. Helper processes that opened audio
    /// after the initial setup will now translate to non-zero process object IDs.
    private func attemptAppAudioRebuild(pid: pid_t, appPath: URL) {
        teardownAppAudioChainOnly()
        do {
            try setupAppAudioRecording(pid: pid, to: appPath, allowSelfTestRebuild: false)
            NSLog("Heard: App-audio chain rebuilt successfully — self-test will re-run at +2s")
        } catch {
            NSLog("Heard: App-audio rebuild failed: %@", error.localizedDescription)
            appAudioTapFailed = true
        }
    }

    private func logAppAudioStats(prefix: String, context ctx: AppAudioInputContext) {
        let total = ctx.totalFrames
        let nonZero = ctx.nonZeroFrames
        let cycles = ctx.renderCycles
        let peak = ctx.peakAmplitude
        let errs = ctx.renderErrorCount
        let lastErr = ctx.lastRenderError
        let firstAudio = ctx.firstAudioAt
        let rms = total > 0 ? sqrt(ctx.sumSquares / Double(total)) : 0
        let nonZeroPct = total > 0 ? Double(nonZero) * 100.0 / Double(total) : 0
        let peakDb = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        let rmsDb  = rms  > 0 ? 20 * log10(rms) : -.infinity
        NSLog("Heard: %@ — cycles=%d frames=%d nonZero=%.1f%% peak=%.4f (%.1fdB) rms=%.4f (%.1fdB) errs=%d lastErr=%d firstAudio=%@",
              prefix, cycles, total, nonZeroPct, peak, peakDb, rms, rmsDb, errs, lastErr,
              firstAudio == 0 ? "never" : "yes")
    }

    private func installDefaultOutputDeviceListener(initial: AudioObjectID) {
        guard defaultOutputListenerBlock == nil else { return }
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            var newID: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var p = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &p, 0, nil, &size, &newID
            )
            let name = RecordingManager.copyDeviceStringProperty(newID, selector: kAudioObjectPropertyName) ?? "?"
            NSLog("Heard: Default output device CHANGED to \"%@\" (id=%u). Aggregate is still bound to the original device — capture may stop if the original device disappeared.",
                  name, newID)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &prop, nil, block
        )
        if status == noErr {
            defaultOutputListenerBlock = block
        } else {
            NSLog("Heard: Failed to install default-output listener (%d)", status)
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &prop, nil, block
        )
        if status != noErr {
            NSLog("Heard: Failed to remove default-output listener (%d)", status)
        }
        defaultOutputListenerBlock = nil
    }

    nonisolated static func copyDeviceStringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var prop = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, ptr)
        }
        return err == noErr ? (ref as String) : nil
    }

    private func copyDeviceStringProperty(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        return Self.copyDeviceStringProperty(deviceID, selector: selector)
    }

    private func handleMaxDurationReached() {
        guard let session = stopRecording() else { return }

        // Enqueue the finished session
        onMaxDurationReached?(session)

        // Restart recording if we had a Teams PID (meeting still active)
        let pid = currentTeamsPID
        let title = currentTitle
        let roster = currentRosterNames
        if pid != nil {
            do {
                try startRecording(title: title + " (cont.)", teamsPID: pid, rosterNames: roster)
            } catch {
                NSLog("Heard: Failed to restart recording after max duration: \(error)")
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
        ModelStatusItem(modelKind: $0, availability: .notDownloaded, detail: "Download required")
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

    private var refreshTask: Task<Void, Never>?

    public init() {
        refresh()
        // Periodically re-check permissions (catches grants made in System Settings)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
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
                id: "audioCapture",
                title: "System Audio",
                purpose: "Capture Teams audio to record other participants. The permission dialog appears when you join your first meeting.",
                state: audioCaptureState()
            ),
            PermissionStatus(
                id: "screenCapture",
                title: "Screen Recording",
                purpose: "Tap Teams audio to record the other participants' voices. Required for dual-track recording.",
                state: screenCaptureState()
            ),
            PermissionStatus(
                id: "accessibility",
                title: "Accessibility",
                purpose: "Read Teams window titles and roster for meeting names and speaker naming. Required for dictation text injection.",
                state: accessibilityState()
            ),
        ]
    }

    public var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func markAudioCaptureGranted() {
        UserDefaults.standard.set(true, forKey: "audioCaptureTCCGranted")
        refresh()
    }

    public func openAudioCaptureSettings() {
        // No direct API to request kTCCServiceAudioCapture — the dialog appears
        // automatically when AudioHardwareCreateProcessTap is first called (i.e. on
        // meeting join). Open the Microphone privacy page as the closest system UI.
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public func openScreenCaptureSettings() {
        // CGRequestScreenCaptureAccess() triggers the system prompt on macOS 14;
        // on macOS 15+ it redirects to System Settings. Use it unconditionally.
        CGRequestScreenCaptureAccess()
        // Re-check after a brief delay — the grant applies asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func audioCaptureState() -> PermissionState {
        UserDefaults.standard.bool(forKey: "audioCaptureTCCGranted") ? .granted : .recommended
    }

    private func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .recommended
        default: return .unknown
        }
    }

    private func screenCaptureState() -> PermissionState {
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
        let recordingsDir = FileManager.default.heardAppSupportDirectory
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

// MARK: - Audio Device Cleanup

public enum AudioDeviceCleanup {
    /// UID prefix used by every aggregate device Heard creates for its process tap.
    /// Must match the value used in `RecordingManager.setupAppAudioRecording`.
    static let heardAggregateUIDPrefix = "com.execsumo.heard.tap."

    /// Destroy any orphaned private aggregate devices left over from a previous
    /// Heard session that crashed mid-recording. macOS normally reclaims these
    /// when the creating process exits cleanly, but `kill -9` / segfaults can
    /// leak them into the CoreAudio device tree. Called on app launch.
    public static func cleanOrphanAggregateDevices() {
        var propSize: UInt32 = 0
        var devicesProp = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &devicesProp, 0, nil, &propSize
        )
        guard sizeStatus == noErr, propSize > 0 else { return }

        let deviceCount = Int(propSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        let readStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &devicesProp, 0, nil, &propSize, &deviceIDs
        )
        guard readStatus == noErr else { return }

        var destroyed = 0
        for deviceID in deviceIDs {
            guard let uid = deviceUID(deviceID),
                  uid.hasPrefix(heardAggregateUIDPrefix) else { continue }
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            if status == noErr {
                destroyed += 1
                NSLog("Heard: Destroyed orphan aggregate device id=%u uid=%@", deviceID, uid)
            } else {
                NSLog("Heard: Failed to destroy orphan aggregate device id=%u (%d)", deviceID, status)
            }
        }
        if destroyed > 0 {
            NSLog("Heard: Orphan aggregate cleanup destroyed %d device(s)", destroyed)
        }
    }

    private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var uidRef: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidProp = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidProp, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return uidRef as String
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
            NSLog("Heard: Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Window Activation Coordinator

/// Reference-counts windows that need `NSApplication.ActivationPolicy.regular`
/// so the policy flips to `.regular` while any of them are visible and reverts
/// to `.accessory` once the last one closes.
///
/// Menu bar apps run as `.accessory` so they don't show a Dock icon, but
/// windows rendered under that policy can't receive keyboard focus. Each
/// focus-needing scene (Settings, Name Speakers) calls `begin(_:)` in its
/// `onAppear` and `end(_:)` in its `onDisappear`, keyed by a stable owner
/// identifier. The coordinator guarantees that closing one of several open
/// windows never yanks focus from the remaining ones.
@MainActor
public enum WindowActivationCoordinator {
    private static var owners: Set<String> = []

    /// Register that `owner` needs `.regular` activation policy. The first
    /// registration promotes the app to `.regular` and activates it.
    public static func begin(_ owner: String) {
        let wasEmpty = owners.isEmpty
        owners.insert(owner)
        if wasEmpty {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Unregister `owner`. When the last owner leaves, the app reverts to
    /// `.accessory` (menu-bar only, no Dock icon).
    public static func end(_ owner: String) {
        owners.remove(owner)
        if owners.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Transcript Writer

public enum TranscriptWriter {
    /// Replace a temporary speaker label (e.g. "Speaker 1") with a real name in an
    /// existing transcript markdown file. Updates speaker tags in body lines and the
    /// `**Participants:**` header line.
    public static func renameSpeaker(in transcriptURL: URL, from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, oldName != trimmed else { return }
        guard let data = try? Data(contentsOf: transcriptURL),
              let original = String(data: data, encoding: .utf8) else { return }

        var lines = original.components(separatedBy: "\n")
        for index in lines.indices {
            // Body line: "[hh:mm] **OldName:** ..." → "[hh:mm] **NewName:** ..."
            let bodyMarker = "**\(oldName):**"
            if lines[index].contains(bodyMarker) {
                lines[index] = lines[index].replacingOccurrences(of: bodyMarker, with: "**\(trimmed):**")
            }
            // Participants header line
            if lines[index].hasPrefix("**Participants:**") {
                let prefix = "**Participants:**"
                let rest = String(lines[index].dropFirst(prefix.count))
                let names = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let renamed = names.map { $0 == oldName ? trimmed : $0 }
                // Deduplicate while preserving order
                var seen = Set<String>()
                let unique = renamed.filter { seen.insert($0).inserted && !$0.isEmpty }
                lines[index] = "\(prefix) \(unique.joined(separator: ", "))"
            }
        }

        let updated = lines.joined(separator: "\n")
        try? updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

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
    private let onPipelineIdle: @MainActor () -> Void

    /// In-memory state for the current pipeline job.
    private var appTrack: PreprocessedTrack?
    private var micTrack: PreprocessedTrack?
    private var appTranscription: ASRResult?
    private var micTranscription: ASRResult?
    private var appDiarization: DiarizationResult?

    /// Cached models for keep-alive between jobs.
    private var cachedAsrModels: AsrModels?
    private var cachedAsrManager: AsrManager?
    private var cachedAsrVersion: TranscriptionModel?
    private var modelUnloadTask: Task<Void, Never>?

    private static let retryDelays: [TimeInterval] = [5, 30, 300]
    private static let maxRetries = 3
    /// Cumulative retry cap across sessions. Once `job.retryCount` reaches this
    /// value, the job stays `.failed` until the user explicitly retries it
    /// (which resets `retryCount` to 0). Prevents a permanently-broken job
    /// (corrupt WAV, missing file) from burning retries on every app launch.
    /// With `maxRetries = 3` per session, this allows two full session
    /// exhaustions before giving up for good.
    public static let lifetimeRetryLimit = 6

    public init(
        queueStore: PipelineQueueStore,
        speakerStore: SpeakerStore,
        settingsStore: SettingsStore,
        modelCatalog: ModelCatalog,
        onNamingRequired: @escaping @MainActor ([NamingCandidate]) -> Void,
        onPipelineIdle: @escaping @MainActor () -> Void = {}
    ) {
        self.queueStore = queueStore
        self.speakerStore = speakerStore
        self.settingsStore = settingsStore
        self.modelCatalog = modelCatalog
        self.onNamingRequired = onNamingRequired
        self.onPipelineIdle = onPipelineIdle
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
            retryCount: 0,
            rosterNames: session.rosterNames
        )
        queueStore.enqueue(job)
        runNextIfNeeded()
    }

    public func retryFailedJob(_ job: PipelineJob) {
        var retry = job
        retry.stage = .queued
        retry.error = nil
        // User-initiated retry gets a fresh budget. Without this, a job that
        // already hit the lifetime cap would be filtered out by
        // `PipelineQueueStore.prepareForResume` / `executeWithRetry` and
        // never run again.
        retry.retryCount = 0
        queueStore.update(retry)
        runNextIfNeeded()
    }

    public func runNextIfNeeded() {
        guard !isProcessing else { return }
        guard let next = queueStore.jobs.first(where: { $0.stage == .queued }) else {
            onPipelineIdle()
            return
        }
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

        // Default keepAlive is 0: unload immediately. Back-to-back meetings don't
        // cause rapid reloads because meeting 2 records while meeting 1's pipeline
        // runs — the gap before reload is always at least meeting 2's remaining duration.
        let keepAlive = settingsStore.settings.pipelineKeepAlive
        if keepAlive > 0 {
            scheduleModelUnload(after: keepAlive)
        } else {
            unloadPipelineModels()
        }
    }

    private func scheduleModelUnload(after seconds: TimeInterval) {
        modelUnloadTask?.cancel()
        modelUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.unloadPipelineModels()
        }
    }

    /// Unload cached pipeline models from memory.
    public func unloadPipelineModels() {
        modelUnloadTask?.cancel()
        modelUnloadTask = nil
        cachedAsrModels = nil
        cachedAsrManager = nil
        cachedAsrVersion = nil
        NSLog("Heard: Pipeline models unloaded")
    }

    // MARK: - Retry Logic

    private func processWithRetry(_ job: PipelineJob) async {
        var working = job
        await Self.executeWithRetry(
            job: &working,
            maxRetries: Self.maxRetries,
            lifetimeRetryLimit: Self.lifetimeRetryLimit,
            retryDelays: Self.retryDelays,
            isNonRetryable: { ($0 as? PipelineError)?.isNonRetryable ?? false },
            onUpdate: { [weak self] updated in self?.queueStore.update(updated) },
            sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) },
            process: { [weak self] job in
                guard let self else { throw CancellationError() }
                try await self.process(&job)
            }
        )
    }

    /// Pure-ish retry driver. Public for testing — invoked by `processWithRetry`
    /// with real dependencies. Semantics:
    /// - Success: returns with the job's final state from `process`.
    /// - CancellationError: returns silently, no further updates.
    /// - Non-retryable error: sets `.failed`, persists once, returns.
    /// - Retryable error: increments `retryCount` cumulatively, records `error`, persists, sleeps, retries.
    /// - Exhausted per-session retries: sets `.failed`, persists.
    /// - Lifetime cap reached (`retryCount >= lifetimeRetryLimit`): sets `.failed`
    ///   immediately without attempting. `retryCount` is cumulative across sessions
    ///   so a permanently-broken job eventually stops re-running on every app launch.
    public static func executeWithRetry(
        job: inout PipelineJob,
        maxRetries: Int,
        lifetimeRetryLimit: Int,
        retryDelays: [TimeInterval],
        isNonRetryable: (Error) -> Bool,
        onUpdate: (PipelineJob) -> Void,
        sleep: (TimeInterval) async throws -> Void,
        process: (inout PipelineJob) async throws -> Void
    ) async {
        if job.retryCount >= lifetimeRetryLimit {
            job.stage = .failed
            onUpdate(job)
            return
        }
        for attempt in 0..<maxRetries {
            do {
                try await process(&job)
                return
            } catch is CancellationError {
                return
            } catch {
                job.error = error.localizedDescription
                job.retryCount += 1

                if isNonRetryable(error) {
                    job.stage = .failed
                    onUpdate(job)
                    return
                }

                if job.retryCount >= lifetimeRetryLimit {
                    job.stage = .failed
                    onUpdate(job)
                    return
                }

                onUpdate(job)

                if attempt < maxRetries - 1 {
                    let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                    try? await sleep(delay)
                } else {
                    job.stage = .failed
                    onUpdate(job)
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

            if !transcript.unmatchedSpeakers.isEmpty {
                // Extract audio clips for each unmatched speaker
                let recordingsDir = FileManager.default.heardAppSupportDirectory
                    .appendingPathComponent("recordings", isDirectory: true)
                let clips = AudioClipExtractor.extractSpeakerClips(
                    unmatchedSpeakers: transcript.unmatchedSpeakers,
                    diarizationSegments: transcript.diarizationSegments,
                    sourceAudioURL: job.appAudioPath,
                    outputDirectory: recordingsDir
                )

                // Build candidates with audio clips, embeddings, and suggested roster names
                let rosterSuggestions = transcript.unmatchedRosterNames
                let candidates = clips.enumerated().map { (index, clip) in
                    NamingCandidate(
                        id: UUID(),
                        temporaryName: clip.temporaryName,
                        suggestedName: index < rosterSuggestions.count ? rosterSuggestions[index] : nil,
                        audioClipURLs: clip.clipURLs,
                        embedding: clip.embedding,
                        transcriptPath: outputURL
                    )
                }
                onNamingRequired(candidates)
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

    // MARK: - Stage 2: Transcription

    private func runTranscription(_ job: PipelineJob) async throws {
        // Cancel any pending unload — we're using the models now
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        let selectedVersion = settingsStore.settings.transcriptionModel

        // Reuse cached models if available and the same version; otherwise load fresh
        let asrManager: AsrManager
        if let cached = cachedAsrManager, cachedAsrVersion == selectedVersion {
            // Reset decoder state so stale context from the previous job doesn't bleed in
            try await cached.resetDecoderState()
            asrManager = cached
        } else {
            // Version changed or no cache — discard old models and load the selected version
            cachedAsrModels = nil
            cachedAsrManager = nil
            cachedAsrVersion = nil

            let fluidVersion: AsrModelVersion = selectedVersion == .v2 ? .v2 : .v3
            let models = try await AsrModels.loadFromCache(version: fluidVersion)
            let asrConfig = ASRConfig(
                tdtConfig: TdtConfig(blankId: selectedVersion.blankId),
                encoderHiddenSize: fluidVersion.encoderHiddenSize
            )
            let manager = AsrManager(config: asrConfig)
            try await manager.loadModels(models)
            asrManager = manager
            cachedAsrModels = models
            cachedAsrManager = manager
            cachedAsrVersion = selectedVersion
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

        // Models stay cached for keep-alive; unloaded by clearJobState() or forceUnload()
    }

    // MARK: - Stage 3: Diarization (LS-EEND + WeSpeaker)

    private func runDiarization(_ job: PipelineJob) async throws {
        // Diarization only applies to the app track (remote speakers).
        // The mic track is a single known speaker (the local user) so diarization adds no value.
        let minSamples = 16_000 * 2 // 2 seconds at 16kHz

        guard let track = appTrack, track.samples.count >= minSamples else {
            // Too short or missing — skip, speaker assignment will use defaults
            return
        }

        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()
        appDiarization = try await diarizer.process(audio: track.samples)

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
        var unmatchedSpeakerInfo: [(speakerID: String, temporaryName: String, embedding: [Float])] = []
        var diarSegTuples: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] = []
        var unmatchedRosterNamesForPrompt: [String] = []

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

            // Roster-based auto-naming: use Teams participant list to fill in unmatched speakers
            if !job.rosterNames.isEmpty {
                let rosterSet = Set(job.rosterNames)
                let knownNames = Set(matches.filter { !$0.isNewSpeaker }.map(\.assignedName))
                let unmatchedSpeakers = matches.filter { $0.isNewSpeaker }

                // Filter roster to names not already matched (excluding local user)
                let unmatchedRosterNames = rosterSet.subtracting(knownNames).subtracting([me])

                if unmatchedSpeakers.count == 1 && unmatchedRosterNames.count == 1 {
                    // Exactly one unknown speaker and one unmatched roster name — auto-assign
                    let speakerID = unmatchedSpeakers[0].detectedSpeakerID
                    let rosterName = unmatchedRosterNames.first!
                    nameMap[speakerID] = rosterName
                    NSLog("Heard: Auto-assigned roster name '\(rosterName)' to \(speakerID)")
                } else if unmatchedSpeakers.count == unmatchedRosterNames.count && unmatchedSpeakers.count > 0 {
                    // Same number of unmatched speakers and roster names — assign in order
                    let sortedRoster = unmatchedRosterNames.sorted()
                    for (i, speaker) in unmatchedSpeakers.enumerated() where i < sortedRoster.count {
                        nameMap[speaker.detectedSpeakerID] = sortedRoster[i]
                        NSLog("Heard: Auto-assigned roster name '\(sortedRoster[i])' to \(speaker.detectedSpeakerID)")
                    }
                } else {
                    // Roster names available but count mismatch — pass as suggestions for naming prompt
                    unmatchedRosterNamesForPrompt = unmatchedRosterNames.sorted()
                }
            }

            // Collect unmatched speaker info for naming prompt
            let stillUnmatched = matches.filter { $0.isNewSpeaker && nameMap[$0.detectedSpeakerID]?.hasPrefix("Speaker ") ?? true }
            unmatchedSpeakerInfo = stillUnmatched.map {
                (speakerID: $0.detectedSpeakerID, temporaryName: nameMap[$0.detectedSpeakerID] ?? $0.assignedName, embedding: $0.embedding)
            }

            // Collect diarization segments with original-time timestamps for clip extraction
            diarSegTuples = diarSegments.map {
                (speakerID: $0.speakerID, startTime: $0.startTime, endTime: $0.endTime)
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

            // Update speaker database for matched profiles
            SpeakerMatcher.updateDatabase(matches: matches, speakerStore: speakerStore)

            // Create profiles for roster-auto-assigned new speakers (those whose
            // temporary "Speaker N" label got replaced by a real roster name).
            // Unresolved new speakers are skipped here — saveSpeakerName/skipNaming
            // creates them after the user names them through the prompt.
            let stillUnmatchedIDs = Set(stillUnmatched.map(\.detectedSpeakerID))
            for match in matches where match.isNewSpeaker
                && !match.embedding.isEmpty
                && !stillUnmatchedIDs.contains(match.detectedSpeakerID) {
                let resolvedName = nameMap[match.detectedSpeakerID] ?? match.assignedName
                let profile = SpeakerProfile(
                    id: UUID(),
                    name: resolvedName,
                    embeddings: [match.embedding],
                    firstSeen: Date(),
                    lastSeen: Date(),
                    meetingCount: 1
                )
                speakerStore.upsert(profile)
            }
        }

        // Sort by start time and merge consecutive same-speaker segments
        allSegments.sort { $0.startTime < $1.startTime }
        let merged = SegmentMerger.mergeConsecutive(allSegments)

        // Handle empty result
        let finalSegments = merged.isEmpty
            ? [TranscriptSegment(speaker: me, startTime: 0, endTime: 0, text: "[No speech detected]")]
            : merged

        let segmentSpeakers = Set(finalSegments.map(\.speaker))
        let allParticipants = segmentSpeakers.union(Set(job.rosterNames)).sorted()

        return TranscriptDocument(
            title: job.meetingTitle.isEmpty ? "Meeting" : job.meetingTitle,
            startTime: job.startTime,
            endTime: job.endTime,
            participants: allParticipants,
            segments: finalSegments,
            unmatchedSpeakers: unmatchedSpeakerInfo,
            diarizationSegments: diarSegTuples,
            unmatchedRosterNames: unmatchedRosterNamesForPrompt
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

public enum PipelineError: LocalizedError {
    case noAudioFiles
    case recordingTooShort

    public var errorDescription: String? {
        switch self {
        case .noAudioFiles: return "No audio files found for this recording"
        case .recordingTooShort: return "Recording too short to transcribe"
        }
    }

    /// Errors that should not be retried (will never succeed on retry).
    public var isNonRetryable: Bool {
        switch self {
        case .noAudioFiles, .recordingTooShort: return true
        }
    }
}
