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

@MainActor
public final class MeetingDetector {
    public private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private var activeSnapshot: MeetingSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var rosterPollingTask: Task<Void, Never>?
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
            }
        } else {
            consecutiveDetections = 0
            if let snapshot = activeSnapshot {
                stopRosterPolling()
                activeSnapshot = nil
                cooldownUntil = Date().addingTimeInterval(5)
                onMeetingEnded(snapshot)
            }
        }
    }

    /// Poll IOPMCopyAssertionsByProcess for Teams holding a meeting-related power assertion.
    /// New Teams (com.microsoft.teams2) uses AssertionTrueType = PreventUserIdleDisplaySleep
    /// and/or AssertName = "Microsoft Teams Call in progress".
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

    // Context object shared between the main actor and the AUHAL render callback thread.
    private final class AppAudioInputContext: @unchecked Sendable {
        let hal: AudioUnit
        let file: AVAudioFile
        let format: AVAudioFormat
        var isStopped = false
        init(hal: AudioUnit, file: AVAudioFile, format: AVAudioFormat) {
            self.hal = hal; self.file = file; self.format = format
        }
    }

    private var micEngine: AVAudioEngine?
    private var appHALUnit: AudioUnit?
    private var appHALContext: AppAudioInputContext?
    private var micAudioFile: AVAudioFile?
    private var appAudioFile: AVAudioFile?
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var maxDurationTask: Task<Void, Never>?
    private var micStartTime: Date?
    private var appStartTime: Date?

    /// AsyncStream publisher for mic buffers — v2 dictation will subscribe to this.
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var micBufferStream: AsyncStream<AVAudioPCMBuffer>?

    /// Callback for max-duration split: enqueue current session, optionally restart.
    public var onMaxDurationReached: (@MainActor (RecordingSession) -> Void)?

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

    private func setupAppAudioRecording(pid: pid_t, to url: URL) throws {
        // ── Step 1: Collect ALL Teams-related process object IDs ──────────────
        // Teams (Electron/Chromium) renders audio in renderer / GPU sub-processes,
        // not necessarily the main process that holds the power assertion. Tapping
        // only the reported PID misses audio from those child processes.
        let processObjectIDs = collectTeamsProcessObjectIDs(requiredPID: pid)
        guard !processObjectIDs.isEmpty else {
            NSLog("Heard: No CoreAudio process objects found for Teams (pid=%d)", pid)
            throw RecordingError.processTapFailed(kAudioHardwareBadObjectError)
        }
        NSLog("Heard: Creating process tap for %d Teams process(es)", processObjectIDs.count)

        // ── Step 2: Create the process tap ────────────────────────────────────
        // Screen Recording permission is required for AudioHardwareCreateProcessTap.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("Heard: Screen Recording permission not granted — process tap will likely fail")
        }
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDesc.name = "Heard Tap"
        // Use non-exclusive (isPrivate = false) so our tap works alongside Teams' own internal
        // audio taps (noise cancellation, echo processing, etc.). An exclusive tap would be
        // rejected if any other client already holds a tap on the same processes.
        tapDesc.isPrivate = false
        tapDesc.muteBehavior = .unmuted

        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
        guard tapErr == noErr else {
            NSLog("Heard: AudioHardwareCreateProcessTap failed (%d)", tapErr)
            throw RecordingError.processTapFailed(tapErr)
        }
        NSLog("Heard: Process tap created (id=%u)", tapObjectID)

        // ── Step 3: Get tap UID ───────────────────────────────────────────────
        var tapUIDRef: CFString = "" as CFString
        var tapUIDSize = UInt32(MemoryLayout<CFString>.size)
        var tapUIDProp = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapUIDErr = withUnsafeMutablePointer(to: &tapUIDRef) { ptr in
            AudioObjectGetPropertyData(tapObjectID, &tapUIDProp, 0, nil, &tapUIDSize, ptr)
        }
        guard tapUIDErr == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw RecordingError.deviceSetupFailed(tapUIDErr)
        }
        let tapUID = tapUIDRef as String

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

        // ── Step 5: Create private aggregate device containing the tap ────────
        let aggregateUID = "com.execsumo.heard.tap.\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Heard Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
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

        // ── Step 6: Build a raw HAL Output Audio Unit ─────────────────────────
        // AVAudioEngine.inputNode is NOT used here: calling engine.prepare() after
        // changing kAudioOutputUnitProperty_CurrentDevice on the engine's underlying
        // unit causes the engine to re-bind to the system default input (mic), silently
        // discarding the device change. A standalone AUHAL configured before
        // AudioUnitInitialize is the only reliable way to select a custom input device.
        var halDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let halComponent = AudioComponentFindNext(nil, &halDesc) else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw RecordingError.deviceSetupFailed(kAudioHardwareUnspecifiedError)
        }
        var halRef: AudioUnit?
        let newErr = AudioComponentInstanceNew(halComponent, &halRef)
        guard newErr == noErr, let hal = halRef else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw RecordingError.deviceSetupFailed(newErr)
        }

        // Wrap remaining setup so we can dispose the AUHAL on any error.
        do {
            // Enable input on bus 1; disable output on bus 0.
            var one: UInt32 = 1, zero: UInt32 = 0
            AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &one, 4)
            AudioUnitSetProperty(hal, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0, &zero, 4)

            // Point the AUHAL at the aggregate device BEFORE AudioUnitInitialize.
            var devID = aggregateDeviceID
            let setErr = AudioUnitSetProperty(
                hal, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID, UInt32(MemoryLayout<AudioObjectID>.size)
            )
            guard setErr == noErr else {
                NSLog("Heard: AUHAL CurrentDevice failed (%d)", setErr)
                throw RecordingError.deviceSetupFailed(setErr)
            }

            // Query the hardware input format (output scope of bus 1 = what arrives from hw).
            var hwFmt = AudioStreamBasicDescription()
            var hwFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioUnitGetProperty(hal, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1, &hwFmt, &hwFmtSize)
            let sampleRate = hwFmt.mSampleRate > 0 ? hwFmt.mSampleRate : 48000.0
            let channels   = hwFmt.mChannelsPerFrame > 0 ? hwFmt.mChannelsPerFrame : 2
            NSLog("Heard: AUHAL hw format sr=%.0f ch=%u flags=0x%x", sampleRate, channels, hwFmt.mFormatFlags)

            // Request standard non-interleaved float32 from the AUHAL.
            guard let avFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                              channels: channels) else {
                throw RecordingError.deviceSetupFailed(kAudioHardwareUnspecifiedError)
            }
            var clientFmt = avFormat.streamDescription.pointee
            AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1,
                                 &clientFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            // Create the output WAV file.
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            appAudioFile = file

            // Build context and install the AUHAL render callback.
            // kAudioOutputUnitProperty_SetInputCallback fires on each I/O cycle; we call
            // AudioUnitRender inside it to pull the data from the tap via the AUHAL.
            let ctx = AppAudioInputContext(hal: hal, file: file, format: avFormat)
            appHALContext = ctx

            var cb = AURenderCallbackStruct(
                inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ -> OSStatus in
                    guard let ptr = inRefCon,
                          let ts = inTimeStamp,
                          inNumberFrames > 0 else { return noErr }
                    let context = Unmanaged<AppAudioInputContext>.fromOpaque(ptr).takeUnretainedValue()
                    guard !context.isStopped else { return noErr }

                    guard let buf = AVAudioPCMBuffer(pcmFormat: context.format,
                                                    frameCapacity: inNumberFrames) else { return noErr }
                    buf.frameLength = inNumberFrames

                    let renderErr = AudioUnitRender(context.hal, ioActionFlags, ts,
                                                   inBusNumber, inNumberFrames,
                                                   buf.mutableAudioBufferList)
                    if renderErr == noErr {
                        try? context.file.write(from: buf)
                    } else {
                        NSLog("Heard: AudioUnitRender error %d", renderErr)
                    }
                    return noErr
                },
                inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque()
            )
            let cbErr = AudioUnitSetProperty(
                hal, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0,
                &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard cbErr == noErr else {
                NSLog("Heard: SetInputCallback failed (%d)", cbErr)
                throw RecordingError.deviceSetupFailed(cbErr)
            }

            // Initialize (locks in the device/format) then start.
            let initErr = AudioUnitInitialize(hal)
            guard initErr == noErr else {
                NSLog("Heard: AudioUnitInitialize failed (%d)", initErr)
                throw RecordingError.deviceSetupFailed(initErr)
            }
            let startErr = AudioOutputUnitStart(hal)
            guard startErr == noErr else {
                AudioUnitUninitialize(hal)
                NSLog("Heard: AudioOutputUnitStart failed (%d)", startErr)
                throw RecordingError.deviceSetupFailed(startErr)
            }

            appHALUnit = hal
            appStartTime = Date()
            NSLog("Heard: App audio capture started (raw AUHAL, aggregate=%u)", aggregateDeviceID)

        } catch {
            AudioComponentInstanceDispose(hal)
            appHALContext = nil
            appAudioFile = nil
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID); aggregateDeviceID = 0
            AudioHardwareDestroyProcessTap(tapObjectID); tapObjectID = 0
            throw error
        }
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
        appHALContext?.isStopped = true
        if let hal = appHALUnit {
            AudioOutputUnitStop(hal)
            AudioUnitUninitialize(hal)
            AudioComponentInstanceDispose(hal)
            appHALUnit = nil
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
    private let onPipelineIdle: @MainActor () -> Void

    /// In-memory state for the current pipeline job.
    private var appTrack: PreprocessedTrack?
    private var micTrack: PreprocessedTrack?
    private var appTranscription: ASRResult?
    private var micTranscription: ASRResult?
    private var appDiarization: DiarizationResult?
    private var micDiarization: DiarizationResult?

    /// Cached models for keep-alive between jobs.
    private var cachedAsrModels: AsrModels?
    private var cachedAsrManager: AsrManager?
    private var modelUnloadTask: Task<Void, Never>?

    private static let retryDelays: [TimeInterval] = [5, 30, 300]
    private static let maxRetries = 3

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
        micDiarization = nil

        // Schedule model unload based on keep-alive setting
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
        NSLog("Heard: Pipeline models unloaded")
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

                // Fail immediately for errors that will never succeed on retry
                if let pipelineError = error as? PipelineError, pipelineError.isNonRetryable {
                    NSLog("Heard: Non-retryable error for job \(working.id): \(error)")
                    working.stage = .failed
                    queueStore.update(working)
                    return
                }

                queueStore.update(working)

                if attempt < Self.maxRetries - 1 {
                    let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                    NSLog("Heard: Stage \(working.stage.rawValue) failed (attempt \(attempt + 1)), retrying in \(Int(delay))s: \(error)")
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    NSLog("Heard: Exhausted retries for job \(working.id): \(error)")
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
                        audioClipURL: clip.clipURL,
                        embedding: clip.embedding
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

    // MARK: - Stage 2: Transcription (Parakeet TDT V2)

    private func runTranscription(_ job: PipelineJob) async throws {
        // Cancel any pending unload — we're using the models now
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        // Reuse cached models if available, otherwise load fresh
        let asrManager: AsrManager
        if let cached = cachedAsrManager {
            asrManager = cached
        } else {
            let models = try await AsrModels.loadFromCache(version: .v2)
            let manager = AsrManager()
            try await manager.initialize(models: models)
            asrManager = manager
            cachedAsrModels = models
            cachedAsrManager = manager
        }

        // Configure custom vocabulary boosting if terms are set and CTC models available
        let vocab = settingsStore.settings.customVocabulary
        if !vocab.isEmpty {
            do {
                let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                let ctcTokenizer = try await CtcTokenizer.load(
                    from: CtcModels.defaultCacheDirectory(for: .ctc110m)
                )
                let terms = vocab.map { term in
                    let tokenIds = ctcTokenizer.encode(term)
                    return CustomVocabularyTerm(text: term, weight: 10.0, ctcTokenIds: tokenIds.isEmpty ? nil : tokenIds)
                }
                let context = CustomVocabularyContext(terms: terms)
                try await asrManager.configureVocabularyBoosting(
                    vocabulary: context,
                    ctcModels: ctcModels
                )
                NSLog("Heard: Vocabulary boosting configured with \(vocab.count) terms")
            } catch {
                NSLog("Heard: Vocabulary boosting unavailable, continuing without: \(error)")
            }
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

enum PipelineError: LocalizedError {
    case noAudioFiles
    case recordingTooShort

    var errorDescription: String? {
        switch self {
        case .noAudioFiles: return "No audio files found for this recording"
        case .recordingTooShort: return "Recording too short to transcribe"
        }
    }

    /// Errors that should not be retried (will never succeed on retry).
    var isNonRetryable: Bool {
        switch self {
        case .noAudioFiles, .recordingTooShort: return true
        }
    }
}
