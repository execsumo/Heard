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
import ScreenCaptureKit
import ServiceManagement

// MARK: - Data Types

/// A meeting app Heard knows how to detect via IOKit power assertions.
public enum MeetingApp: String, CaseIterable, Codable, Sendable {
    case teams
    case zoom
    case webex

    /// Bundle IDs of the main meeting app process (helpers excluded by name suffix in `isHelperBundleID`).
    public var bundleIDs: Set<String> {
        switch self {
        case .teams: return ["com.microsoft.teams", "com.microsoft.teams2"]
        case .zoom:  return ["us.zoom.xos"]
        case .webex: return ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"]
        }
    }

    /// Localized-name fallbacks for builds that ship under an unfamiliar bundle ID.
    public var processNames: Set<String> {
        switch self {
        case .teams:
            return [
                "Microsoft Teams",
                "Microsoft Teams (work or school)",
                "Microsoft Teams classic",
            ]
        case .zoom, .webex:
            return []
        }
    }

    /// Regex stripped from the window title to extract the meeting name.
    /// Matches the trailing app-name suffix that each client appends.
    public var titleSuffixPattern: String {
        switch self {
        case .teams: return #"\s*\|\s*Microsoft Teams.*$"#
        case .zoom:  return #"\s*[-–]\s*Zoom.*$"#
        case .webex: return #"\s*[-–]\s*Webex.*$"#
        }
    }

    /// Bare placeholder window titles to ignore (no real meeting name extractable).
    public var placeholderTitles: Set<String> {
        switch self {
        case .teams: return []
        case .zoom:  return ["Zoom Meeting", "Zoom", "Zoom Workplace"]
        case .webex: return ["Webex", "Webex Meetings", "Cisco Webex Meetings"]
        }
    }

    public var displayName: String {
        switch self {
        case .teams: return "Microsoft Teams"
        case .zoom:  return "Zoom"
        case .webex: return "Webex"
        }
    }

    /// True if the process belongs to this meeting app's process family —
    /// main app *or* helpers. Used to collect every process worth tapping for
    /// audio: Electron-based clients (Teams, Webex) render call audio in
    /// renderer/GPU helper processes, not the main process that holds the
    /// power assertion.
    public func isProcessFamilyMember(bundleID: String?, localizedName: String?) -> Bool {
        let bundle = bundleID?.lowercased() ?? ""
        let name = localizedName?.lowercased() ?? ""
        switch self {
        case .teams:
            return bundle.hasPrefix("com.microsoft.teams")
                || (name.hasPrefix("microsoft teams") && !bundle.isEmpty)
        case .zoom:
            return bundle.hasPrefix("us.zoom.")
                || (name.hasPrefix("zoom") && !bundle.isEmpty)
        case .webex:
            return bundle.hasPrefix("cisco-systems.spark")
                || bundle.hasPrefix("com.cisco.webex")
                || (name.contains("webex") && !bundle.isEmpty)
        }
    }
}

public struct MeetingSnapshot {
    public var title: String
    public var startedAt: Date
    public var source: MeetingApp
    public var meetingPID: pid_t?
    public var rosterNames: [String]

    public init(title: String, startedAt: Date, source: MeetingApp = .teams, meetingPID: pid_t?, rosterNames: [String] = []) {
        self.title = title
        self.startedAt = startedAt
        self.source = source
        self.meetingPID = meetingPID
        self.rosterNames = rosterNames
    }
}

public struct RecordingSession {
    public var title: String
    public let startTime: Date
    public let appAudioPath: URL
    public let micAudioPath: URL
    public var micDelaySeconds: TimeInterval
    public var rosterNames: [String]
    /// In-flight notes captured during the meeting via the note-composer hotkey.
    /// Carried into the `PipelineJob` when the session ends.
    public var notes: [MeetingNote]

    public init(title: String, startTime: Date, appAudioPath: URL, micAudioPath: URL, micDelaySeconds: TimeInterval, rosterNames: [String] = [], notes: [MeetingNote] = []) {
        self.title = title
        self.startTime = startTime
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.micDelaySeconds = micDelaySeconds
        self.rosterNames = rosterNames
        self.notes = notes
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
public final class MeetingDetector: ObservableObject {
    @Published public private(set) var isWatching = false
    private let onMeetingStarted: @MainActor (MeetingSnapshot) -> Void
    private let onMeetingEnded: @MainActor (MeetingSnapshot) -> Void
    private let enabledSources: @MainActor () -> Set<MeetingApp>
    private var activeSnapshot: MeetingSnapshot?
    private var pollingTask: Task<Void, Never>?
    private var rosterPollingTask: Task<Void, Never>?
    private var detectionState = MeetingDetectionState()
    private var isSimulated = false

    /// If `bundleID`/`localizedName` identifies the *main* process of one of the known meeting apps,
    /// return that `MeetingApp`. Helpers (e.g. `com.microsoft.teams2.helper`) return nil.
    /// Bundle-ID matching is locale-independent; localized-name fallback covers builds with unfamiliar IDs.
    nonisolated public static func meetingAppFor(bundleID: String?, localizedName: String?) -> MeetingApp? {
        if let bundleID, bundleID.contains(".helper") { return nil }
        for app in MeetingApp.allCases {
            if let bundleID, app.bundleIDs.contains(bundleID) { return app }
        }
        for app in MeetingApp.allCases {
            if let localizedName, app.processNames.contains(localizedName) { return app }
        }
        return nil
    }

    /// Backwards-compatible Teams-specific helper retained for tests and external callers.
    nonisolated public static func isTeamsMainApp(bundleID: String?, localizedName: String?) -> Bool {
        meetingAppFor(bundleID: bundleID, localizedName: localizedName) == .teams
    }

    public init(
        enabledSources: @escaping @MainActor () -> Set<MeetingApp> = { Set(MeetingApp.allCases) },
        onMeetingStarted: @escaping @MainActor (MeetingSnapshot) -> Void,
        onMeetingEnded: @escaping @MainActor (MeetingSnapshot) -> Void
    ) {
        self.enabledSources = enabledSources
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
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                self.poll()
            }
        }
    }

    private func poll() {
        // Don't interfere with simulated meetings
        if isSimulated { return }

        let enabled = enabledSources()

        // If the active source has been disabled mid-meeting, treat as end-of-meeting.
        if let snapshot = activeSnapshot, !enabled.contains(snapshot.source) {
            stopRosterPolling()
            activeSnapshot = nil
            detectionState = MeetingDetectionState()
            onMeetingEnded(snapshot)
            return
        }

        let result = Self.detectMeeting(enabled: enabled)
        let action = detectionState.step(now: Date(), detected: result != nil)

        switch action {
        case .ignore:
            return
        case .startMeeting:
            guard let result else { return }
            let pid = result.pid
            let source = result.source
            // Title/roster scraping does blocking AX IPC into the meeting app —
            // which is busy joining a call and can stall for seconds. Run it off
            // the main thread, then start the meeting once the data is in hand.
            Task { [weak self] in
                let (title, rosterNames) = await Task.detached(priority: .userInitiated) {
                    // Teams is an Electron/Chromium app: its accessibility tree is
                    // dormant until a client requests it via AXManualAccessibility.
                    // Nudge it now — the tree builds asynchronously, so this first
                    // read often still misses; the roster poll retries title+roster.
                    if source == .teams { Self.enableMeetingAppAccessibility(pid: pid, source: source) }
                    let title = Self.extractMeetingTitle(pid: pid, source: source) ?? ""
                    let roster: [String] = source == .teams ? RosterReader.readRoster(pid: pid) : []
                    return (title, roster)
                }.value
                DebugFileLog.log("meeting start scrape: source=\(source.rawValue) pid=\(pid) titleCaptured=\(!title.isEmpty) rosterCount=\(rosterNames.count) — roster poll will retry title/roster every 15s")
                guard let self else { return }
                // The meeting may have ended (or watching been toggled off) while
                // we were scraping — the detection state machine is the source of truth.
                guard self.detectionState.hasActiveSnapshot, self.activeSnapshot == nil else { return }
                let snapshot = MeetingSnapshot(
                    title: title,
                    startedAt: Date(),
                    source: source,
                    meetingPID: pid,
                    rosterNames: rosterNames
                )
                self.activeSnapshot = snapshot
                if source == .teams { self.startRosterPolling() }
                self.onMeetingStarted(snapshot)
            }
        case .endMeeting:
            guard let snapshot = activeSnapshot else { return }
            stopRosterPolling()
            activeSnapshot = nil
            onMeetingEnded(snapshot)
        }
    }

    /// Poll IOPMCopyAssertionsByProcess for any enabled meeting app holding a meeting-related
    /// power assertion. Teams, Zoom, and Webex all raise `PreventUserIdleDisplaySleep` (or the
    /// older `NoDisplaySleepAssertion`) while a call is active. AssertName containing
    /// "call in progress" / "meeting in progress" is also accepted as a fallback.
    private static func detectMeeting(enabled: Set<MeetingApp>) -> (source: MeetingApp, pid: pid_t)? {
        guard !enabled.isEmpty else { return nil }

        let runningApps = NSWorkspace.shared.runningApplications
        let candidates: [(NSRunningApplication, MeetingApp)] = runningApps.compactMap { app in
            guard let source = meetingAppFor(bundleID: app.bundleIdentifier, localizedName: app.localizedName),
                  enabled.contains(source)
            else { return nil }
            return (app, source)
        }
        guard !candidates.isEmpty else { return nil }

        var assertionsByPid: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsByPid) == kIOReturnSuccess,
              let dict = assertionsByPid?.takeRetainedValue() as NSDictionary?
        else {
            return nil
        }

        for (app, source) in candidates {
            let pid = app.processIdentifier
            guard let assertions = dict[NSNumber(value: pid)] as? [[String: Any]] else { continue }
            for assertion in assertions {
                let assertionType = assertion["AssertionType"] as? String ?? ""
                let assertionTrueType = assertion["AssertionTrueType"] as? String ?? ""
                let assertName = (assertion["AssertName"] as? String ?? "").lowercased()

                let isDisplaySleep = assertionType == "PreventUserIdleDisplaySleep"
                    || assertionTrueType == "PreventUserIdleDisplaySleep"
                    || assertionType == "NoDisplaySleepAssertion"
                let isCallInProgress = assertName.contains("call in progress")
                    || assertName.contains("meeting in progress")
                    || assertName.contains("in a meeting")

                if isDisplaySleep || isCallInProgress {
                    return (source, pid)
                }
            }
        }
        return nil
    }

    /// Wake a Chromium/Electron meeting app's accessibility tree.
    ///
    /// Teams keeps its a11y tree off by default to save resources, so AX reads of
    /// its windows/titles/roster fail (commonly `kAXErrorAPIDisabled`, -25211) even
    /// though Heard itself is trusted. Setting `AXManualAccessibility` on the app
    /// element signals Chromium to build the tree. The build is asynchronous, so
    /// callers must still retry the actual read after this returns.
    ///
    /// The `setErr` log line is the diagnostic discriminator: `.success` means the
    /// nudge was accepted (any lingering empty reads are tree-build timing); a
    /// `.apiDisabled` here would instead mean Heard is genuinely untrusted.
    nonisolated private static func enableMeetingAppAccessibility(pid: pid_t?, source: MeetingApp) {
        guard let pid else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let setErr = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        DebugFileLog.log("enableMeetingAppAccessibility: pid=\(pid) source=\(source.rawValue) setErr=\(setErr.rawValue)")
    }

    /// Extract the meeting title from a meeting-app window via Accessibility API.
    /// Strips the trailing app-name suffix (` | Microsoft Teams`, ` - Zoom`, etc.).
    /// Returns nil if AX is denied, no window matches, or the title is just a placeholder.
    /// Nonisolated: called from a detached task so the blocking AX IPC never
    /// runs on the main thread.
    nonisolated private static func extractMeetingTitle(pid: pid_t?, source: MeetingApp) -> String? {
        // Do not pre-check AXIsProcessTrusted() — it can return a stale cached false on
        // macOS 15+ even when Accessibility IS granted. AXUIElementCopyAttributeValue
        // returns .apiDisabled on its own when access is genuinely denied, so the guard
        // below handles the not-granted case correctly without the pre-check.
        guard let pid else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // Bound each AX round-trip so a hung meeting app can't hang us.
        AXUIElementSetMessagingTimeout(app, 1.0)
        var windowsRef: AnyObject?
        let windowsErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard windowsErr == .success, let windows = windowsRef as? [AXUIElement] else {
            // For a per-app Electron query, .apiDisabled (-25211) usually means the
            // app's Chromium a11y tree is still dormant (see enableMeetingAppAccessibility),
            // NOT that Heard is untrusted — confirm trust via the system-wide element
            // instead. Any failure here yields an empty title -> "Meeting" fallback;
            // the roster poll retries once the tree wakes.
            DebugFileLog.log("extractMeetingTitle: windows query failed pid=\(pid) source=\(source.rawValue) axErr=\(windowsErr.rawValue)")
            return nil
        }
        DebugFileLog.log("extractMeetingTitle: pid=\(pid) source=\(source.rawValue) windowCount=\(windows.count)")

        for window in windows {
            var titleRef: AnyObject?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty
            else { continue }
            if let cleaned = cleanWindowTitle(title, source: source) {
                DebugFileLog.log("extractMeetingTitle: raw=\(title.debugDescription) -> cleaned=\(cleaned.debugDescription)")
                return cleaned
            }
            DebugFileLog.log("extractMeetingTitle: raw=\(title.debugDescription) rejected (empty/placeholder after suffix strip)")
        }
        DebugFileLog.log("extractMeetingTitle: no usable title among \(windows.count) window(s) -> nil (falls back to 'Meeting')")
        return nil
    }

    /// Pure helper exposed for tests: strip the source's title suffix and reject placeholders.
    nonisolated public static func cleanWindowTitle(_ title: String, source: MeetingApp) -> String? {
        let cleaned = title.replacingOccurrences(
            of: source.titleSuffixPattern,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        if source.placeholderTitles.contains(cleaned) { return nil }
        return cleaned
    }

    // MARK: - Roster Polling

    /// Poll the Teams roster every 15 seconds during an active meeting to accumulate participant names.
    /// Only runs for Teams meetings — Zoom/Webex roster scraping is not implemented.
    private func startRosterPolling() {
        rosterPollingTask?.cancel()
        rosterPollingTask = Task { [weak self] in
            var tick = 0
            // Developer-Mode only: emit at most a few AX tree dumps per meeting when
            // the roster keeps coming back empty, so we can retune the parser without
            // flooding the log. Reset per meeting (the task is recreated on each start).
            var rosterDumpsRemaining = 3
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled,
                      let snapshot = self.activeSnapshot,
                      snapshot.source == .teams
                else { break }
                tick += 1
                // The roster walk is a deep recursive AX scrape of Teams'
                // Electron tree — keep it off the main thread.
                let pid = snapshot.meetingPID
                let source = snapshot.source
                // Re-extract the title until we get one: the initial capture at
                // join time usually fires before Teams' a11y tree has finished
                // building, leaving the title empty (-> "Meeting" filename).
                let needTitle = (self.activeSnapshot?.title ?? "").isEmpty
                // An empty roster means the tree still looks asleep — the join-time
                // nudge may have timed out against a busy Teams. Re-nudge before each
                // read until names appear (idempotent). Gate on roster, not title:
                // window titles can be AppKit-provided and succeed without the woken
                // Chromium tree that the roster DOM actually needs.
                let rosterEmpty = (self.activeSnapshot?.rosterNames.isEmpty ?? true)
                // While roster is still empty, capture a bounded tree dump (Developer
                // Mode + budget) so an empty result is self-diagnosing, not silent.
                let wantDump = rosterEmpty && rosterDumpsRemaining > 0 && DebugFileLog.isEnabled
                let (names, refreshedTitle, treeDump) = await Task.detached(priority: .utility) {
                    if rosterEmpty { Self.enableMeetingAppAccessibility(pid: pid, source: source) }
                    let names = RosterReader.readRoster(pid: pid)
                    let title = needTitle ? Self.extractMeetingTitle(pid: pid, source: source) : nil
                    let dump = (wantDump && names.isEmpty) ? RosterReader.diagnosticTreeDump(pid: pid) : nil
                    return (names, title, dump)
                }.value
                if !names.isEmpty {
                    let existing = Set(self.activeSnapshot?.rosterNames ?? [])
                    let newNames = names.filter { !existing.contains($0) }
                    if !newNames.isEmpty {
                        self.activeSnapshot?.rosterNames.append(contentsOf: newNames)
                    }
                }
                if let refreshedTitle, !refreshedTitle.isEmpty {
                    self.activeSnapshot?.title = refreshedTitle
                }
                DebugFileLog.log("roster poll tick=\(tick): read=\(names.count) total=\(self.activeSnapshot?.rosterNames.count ?? 0) titleEmpty=\(needTitle) titleRefreshed=\(refreshedTitle != nil)")
                if let treeDump {
                    rosterDumpsRemaining -= 1
                    DebugFileLog.log("roster poll tick=\(tick): readRoster empty — AX tree dump (\(3 - rosterDumpsRemaining)/3):\n\(treeDump)")
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
        let snapshot = MeetingSnapshot(title: title, startedAt: Date(), source: .teams, meetingPID: nil)
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
    /// True when the mic engine failed to start — recording is app-audio-only.
    @Published public private(set) var micCaptureFailed: Bool = false

    /// CoreAudio UID of the input device to record the mic track from. nil =
    /// follow the system default input device. Set by AppModel from settings.
    public var inputDeviceUID: String?

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

    /// The meeting-app PID, source, title, and roster for the current recording (needed for re-start on split).
    private var currentMeetingPID: pid_t?
    private var currentSource: MeetingApp = .teams
    private var currentTitle: String = ""
    private var currentRosterNames: [String] = []

    public func startRecording(title: String, meetingPID: pid_t?, source: MeetingApp = .teams, rosterNames: [String] = []) throws {
        guard activeSession == nil else { return }

        let stamp = Formatting.recordingFileFormatter.string(from: Date())
        let base = FileManager.default.heardAppSupportDirectory
            .appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let appPath = base.appendingPathComponent("\(stamp)_app.wav")
        let micPath = base.appendingPathComponent("\(stamp)_mic.wav")

        // Mic is best-effort, like the app tap: a broken or vanished input
        // device shouldn't lose the whole meeting. If the mic fails but the
        // app tap comes up, record app-audio-only and surface the degraded
        // state in the menu bar.
        micCaptureFailed = false
        var micError: Error?
        do {
            try setupMicRecording(to: micPath)
        } catch {
            micError = error
            micCaptureFailed = true
            NSLog("Heard: Mic capture failed (recording app audio only): \(error.localizedDescription)")
        }

        // Set up app audio recording if we have a meeting-app PID
        appAudioTapFailed = false
        currentSource = source
        var appAudioRunning = false
        if let pid = meetingPID {
            do {
                try setupAppAudioRecording(pid: pid, to: appPath)
                appAudioRunning = true
            } catch {
                // App audio is best-effort — continue with mic-only if tap fails
                appAudioTapFailed = true
                NSLog("Heard: App audio tap failed (recording mic-only): \(error.localizedDescription)")
            }
        }

        // Neither track is capturing — there is nothing to record.
        if let micError, !appAudioRunning {
            micCaptureFailed = false
            appAudioTapFailed = false
            throw micError
        }

        let micDelay: TimeInterval
        if let mic = micStartTime, let app = appStartTime {
            micDelay = mic.timeIntervalSince(app)
        } else {
            micDelay = 0
        }

        currentMeetingPID = meetingPID
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

    /// Update the meeting title on the active session. The title is often captured
    /// late (Teams' a11y tree builds after join), so the recording starts with an
    /// empty title and this fills it in before the session is enqueued, fixing the
    /// transcript filename. No-ops on empty so a failed re-attempt can't clobber a
    /// title already captured.
    public func updateTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard activeSession != nil, !trimmed.isEmpty else { return }
        activeSession?.title = trimmed
        currentTitle = trimmed
    }

    /// Append a user-authored note to the active recording session. The offset
    /// is measured from `session.startTime` using the wall-clock instant at
    /// which the composer was *opened* (passed in by the caller), not the
    /// submit instant — so a note typed slowly still anchors to when the user
    /// reacted to what was being said. Returns false if no session is active.
    @discardableResult
    public func addNote(at openedAt: Date, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let session = activeSession else { return false }
        let offset = max(0, openedAt.timeIntervalSince(session.startTime))
        activeSession?.notes.append(MeetingNote(offsetSeconds: offset, text: trimmed))
        return true
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
        micCaptureFailed = false
        defer { activeSession = nil }
        return activeSession
    }

    // MARK: - Mic Recording (AVAudioEngine)

    private func setupMicRecording(to url: URL) throws {
        let engine = AVAudioEngine()
        // Apply user-selected input device BEFORE reading the format. Changing
        // the device changes its sample rate and channel count.
        AudioInputDevices.apply(uid: inputDeviceUID, to: engine)
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

        // Log-once flag for write failures; the tap fires ~10×/s so logging
        // every failure would flood the log. Torn read at worst logs twice.
        final class WriteFailureFlag: @unchecked Sendable { var logged = false }
        let writeFailure = WriteFailureFlag()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: monoFormat) {
            [weak self] buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                if !writeFailure.logged {
                    writeFailure.logged = true
                    NSLog("Heard: Mic WAV write failed (disk full?): \(error.localizedDescription)")
                }
            }
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
        // ── Step 1: Collect ALL meeting-app process object IDs ────────────────
        // Electron/Chromium clients (Teams, Webex) render audio in renderer / GPU
        // sub-processes, not necessarily the main process that holds the power
        // assertion. Tapping only the reported PID misses audio from those children.
        let appName = currentSource.displayName
        let processObjectIDs = collectMeetingProcessObjectIDs(for: currentSource, requiredPID: pid)
        guard !processObjectIDs.isEmpty else {
            NSLog("Heard: No CoreAudio process objects found for %@ (pid=%d). The process(es) haven't opened audio yet — translate-PID returns 0 until they do.", appName, pid)
            throw RecordingError.processTapFailed(kAudioHardwareBadObjectError)
        }
        NSLog("Heard: Creating process tap for %d %@ process(es)", processObjectIDs.count, appName)
        if processObjectIDs.count == 1 {
            NSLog("Heard: WARNING — only ONE %@ audio process found. Electron-based clients typically render call audio in helper processes; if the captured WAV is silent, the wrong process is being tapped.", appName)
        }

        // ── Step 2: Create the process tap ────────────────────────────────────
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

            do {
                try ctx.file.write(from: buf)
            } catch {
                // Surface write failures (disk full, volume gone) instead of
                // silently producing an empty WAV. Counted into the periodic
                // stats line; logged in full once.
                ctx.renderErrorCount &+= 1
                ctx.lastRenderError = OSStatus(truncatingIfNeeded: (error as NSError).code)
                if ctx.renderErrorCount == 1 {
                    NSLog("Heard: App audio WAV write failed (disk full?): %@", error.localizedDescription)
                }
            }
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

    /// Find CoreAudio process object IDs for all running processes in the meeting
    /// app's family. Electron clients can render audio from the main process OR
    /// helper processes (Teams Helper, Teams Helper (GPU), etc.). We tap all of
    /// them so that audio from any subprocess is captured regardless of which
    /// one is active.
    private func collectMeetingProcessObjectIDs(for source: MeetingApp, requiredPID: pid_t) -> [AudioObjectID] {
        let meetingApps = NSWorkspace.shared.runningApplications.filter { app in
            source.isProcessFamilyMember(bundleID: app.bundleIdentifier, localizedName: app.localizedName)
        }

        var pids = meetingApps.map(\.processIdentifier)
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
                NSLog("Heard: Tapping %@ process pid=%d objectID=%u (%@)",
                      source.displayName, pid, objID,
                      meetingApps.first(where: { $0.processIdentifier == pid })?.localizedName ?? "?")
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
            // The rebuild truncated and restarted the app WAV, so the app
            // track's t=0 moved to the new appStartTime. Recompute the
            // mic/app alignment offset (mic.start − app.start, same formula
            // as startRecording) — otherwise bleed dedup and interleaving
            // run with a delay that's stale by the rebuild gap (~2–4 s).
            if let mic = micStartTime, let app = appStartTime {
                let delay = mic.timeIntervalSince(app)
                activeSession?.micDelaySeconds = delay
                NSLog("Heard: Rebuild moved app-track start — mic delay recalibrated to %.2fs", delay)
            }
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

        // Restart recording if we had a meeting-app PID (meeting still active)
        let pid = currentMeetingPID
        let source = currentSource
        let title = currentTitle
        let roster = currentRosterNames
        if pid != nil {
            do {
                try startRecording(title: title + " (cont.)", meetingPID: pid, source: source, rosterNames: roster)
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

/// Pure state machine for the cached Screen Recording grant. Exposed for unit tests.
///
/// macOS only applies a Screen Recording revocation after the app restarts, so:
/// - a grant confirmed by a live probe this session is sticky for the rest of the
///   process lifetime (a downgrade within the same session is always stale), but
/// - a grant cached from a previous session may have been revoked while the app was
///   not running, so it is only trusted until `reconfirmBudget` consecutive failed
///   probes have elapsed (~30 s at the 3 s poll interval — enough to ride out the
///   window-list probe's transient false negatives), after which it is cleared and
///   the permission reports Not Granted.
/// If a probe succeeds after the budget ran out (the false negatives outlasted it),
/// the grant re-confirms and re-persists on that poll tick.
public struct ScreenCaptureGrantCache: Equatable {
    /// What the caller must write to the persisted flag after a probe (nil = no change).
    public enum PersistAction: Equatable {
        case markGranted
        case clearGrant
    }

    public private(set) var confirmedThisSession = false
    public private(set) var cachedFromPreviousSession: Bool
    public private(set) var reconfirmBudget: Int

    public init(cachedFromPreviousSession: Bool, reconfirmBudget: Int = 10) {
        self.cachedFromPreviousSession = cachedFromPreviousSession
        self.reconfirmBudget = reconfirmBudget
    }

    /// Whether the permission should currently be treated as granted.
    public var isGranted: Bool { confirmedThisSession || cachedFromPreviousSession }

    /// Feed one probe result from the 3 s background poll. A `false` may be a transient
    /// false negative (stale CGPreflight cache, no titled windows on screen), so it only
    /// chips away at the reconfirmation budget rather than downgrading immediately.
    public mutating func recordProbe(granted: Bool) -> PersistAction? {
        if granted {
            let firstConfirmation = !confirmedThisSession
            confirmedThisSession = true
            return firstConfirmation ? .markGranted : nil
        }
        guard !confirmedThisSession, cachedFromPreviousSession else { return nil }
        reconfirmBudget -= 1
        if reconfirmBudget <= 0 {
            cachedFromPreviousSession = false
            return .clearGrant
        }
        return nil
    }

    /// Feed an authoritative probe result (SCShareableContent reads the live TCC
    /// database). A `false` here is definitive, so the cached grant clears immediately
    /// instead of waiting out the reconfirmation budget.
    public mutating func recordAuthoritativeProbe(granted: Bool) -> PersistAction? {
        if granted { return recordProbe(granted: true) }
        guard !confirmedThisSession, cachedFromPreviousSession else { return nil }
        cachedFromPreviousSession = false
        reconfirmBudget = 0
        return .clearGrant
    }
}

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var statuses: [PermissionStatus] = []

    private var refreshTask: Task<Void, Never>?
    // Tracks the Screen Recording grant across sessions. A grant confirmed live this
    // session is sticky for the process lifetime; a grant cached from a previous session
    // (UserDefaults) is reconfirmed after launch and cleared if the user revoked the
    // permission while Heard wasn't running. See ScreenCaptureGrantCache.
    private var screenCaptureGrant = ScreenCaptureGrantCache(
        cachedFromPreviousSession: UserDefaults.standard.bool(forKey: "screenCaptureTCCGranted")
    )
    // Set when the user clicks "Grant…" so the System Settings deactivation observer
    // knows to do a live check when they return.
    private var pendingScreenCaptureCheck = false
    private var systemPrefsObserver: (any NSObjectProtocol)?

    public init() {
        refresh()
        // The System Audio grant is cached in UserDefaults (there's no query API
        // for kTCCServiceAudioCapture). Validate it once per launch so a revoked
        // permission doesn't show "Granted" forever — TCC revocations only take
        // effect after an app restart, so once per launch is exactly enough.
        if UserDefaults.standard.bool(forKey: "audioCaptureTCCGranted") {
            validateCachedAudioCaptureGrant()
        }
        // Periodically re-check permissions (catches grants made in System Settings).
        refreshTask = Task { [weak self] in
            // Run an immediate authoritative check so an already-granted permission is
            // reflected at launch rather than after the first 3 s tick — this is what
            // makes a grant from a previous session stick after an app restart.
            await self?.refreshAsync()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                await self.refreshAsync()
            }
        }
    }

    /// Re-verify the cached System Audio grant with a momentary process tap.
    /// Only called when the cached flag is true: in that state the permission is
    /// either still granted (tap succeeds silently) or was revoked/denied (tap
    /// fails without prompting — macOS doesn't re-prompt a denied service).
    /// Skipped when no process has opened audio yet; the cached value stands
    /// until the next launch that can verify it.
    private func validateCachedAudioCaptureGrant() {
        guard let target = anyAudioProcessObjectID() else { return }
        let desc = CATapDescription(stereoMixdownOfProcesses: [target])
        desc.uuid = UUID()
        desc.name = "Heard Permission Validation"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID: AudioObjectID = 0
        if AudioHardwareCreateProcessTap(desc, &tapID) == noErr {
            AudioHardwareDestroyProcessTap(tapID)
        } else {
            NSLog("Heard: Cached System Audio grant failed validation — marking as not granted")
            UserDefaults.standard.set(false, forKey: "audioCaptureTCCGranted")
            refresh()
        }
    }

    // Performs the async screen-capture check then calls the sync refresh.
    private func refreshAsync() async {
        // Background polling uses CGPreflightScreenCaptureAccess() — it reads the live
        // TCC database without triggering any permission dialog. On macOS 15+ the return
        // value may be cached to the process's initial state and won't flip to true after
        // a mid-session grant; the one-shot SCShareableContent check (fired when System
        // Settings deactivates after a user-initiated "Grant…") handles that case.
        //
        // A grant confirmed this session is never downgraded: revocations only take
        // effect after an app restart, so within a session a false probe can only be
        // stale. A grant cached from a PREVIOUS session is different — the user may have
        // revoked it while Heard wasn't running — so it must be reconfirmed after launch
        // and is cleared if probes keep failing (see ScreenCaptureGrantCache).
        //
        // CGPreflightScreenCaptureAccess() can also return a stale false on a FRESH launch
        // on macOS 15+ (notably for ad-hoc signed builds), which would leave a previously-
        // granted permission showing as "Not Granted" after an app restart. Fall back to a
        // non-prompting window-list probe, which reads the live grant without ever
        // triggering the TCC dialog (so it is safe in this background loop).
        if !screenCaptureGrant.confirmedThisSession {
            applyScreenCaptureProbe(
                CGPreflightScreenCaptureAccess() || Self.screenRecordingGrantedViaWindowList()
            )
        }
        refresh()
    }

    /// Feed a probe result into the grant cache and persist any resulting state change.
    private func applyScreenCaptureProbe(_ granted: Bool, authoritative: Bool = false) {
        let action = authoritative
            ? screenCaptureGrant.recordAuthoritativeProbe(granted: granted)
            : screenCaptureGrant.recordProbe(granted: granted)
        switch action {
        case .markGranted:
            UserDefaults.standard.set(true, forKey: "screenCaptureTCCGranted")
        case .clearGrant:
            UserDefaults.standard.set(false, forKey: "screenCaptureTCCGranted")
        case nil:
            break
        }
    }

    /// Authoritative, non-prompting Screen Recording check used by the background poll.
    ///
    /// Reading the window *title* (`kCGWindowName`) of a window owned by another process
    /// requires Screen Recording permission on macOS 10.15+. If any such title is
    /// readable, the permission is granted. Unlike `SCShareableContent`, this never shows
    /// the TCC prompt when permission is missing, so it is safe to call repeatedly.
    /// It can yield a transient false negative if no other app currently has a titled
    /// on-screen window, but the poll retries every 3 s and never downgrades a confirmed
    /// grant, so the result converges to the correct value.
    private nonisolated static func screenRecordingGrantedViaWindowList() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pid != ourPID else { continue }
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
    }

    /// One-shot live permission check via SCShareableContent, which bypasses the
    /// CGPreflightScreenCaptureAccess() per-process cache on macOS 15+.
    ///
    /// WARNING: This call triggers the macOS TCC permission dialog if screen recording
    /// has not yet been granted. It must ONLY be called in direct response to an explicit
    /// user action (e.g. the "Grant…" button), never from a background polling loop.
    private func checkScreenCapturePermissionLive() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    public func refresh() {
        let updated = [
            PermissionStatus(
                id: "microphone",
                title: "Microphone",
                purpose: "Record your voice during meetings.",
                state: microphoneState()
            ),
            PermissionStatus(
                id: "audioCapture",
                title: "System Audio",
                purpose: "Capture Teams audio to record other participants. Click Grant to approve up front instead of mid-meeting.",
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
        // Publish only when something actually changed. This runs on a 3 s poll
        // for the app's lifetime — assigning an identical array would still fire
        // objectWillChange and re-render every observing view on every tick.
        if updated != statuses {
            statuses = updated
        }
    }

    public var isAccessibilityGranted: Bool {
        if AXIsProcessTrusted() { return true }
        // AXIsProcessTrusted can return a stale false on macOS 15+. Fall back to a live
        // AX API call: only kAXErrorAPIDisabled means "no permission".
        let sysWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(sysWide, kAXFocusedApplicationAttribute as CFString, &value)
        return err != .apiDisabled
    }

    public var isScreenCaptureGranted: Bool {
        CGPreflightScreenCaptureAccess() || screenCaptureGrant.isGranted
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

    /// Preflight the System Audio (kTCCServiceAudioCapture) permission so the macOS
    /// TCC prompt appears from Heard's Settings rather than mid-meeting. Creates and
    /// immediately destroys a brief process tap; that call is what triggers the prompt.
    /// If the permission is already granted, the tap succeeds and we mark the cached
    /// state as granted. Falls back to opening System Settings if no audio process
    /// objects exist yet to target.
    public func requestAudioCapture() {
        guard let target = anyAudioProcessObjectID() else {
            openAudioCaptureSettings()
            return
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: [target])
        desc.uuid = UUID()
        desc.name = "Heard Permission Preflight"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        let err = AudioHardwareCreateProcessTap(desc, &tapID)
        if err == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            NSLog("Heard: System Audio preflight succeeded — permission granted")
            markAudioCaptureGranted()
            return
        }

        NSLog("Heard: System Audio preflight failed (%d) — TCC prompt should appear", err)
        // The prompt is asynchronous; re-check shortly so the UI can flip to "Granted"
        // once the user accepts without forcing them to wait for the next 3s refresh tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in self?.recheckAudioCapture() }
        }
    }

    /// Re-attempt the preflight tap silently to detect a freshly granted permission.
    private func recheckAudioCapture() {
        guard let target = anyAudioProcessObjectID() else { return }
        let desc = CATapDescription(stereoMixdownOfProcesses: [target])
        desc.uuid = UUID()
        desc.name = "Heard Permission Recheck"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID: AudioObjectID = 0
        if AudioHardwareCreateProcessTap(desc, &tapID) == noErr {
            AudioHardwareDestroyProcessTap(tapID)
            markAudioCaptureGranted()
        }
    }

    /// Pick any process object the system already knows about, to use as a
    /// preflight target. Returns nil if no processes have opened audio yet.
    private func anyAudioProcessObjectID() -> AudioObjectID? {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &list
        ) == noErr else { return nil }

        return list.first(where: { $0 != 0 })
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

        // Already confirmed live this session — nothing more to do. (A grant merely
        // cached from a previous session still goes through the live check below, so a
        // stale cache can't suppress a legitimate re-grant flow.)
        guard !screenCaptureGrant.confirmedThisSession else { return }

        // Watch for System Settings to deactivate: that's the signal that the user has
        // finished with the privacy page (granted or dismissed) and returned to another
        // app. We do the one-shot live SCShareableContent check at that moment rather
        // than after an arbitrary delay, so it always fires AFTER the user interaction
        // rather than mid-interaction (which would re-trigger the TCC prompt).
        pendingScreenCaptureCheck = true
        guard systemPrefsObserver == nil else { return }
        systemPrefsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  // macOS 13+: "System Settings"; earlier: "System Preferences" — both share this bundle ID
                  app.bundleIdentifier == "com.apple.systempreferences"
            else { return }

            // The observer is registered with `queue: .main`, so this block always runs
            // on the main actor — assert that to access main-actor-isolated state safely
            // (the alternative, a bare Task hop, would let a second notification slip in
            // before the flag/observer are cleared).
            MainActor.assumeIsolated {
                guard self.pendingScreenCaptureCheck else { return }

                // One-shot: remove the observer and clear the flag immediately.
                self.pendingScreenCaptureCheck = false
                if let obs = self.systemPrefsObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(obs)
                    self.systemPrefsObserver = nil
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Fast path: sync check (works on macOS < 15 and after any restart).
                    if CGPreflightScreenCaptureAccess() {
                        self.applyScreenCaptureProbe(true)
                        self.refresh()
                        return
                    }
                    // Bypass macOS 15+ per-process TCC cache with one-shot SCShareableContent.
                    // Safe here: this is user-initiated and fires exactly once per "Grant…" click,
                    // only after the user has left System Settings. The result is authoritative,
                    // so a false clears any stale cached grant immediately.
                    self.applyScreenCaptureProbe(
                        await self.checkScreenCapturePermissionLive(), authoritative: true
                    )
                    self.refresh()
                }
            }
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
        // screenCaptureGrant is updated every 3 s via the background polling task.
        // Background polling uses CGPreflightScreenCaptureAccess() to avoid triggering
        // TCC prompts. A one-shot SCShareableContent check (checkScreenCapturePermissionLive)
        // is used to bypass the macOS 15+ per-process cache, but only when the user
        // explicitly presses the "Grant…" button — never from the polling loop.
        Self.screenCapturePermissionState(
            syncGranted: CGPreflightScreenCaptureAccess(),
            liveGranted: screenCaptureGrant.isGranted
        )
    }

    private func accessibilityState() -> PermissionState {
        if AXIsProcessTrusted() { return .granted }
        // AXIsProcessTrusted can return stale TCC data on macOS 15+. Confirm with a
        // live AX API call: only kAXErrorAPIDisabled means "no permission" — all other
        // results (including kAXErrorNoValue for "no focused app") mean the process IS
        // trusted. Note: AXError has no .notTrusted member; the enum jumps directly
        // from .apiDisabled to .noValue.
        let sysWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(sysWide, kAXFocusedApplicationAttribute as CFString, &value)
        return Self.accessibilityPermissionState(
            isTrusted: false,
            liveGranted: err != .apiDisabled
        )
    }

    // MARK: - Testable state helpers

    /// Exposed for unit tests. Screen recording is granted if either the
    /// (potentially cached) sync check or the live SCShareableContent check confirms it.
    public nonisolated static func screenCapturePermissionState(syncGranted: Bool, liveGranted: Bool) -> PermissionState {
        (syncGranted || liveGranted) ? .granted : .recommended
    }

    /// Exposed for unit tests. Accessibility is granted if either AXIsProcessTrusted()
    /// or the live AX API fallback confirms it.
    public nonisolated static func accessibilityPermissionState(isTrusted: Bool, liveGranted: Bool) -> PermissionState {
        (isTrusted || liveGranted) ? .granted : .recommended
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
    /// When true, the app stays in `.regular` mode even when all windows are closed.
    public static var persistentDockIcon: Bool = false

    /// Register that `owner` needs `.regular` activation policy.
    public static func begin(_ owner: String) {
        owners.insert(owner)
        syncPolicy()
        if owners.count == 1 {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Unregister `owner`.
    public static func end(_ owner: String) {
        owners.remove(owner)
        syncPolicy()
    }

    /// Synchronize the app's activation policy based on open windows and persistent setting.
    public static func syncPolicy() {
        let needsRegular = persistentDockIcon || !owners.isEmpty
        let current = NSApp.activationPolicy()
        let target: NSApplication.ActivationPolicy = needsRegular ? .regular : .accessory
        
        if current != target {
            NSApp.setActivationPolicy(target)
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
        // Skip the disk write when nothing changed. The popup save and the
        // Speakers tab both call this function across every queued transcript
        // and across every file in the output directory to make sure the
        // rename actually lands, so on a typical install most invocations are
        // no-ops; rewriting an unchanged file just adds unnecessary I/O.
        guard updated != original else { return }
        try? updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    /// Rename `oldName` to `newName` across every `.md` transcript directly
    /// inside `directory`. Speaker numbers are globally unique, so in practice
    /// only one transcript matches — but scanning every file lets the rename
    /// hold up if the same placeholder is ever shared across transcripts.
    public static func renameSpeakerInDirectory(
        _ directory: URL,
        from oldName: String,
        to newName: String
    ) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, oldName != trimmed else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }
        for url in entries where url.pathExtension.lowercased() == "md" {
            renameSpeaker(in: url, from: oldName, to: trimmed)
        }
    }

    public static func write(document: TranscriptDocument, outputDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let title = document.title.sanitizedFileName()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filenameStr = "\(formatter.string(from: document.startTime))_\(title)"

        var candidate = outputDirectory.appendingPathComponent("\(filenameStr).md")
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(filenameStr)_\(suffix).md")
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

        let body = renderBody(segments: document.segments, notes: document.notes, noteAuthor: document.noteAuthor)

        try (header + body + "\n").write(to: candidate, atomically: true, encoding: .utf8)
        return candidate
    }

    /// Merge spoken segments and user-authored notes into a single chronological
    /// markdown body. Notes are rendered in italics with a `**Note from <Name>:**`
    /// label so they're visually distinct from spoken speaker blocks. Notes use
    /// their `offsetSeconds` as the timestamp; for sort stability when a note
    /// shares a timestamp with a segment, the note appears immediately after.
    public static func renderBody(
        segments: [TranscriptSegment],
        notes: [MeetingNote],
        noteAuthor: String
    ) -> String {
        let author = noteAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Me"
            : noteAuthor.trimmingCharacters(in: .whitespacesAndNewlines)

        enum Item {
            case segment(TranscriptSegment)
            case note(MeetingNote)
            var time: TimeInterval {
                switch self {
                case .segment(let s): return s.startTime
                case .note(let n): return n.offsetSeconds
                }
            }
            // 0 for segments, 1 for notes — keeps notes after a segment that
            // starts at the same instant rather than splitting the speaker block
            // by a hair.
            var sortKind: Int {
                switch self {
                case .segment: return 0
                case .note: return 1
                }
            }
        }

        var items: [Item] = segments.map { .segment($0) } + notes.map { .note($0) }
        items.sort { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.sortKind < rhs.sortKind
        }

        return items.map { item -> String in
            switch item {
            case .segment(let s):
                return "[\(s.startTime.timestampString)] **\(s.speaker):** \(s.text)"
            case .note(let n):
                let body = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let timestamp = max(0, n.offsetSeconds).timestampString
                return "[\(timestamp)] _**Note from \(author):** \(body)_"
            }
        }.joined(separator: "\n\n")
    }
}

// MARK: - Pipeline Processor

/// Processes recorded meetings through: preprocessing → transcription → diarization → speaker assignment → output.
/// Jobs are processed sequentially (one at a time) to avoid ANE contention.
/// Failed stages retry up to 3 times with exponential backoff (5s, 30s, 5min).
@MainActor
public final class PipelineProcessor: ObservableObject {
    @Published public private(set) var isProcessing = false
    /// 0.0–1.0 while the transcription stage is running; nil at all other times.
    @Published public private(set) var transcriptionProgress: Double? = nil

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
    /// The currently-running pipeline task. Stored so the watchdog can cancel it.
    private var pipelineTask: Task<Void, Never>?
    /// Monotonic token identifying the current pipeline run. Bumped when a new
    /// run starts and when the watchdog aborts one. Task cancellation alone is
    /// not enough to stop a run: FluidAudio calls may not honour the signal, so
    /// a cancelled task can wake from its await minutes later and keep
    /// executing. Every resumption point compares its captured generation
    /// against this value before touching shared per-job state — a superseded
    /// run dies at its next checkpoint instead of corrupting the job that
    /// replaced it.
    private var runGeneration = 0

    /// Throws `CancellationError` when the captured generation has been
    /// superseded. Called after every await before writing shared state.
    private func ensureCurrent(_ generation: Int) throws {
        guard generation == runGeneration else { throw CancellationError() }
    }

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
            rosterNames: session.rosterNames,
            notes: session.notes,
            micDelaySeconds: session.micDelaySeconds
        )
        queueStore.enqueue(job)
        runNextIfNeeded()
    }

    /// Attach a late-arriving meeting note to whichever queued job spans the
    /// given wall-clock instant. Used when the composer panel was opened during
    /// recording but the user submitted after the meeting had already ended —
    /// the note still belongs in that meeting's transcript. No-op if no
    /// matching job exists, or if the matching job has already passed Stage 5.
    @discardableResult
    public func attachNoteToFinishedJob(at openedAt: Date, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Match the most recent job whose recording window contains openedAt
        // and which hasn't been written out yet.
        let candidate = queueStore.jobs
            .filter { $0.startTime <= openedAt && openedAt <= $0.endTime }
            .filter { $0.stage != .complete && $0.stage != .failed }
            .sorted { $0.startTime > $1.startTime }
            .first
        guard var job = candidate else { return false }
        let offset = max(0, openedAt.timeIntervalSince(job.startTime))
        job.notes.append(MeetingNote(offsetSeconds: offset, text: trimmed))
        queueStore.update(job)
        return true
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
        // Belt-and-braces: if a previous run was cancelled mid-stage (e.g. the
        // task tree was cancelled and `executeWithRetry` exited via
        // `CancellationError` without updating the stage), the job stays in a
        // non-terminal, non-queued stage forever. processingJob would keep
        // returning it and the menu bar header would never clear. Re-queue any
        // such orphans so they get retried; the lifetime-cap check in
        // `executeWithRetry` still prevents infinite reruns of a broken job.
        recoverOrphanedNonTerminalJobs()
        guard let next = queueStore.jobs.first(where: { $0.stage == .queued }) else {
            onPipelineIdle()
            return
        }
        isProcessing = true
        runGeneration += 1
        let generation = runGeneration
        pipelineTask = Task {
            await processWithRetry(next, generation: generation)
            await MainActor.run { [weak self] in
                // Generation check (not isProcessing): if the watchdog aborted
                // this run and a new one is already in flight, isProcessing is
                // true again — clearing it here would clobber the new run's
                // task reference and kick off a duplicate concurrent run.
                guard let self, generation == self.runGeneration else { return }
                self.pipelineTask = nil
                self.isProcessing = false
                self.clearJobState()
                self.runNextIfNeeded()
            }
        }
    }

    private func recoverOrphanedNonTerminalJobs() {
        for job in queueStore.jobs {
            switch job.stage {
            case .complete, .failed, .queued:
                continue
            case .preprocessing, .transcribing, .diarizing, .assigning:
                var recovered = job
                // Charge a retry so a job that gets cancelled mid-stage on every
                // run eventually hits the lifetime cap and stops re-queueing.
                recovered.retryCount += 1
                if recovered.retryCount >= Self.lifetimeRetryLimit {
                    recovered.stage = .failed
                    recovered.error = "Job ended unexpectedly — tap Retry to try again"
                } else {
                    recovered.stage = .queued
                    recovered.stageStartTime = nil
                }
                queueStore.update(recovered)
                NSLog("Heard: Recovered orphaned job \(job.id) from stage \(job.stage) (retryCount=\(recovered.retryCount))")
            }
        }
    }

    /// Called by the watchdog when a pipeline stage has been running too long.
    /// Cancels the current task (best-effort — FluidAudio may not honour the signal
    /// immediately) and immediately marks the stuck job as failed so the UI clears.
    /// Bumping `runGeneration` is the real kill switch: even if the stuck call
    /// eventually returns, the run fails its next generation checkpoint and exits
    /// without touching state that now belongs to a newer run.
    public func abortAndFailCurrentJob() {
        guard isProcessing else { return }
        runGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        if var job = queueStore.processingJob {
            job.stage = .failed
            job.error = "Stage timed out — tap Retry to try again"
            job.stageStartTime = nil
            queueStore.update(job)
        }
        isProcessing = false
        clearJobState()
        // Safe now that stale runs are generation-fenced: pick up the next
        // queued job (or fire onPipelineIdle if there is none) instead of
        // leaving the rest of the queue stalled until the next enqueue.
        runNextIfNeeded()
    }

    private func clearJobState() {
        appTrack = nil
        micTrack = nil
        appTranscription = nil
        micTranscription = nil
        appDiarization = nil
        transcriptionProgress = nil

        // Default keepAlive is 0: unload immediately. Back-to-back meetings don't
        // cause rapid reloads because meeting 2 records while meeting 1's pipeline
        // runs — the gap before reload is always at least meeting 2's remaining duration.
        let keepAlive = TimeInterval(settingsStore.settings.modelKeepAlive * 60)
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

    private func processWithRetry(_ job: PipelineJob, generation: Int) async {
        var working = job
        await Self.executeWithRetry(
            job: &working,
            maxRetries: Self.maxRetries,
            lifetimeRetryLimit: Self.lifetimeRetryLimit,
            retryDelays: Self.retryDelays,
            isNonRetryable: { ($0 as? PipelineError)?.isNonRetryable ?? false },
            // Generation-guarded: a superseded run must not persist queue
            // updates — e.g. its stuck call finally throws and the retry
            // driver's error path would otherwise overwrite the .failed state
            // the watchdog already wrote (or worse, the replacement run's state).
            onUpdate: { [weak self] updated in
                guard let self, generation == self.runGeneration else { return }
                self.queueStore.update(updated)
            },
            sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) },
            process: { [weak self] job in
                guard let self else { throw CancellationError() }
                try self.ensureCurrent(generation)
                try await self.process(&job, generation: generation)
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

    private func process(_ job: inout PipelineJob, generation: Int) async throws {

        // Stage 1: Preprocessing — load WAV, resample to 16kHz mono, Silero VAD trim
        if job.stage == .queued || job.stage == .preprocessing {
            try await advanceTo(&job, stage: .preprocessing)
            modelCatalog.markDownloading(.batchVad)
            try await runPreprocessing(job, generation: generation)
            try ensureCurrent(generation)
            modelCatalog.markReady(.batchVad)
        }

        // Stage 2: Transcription — Parakeet TDT on both tracks
        if job.stage == .preprocessing || job.stage == .transcribing {
            try await advanceTo(&job, stage: .transcribing)
            modelCatalog.markDownloading(.batchParakeet)
            try await runTranscription(job, generation: generation)
            try ensureCurrent(generation)
            modelCatalog.markReady(.batchParakeet)
        }

        // Stage 3: Diarization — LS-EEND + WeSpeaker on both tracks
        if job.stage == .transcribing || job.stage == .diarizing {
            try await advanceTo(&job, stage: .diarizing)
            modelCatalog.markDownloading(.diarization)
            try await runDiarization(job, generation: generation)
            try ensureCurrent(generation)
            modelCatalog.markReady(.diarization)
            // Diarization was the last consumer of the app track's raw audio —
            // speaker assignment and clip extraction only need the vadMap (clips
            // are cut from the original WAV on disk). Free the buffer.
            appTrack = appTrack?.releasingSamples()
        }

        // Stage 4: Speaker Assignment + Output
        if job.stage == .diarizing || job.stage == .assigning {
            try await advanceTo(&job, stage: .assigning)
            let transcript = runSpeakerAssignment(job)
            let outputDirectory = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
            let outputURL = try TranscriptWriter.write(
                document: transcript,
                outputDirectory: outputDirectory
            )

            job.transcriptPath = outputURL
            job.stage = .complete
            job.stageStartTime = nil
            job.error = nil
            queueStore.update(job)

            NSLog("Heard: Pipeline finished → unmatchedSpeakers=\(transcript.unmatchedSpeakers.count), participants=\(transcript.participants.joined(separator: ", "))")
            if !transcript.unmatchedSpeakers.isEmpty {
                // Extract audio clips for each unmatched speaker.
                // Pass VAD speech segments so silence gaps within each clip are skipped,
                // producing continuous speech rather than raw time slices with long pauses.
                let recordingsDir = FileManager.default.heardAppSupportDirectory
                    .appendingPathComponent("recordings", isDirectory: true)
                let vadSegments = appTrack?.vadMap.mappings.map {
                    (startTime: $0.originalStart, endTime: $0.originalEnd)
                } ?? []
                let clips = AudioClipExtractor.extractSpeakerClips(
                    unmatchedSpeakers: transcript.unmatchedSpeakers,
                    diarizationSegments: transcript.diarizationSegments,
                    speechSegments: appTrack?.vadMap.mappings.map {
                        (startTime: $0.originalStart, endTime: $0.originalEnd)
                    },
                    sourceAudioURL: job.appAudioPath,
                    outputDirectory: recordingsDir,
                    vadSpeechSegments: vadSegments
                )

                // A candidate the user can't listen to can't be identified — and a
                // placeholder profile is excluded from voice matching, so persisting one
                // without audio would only clutter the Speakers list. Drop clipless
                // speakers here; their transcript keeps the "Speaker N" label.
                let audible = clips.filter { !$0.clips.isEmpty }
                for silent in clips where silent.clips.isEmpty {
                    NSLog("Heard: Skipping naming candidate '\(silent.speaker.temporaryName)' — no playable clip could be extracted")
                }

                // Build candidates with audio clips, embeddings, and roster suggestions.
                // Every candidate gets the full unmatched-roster list — with several
                // unknown voices there is no reliable way to pre-pair a specific name
                // to a specific voice, so the prompt offers all of them as tappable
                // chips and the user picks by ear.
                let candidates = audible.map { item in
                    NamingCandidate(
                        id: UUID(),
                        temporaryName: item.speaker.temporaryName,
                        suggestedNames: transcript.unmatchedRosterNames,
                        audioClipURLs: item.clips.map(\.url),
                        embedding: item.speaker.embedding,
                        clipEmbeddings: perClipEmbeddings(
                            speakerID: item.speaker.speakerID,
                            regions: item.clips.map { (startTime: $0.startTime, endTime: $0.endTime) }
                        ),
                        transcriptPath: outputURL,
                        totalMeetingDuration: item.speaker.totalMeetingDuration,
                        totalWordCount: item.speaker.totalWordCount,
                        totalSpeakingTime: item.speaker.totalSpeakingTime
                    )
                }
                if !candidates.isEmpty {
                    NSLog("Heard: Triggering naming prompt for \(candidates.count) candidate(s)")
                    onNamingRequired(candidates)
                }
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

    private func runPreprocessing(_ job: PipelineJob, generation: Int) async throws {
        let fm = FileManager.default
        let appExists = fm.fileExists(atPath: job.appAudioPath.path)
        let micExists = fm.fileExists(atPath: job.micAudioPath.path)

        guard appExists || micExists else { throw PipelineError.noAudioFiles }

        // Skip files that are too small to contain meaningful audio (< 1KB)
        let appUsable = appExists && (try? fm.attributesOfItem(atPath: job.appAudioPath.path)[.size] as? Int).flatMap({ $0 > 1024 }) ?? false
        let micUsable = micExists && (try? fm.attributesOfItem(atPath: job.micAudioPath.path)[.size] as? Int).flatMap({ $0 > 1024 }) ?? false

        guard appUsable || micUsable else { throw PipelineError.noAudioFiles }

        if settingsStore.settings.effectiveLowMemory {
            // Serialize preprocessing to halve peak RAM (~400 MB instead of ~800 MB)
            if appUsable {
                let track = try await AudioPreprocessor.preprocess(wavURL: job.appAudioPath)
                try ensureCurrent(generation)
                appTrack = track
            }
            if micUsable {
                let track = try await AudioPreprocessor.preprocess(wavURL: job.micAudioPath)
                try ensureCurrent(generation)
                micTrack = track
            }
        } else {
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
                    try ensureCurrent(generation)
                    if label == "app" { appTrack = track }
                    else { micTrack = track }
                }
            }
        }
    }

    // MARK: - Stage 2: Transcription

    private func runTranscription(_ job: PipelineJob, generation: Int) async throws {
        // Cancel any pending unload — we're using the models now
        modelUnloadTask?.cancel()
        modelUnloadTask = nil

        let selectedVersion = settingsStore.settings.transcriptionModel

        // Reuse cached models if available and the same version; otherwise load fresh.
        // Each transcribe() call uses its own fresh TdtDecoderState, so no stale context
        // from prior jobs/tracks bleeds in.
        let asrManager: AsrManager
        if let cached = cachedAsrManager, cachedAsrVersion == selectedVersion {
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
            try ensureCurrent(generation)
            asrManager = manager
            cachedAsrModels = models
            cachedAsrManager = manager
            cachedAsrVersion = selectedVersion
        }

        // Minimum 16,000 samples (1 second at 16kHz) required by Parakeet
        let minSamples = 16_000

        // v3 emits Cyrillic for short Latin utterances unless given a language hint;
        // v2 ignores this parameter. Heard is English-only per spec.
        let language: Language = .english

        // Weight progress by sample count so the bar advances proportionally to work done.
        let appCount = appTrack.flatMap { $0.samples.count >= minSamples ? $0.samples.count : nil } ?? 0
        let micCount = micTrack.flatMap { $0.samples.count >= minSamples ? $0.samples.count : nil } ?? 0
        let totalTranscribeSamples = appCount + micCount
        transcriptionProgress = totalTranscribeSamples > 0 ? 0.0 : nil

        // Transcribe app track (remote participants) with a fresh decoder state.
        if let track = appTrack, track.samples.count >= minSamples {
            var decoderState = TdtDecoderState.make()
            let result = try await asrManager.transcribe(
                track.samples, decoderState: &decoderState, language: language
            )
            try ensureCurrent(generation)
            appTranscription = result
            if totalTranscribeSamples > 0 {
                transcriptionProgress = Double(appCount) / Double(totalTranscribeSamples)
            }
        }

        // Transcribe mic track (local user) with its own fresh decoder state.
        if let track = micTrack, track.samples.count >= minSamples {
            var decoderState = TdtDecoderState.make()
            let result = try await asrManager.transcribe(
                track.samples, decoderState: &decoderState, language: language
            )
            try ensureCurrent(generation)
            micTranscription = result
        }

        transcriptionProgress = nil  // clear before vocabulary boosting / next stage

        // Apply CTC-based custom vocabulary boosting as post-processing. Best-effort —
        // never fails the job; original transcripts are kept on any error.
        await applyVocabularyBoosting(generation: generation)
        try ensureCurrent(generation)

        // Apply custom formatting commands
        TextNormalizer.shared.clearRules()
        for cmd in settingsStore.settings.formattingCommands {
            TextNormalizer.shared.addRule(spoken: cmd.spoken, written: cmd.written)
        }

        // Apply Inverse Text Normalization (punctuation and number formatting)
        if let result = appTranscription {
            appTranscription = TextNormalizer.shared.normalize(result: result)
        }
        if let result = micTranscription {
            micTranscription = TextNormalizer.shared.normalize(result: result)
        }

        // The mic track is never diarized — transcription (incl. vocab boosting)
        // was its last audio consumer, so free the sample buffer now. Done only
        // on the success path so a within-session retry still has the samples.
        micTrack = micTrack?.releasingSamples()

        // Models stay cached for keep-alive; unloaded by clearJobState() or forceUnload()
    }

    /// Post-process ASRResults with CTC vocabulary rescoring.
    ///
    /// FluidAudio 0.13.6+ removed `configureVocabularyBoosting` from batch `AsrManager`.
    /// The supported migration runs `CtcKeywordSpotter` over the same audio to compute
    /// log-probs, then asks `VocabularyRescorer.ctcTokenRescore` to rewrite low-confidence
    /// words against the user's vocabulary. Skipped silently when the user has no terms
    /// or the CTC 110M model isn't downloaded — the Models tab gates that download.
    private func applyVocabularyBoosting(generation: Int) async {
        let terms = settingsStore.settings.customVocabulary
        guard !terms.isEmpty else { return }

        let ctcDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: ctcDir) else {
            NSLog("Heard: Custom vocabulary set (%d terms) but CTC 110M not downloaded — skipping boost", terms.count)
            return
        }

        do {
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: ctcDir)
            let vocabularyTerms = terms.map { term -> CustomVocabularyTerm in
                let tokenIds = tokenizer.encode(term)
                return CustomVocabularyTerm(
                    text: term,
                    weight: 10.0,
                    ctcTokenIds: tokenIds.isEmpty ? nil : tokenIds
                )
            }
            let context = CustomVocabularyContext(terms: vocabularyTerms)
            let spotter = CtcKeywordSpotter(models: ctcModels)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: context,
                ctcModelDirectory: ctcDir
            )

            if let track = appTrack, let result = appTranscription {
                let rescored = await rescore(
                    result: result, samples: track.samples,
                    vocabulary: context, spotter: spotter, rescorer: rescorer
                )
                guard generation == runGeneration else { return }
                appTranscription = rescored
            }
            if let track = micTrack, let result = micTranscription {
                let rescored = await rescore(
                    result: result, samples: track.samples,
                    vocabulary: context, spotter: spotter, rescorer: rescorer
                )
                guard generation == runGeneration else { return }
                micTranscription = rescored
            }
        } catch {
            NSLog("Heard: Vocab boost setup failed — keeping original transcript: %@", error.localizedDescription)
        }
    }

    private func rescore(
        result: ASRResult,
        samples: [Float],
        vocabulary: CustomVocabularyContext,
        spotter: CtcKeywordSpotter,
        rescorer: VocabularyRescorer
    ) async -> ASRResult {
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            return result
        }
        do {
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: vocabulary
            )
            let rescored = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration
            )
            guard rescored.wasModified else { return result }

            let detected = spot.detections.map(\.term.text)
            let applied = rescored.replacements
                .filter(\.shouldReplace)
                .compactMap(\.replacementWord)
            return result.withRescoring(text: rescored.text, detected: detected, applied: applied)
        } catch {
            NSLog("Heard: Vocab rescoring failed — keeping original transcript: %@", error.localizedDescription)
            return result
        }
    }

    // MARK: - Stage 3: Diarization (LS-EEND + WeSpeaker)
    //
    // Upgrade path: FluidAudio also provides SortformerDiarizer (~11% DER vs ~17.7% here).
    // Sortformer is blocked by an embedding gap — its DiarizerTimeline contains no per-segment
    // speaker embeddings, which the SpeakerAssigner needs for cross-meeting identity.
    // To adopt it: run Sortformer for segmentation, then extract WeSpeaker embeddings on each
    // segment, and convert to DiarizationResult before passing downstream.

    private func runDiarization(_ job: PipelineJob, generation: Int) async throws {
        // Diarization only applies to the app track (remote speakers).
        // The mic track is a single known speaker (the local user) so diarization adds no value.
        let minSamples = 16_000 * 2 // 2 seconds at 16kHz

        guard let track = appTrack, track.samples.count >= minSamples else {
            // Too short or missing — skip, speaker assignment will use defaults
            return
        }

        // FluidAudio's clusteringThreshold is a cosine *similarity* (despite the
        // name) — AHC merges when cos_sim ≥ threshold. Higher = stricter
        // separation (more clusters); lower = more merging. The Speakers tab
        // supports merging, but recovering from a merged embedding is harder,
        // so we default to stricter than FluidAudio's 0.6.
        let similarity = settingsStore.settings.diarizationClusteringSimilarity
        var config = OfflineDiarizerConfig(clusteringThreshold: similarity)
        // Surface per-chunk speaker embeddings so speaker assignment can build a robust
        // duration-weighted centroid per speaker instead of relying on one arbitrary
        // segment. Off by default in FluidAudio (~1–2 MB/hour of audio); negligible here.
        config.exposeChunkEmbeddings = true
        let diarizer = OfflineDiarizerManager(config: config)
        try await diarizer.prepareModels()
        let result = try await diarizer.process(audio: track.samples)
        try ensureCurrent(generation)
        appDiarization = result

        // Models are released when diarizer goes out of scope
    }

    /// One embedding per remote speaker, used for matching against the persistent
    /// speaker database and for any profiles created this meeting.
    ///
    /// Prefers a duration-weighted centroid over every per-chunk embedding
    /// (`DiarizationResult.chunkEmbeddings`, FluidAudio 0.14.8+), which is far more
    /// stable than any single window. Falls back to the legacy "first segment per
    /// speaker" embedding when chunk embeddings are unavailable — e.g. very short audio
    /// or a model build that doesn't surface them. Results are sorted by speaker ID so
    /// greedy matching in `SpeakerMatcher` stays deterministic.
    private func buildSpeakerEmbeddings(from result: DiarizationResult) -> [SpeakerEmbedding] {
        if let chunks = result.chunkEmbeddings, !chunks.isEmpty {
            var grouped: [String: [SpeakerEmbeddingAggregator.Chunk]] = [:]
            for chunk in chunks where !chunk.embedding256.isEmpty {
                let seconds = Float(chunk.endTimeSeconds - chunk.startTimeSeconds)
                let weight = seconds > 0 ? seconds : 1  // guard zero-length windows
                grouped["R_\(chunk.speakerId)", default: []].append(
                    .init(vector: chunk.embedding256, weight: weight)
                )
            }
            let centroids = SpeakerEmbeddingAggregator.centroids(perSpeaker: grouped)
            if !centroids.isEmpty {
                NSLog("Heard: built \(centroids.count) speaker centroid(s) from \(chunks.count) chunk embedding(s)")
                return centroids
                    .sorted { $0.key < $1.key }
                    .map { SpeakerEmbedding(speakerID: $0.key, vector: $0.value) }
            }
        }

        // Fallback: first per-segment embedding per speaker (pre-0.15 behavior).
        NSLog("Heard: chunk embeddings unavailable — using per-segment embeddings")
        var seen = Set<String>()
        var fallback: [SpeakerEmbedding] = []
        for seg in result.segments where !seg.embedding.isEmpty {
            let id = "R_\(seg.speakerId)"
            if seen.insert(id).inserted {
                fallback.append(SpeakerEmbedding(speakerID: id, vector: seg.embedding))
            }
        }
        return fallback
    }

    /// One embedding per extracted voice clip, aggregated from the diarizer chunk
    /// embeddings that overlap the clip's original-time region. Chunk times are in the
    /// preprocessed (VAD-trimmed) timebase, so they're mapped through the app track's
    /// `VadSegmentMap` before overlap is computed — the same mapping used for the
    /// diarization segments themselves. Returns an empty vector for a clip when no
    /// chunk overlaps it (or when chunk embeddings are unavailable entirely), so the
    /// result is always parallel to `regions`.
    private func perClipEmbeddings(
        speakerID: String,
        regions: [(startTime: TimeInterval, endTime: TimeInterval)]
    ) -> [[Float]] {
        guard let chunks = appDiarization?.chunkEmbeddings, !chunks.isEmpty else {
            return regions.map { _ in [] }
        }
        let speakerChunks = chunks.filter { "R_\($0.speakerId)" == speakerID && !$0.embedding256.isEmpty }
        guard !speakerChunks.isEmpty else { return regions.map { _ in [] } }

        let vadMap = appTrack?.vadMap
        return regions.map { region in
            var overlapping: [SpeakerEmbeddingAggregator.Chunk] = []
            for chunk in speakerChunks {
                let start = vadMap?.toOriginalTime(TimeInterval(chunk.startTimeSeconds)) ?? TimeInterval(chunk.startTimeSeconds)
                let end = vadMap?.toOriginalTime(TimeInterval(chunk.endTimeSeconds)) ?? TimeInterval(chunk.endTimeSeconds)
                let overlap = min(end, region.endTime) - max(start, region.startTime)
                if overlap > 0 {
                    overlapping.append(.init(vector: chunk.embedding256, weight: Float(overlap)))
                }
            }
            return SpeakerEmbeddingAggregator.centroid(of: overlapping) ?? []
        }
    }

    /// Extract up to two voice samples for a speaker directly into the persistent
    /// `speaker_clips/` directory. Used for profiles created without going through the
    /// naming prompt (roster auto-assignment), whose clips would otherwise never exist.
    private func extractProfileClips(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        sourceAudioURL: URL
    ) -> [URL] {
        let speechSegments = appTrack?.vadMap.mappings.map {
            (startTime: $0.originalStart, endTime: $0.originalEnd)
        }
        let regions = AudioClipExtractor.bestClipRegions(
            speakerID: speakerID,
            diarizationSegments: diarizationSegments,
            speechSegments: speechSegments,
            maxCount: 2
        )
        guard !regions.isEmpty else { return [] }

        let clipsDir = FileManager.default.heardSpeakerClipsDirectory
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)

        var saved: [URL] = []
        for region in regions {
            let clipURL = clipsDir.appendingPathComponent("clip_\(UUID().uuidString.prefix(8)).wav")
            if let url = AudioClipExtractor.extractClip(
                from: sourceAudioURL,
                startTime: region.startTime,
                endTime: region.endTime,
                outputURL: clipURL,
                vadSpeechSegments: speechSegments ?? []
            ) {
                saved.append(url)
            }
        }
        return saved
    }

    // MARK: - Stage 4: Speaker Assignment

    private func runSpeakerAssignment(_ job: PipelineJob) -> TranscriptDocument {
        let me = settingsStore.settings.userName.isEmpty ? "Me" : settingsStore.settings.userName

        // Build transcription segments from ASR results with timestamp remapping
        var appSegments: [TranscriptSegment] = []
        var micSegments: [TranscriptSegment] = []

        // App track segments (remote participants)
        if let asr = appTranscription, let track = appTrack, let timings = asr.tokenTimings {
            appSegments = buildSegmentsFromTimings(timings, vadMap: track.vadMap, defaultSpeaker: "Remote")
        } else if let asr = appTranscription, let track = appTrack, !asr.text.isEmpty {
            appSegments = [TranscriptSegment(
                speaker: "Remote",
                startTime: 0,
                endTime: track.duration,
                text: asr.text
            )]
        }

        // Mic track segments (local user)
        if let asr = micTranscription, let track = micTrack, let timings = asr.tokenTimings {
            micSegments = buildSegmentsFromTimings(timings, vadMap: track.vadMap, defaultSpeaker: me)
        } else if let asr = micTranscription, let track = micTrack, !asr.text.isEmpty {
            micSegments = [TranscriptSegment(
                speaker: me,
                startTime: 0,
                endTime: track.duration,
                text: asr.text
            )]
        }

        // Drop mic segments that duplicate app segments via speaker bleed
        // (e.g. user is on laptop speakers and the mic picks up remote audio).
        let micBefore = micSegments.count
        micSegments = SegmentDeduplicator.dropMicBleed(
            appSegments: appSegments,
            micSegments: micSegments,
            micDelaySeconds: job.micDelaySeconds
        )
        let dropped = micBefore - micSegments.count
        if dropped > 0 {
            NSLog("Heard: dedup dropped \(dropped) mic segment(s) of \(micBefore) as bleed")
        }

        var allSegments: [TranscriptSegment] = appSegments + micSegments

        // Apply diarization speaker labels
        var unmatchedSpeakerInfo: [UnmatchedSpeaker] = []
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

            // One robust embedding per speaker for cross-meeting identity.
            let uniqueEmbeddings = buildSpeakerEmbeddings(from: appDiar)

            let matches = SpeakerMatcher.matchSpeakers(
                embeddings: uniqueEmbeddings,
                database: speakerStore.speakers,
                localUserName: me,
                matchThreshold: Float(settingsStore.settings.speakerMatchThreshold)
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
                } else {
                    // Two or more unknown voices: pairing sorted roster names to diarizer
                    // cluster order would be a coin flip that silently writes wrong
                    // name↔voice pairs into transcripts and poisons the speaker database
                    // with mislabeled embeddings. Pass the names as suggestions instead —
                    // the naming prompt lets the user confirm each one by ear.
                    unmatchedRosterNamesForPrompt = unmatchedRosterNames.sorted()
                }
            }

            // Collect unmatched speaker info for naming prompt
            let stillUnmatched = matches.filter { $0.isNewSpeaker && nameMap[$0.detectedSpeakerID]?.hasPrefix("Speaker_") ?? true }
            unmatchedSpeakerInfo = stillUnmatched.map {
                UnmatchedSpeaker(
                    speakerID: $0.detectedSpeakerID,
                    temporaryName: nameMap[$0.detectedSpeakerID] ?? $0.assignedName,
                    embedding: $0.embedding
                )
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
                // These profiles bypass the naming prompt (which is where clips are
                // normally attached), so extract a voice sample here — straight into
                // the persistent speaker_clips directory — or the profile would sit
                // in the Speakers list with a dead play button forever.
                let clipURLs = extractProfileClips(
                    speakerID: match.detectedSpeakerID,
                    diarizationSegments: diarSegTuples,
                    sourceAudioURL: job.appAudioPath
                )
                let profile = SpeakerProfile(
                    id: UUID(),
                    name: resolvedName,
                    embeddings: [match.embedding],
                    firstSeen: Date(),
                    lastSeen: Date(),
                    meetingCount: 1,
                    audioClipURLs: clipURLs
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

        // Calculate stats
        let meetingDuration = finalSegments.last?.endTime ?? 0
        var wordsPerSpeaker: [String: Int] = [:]
        for segment in finalSegments {
            let words = segment.text.split(whereSeparator: { $0.isWhitespace }).count
            wordsPerSpeaker[segment.speaker, default: 0] += words
        }
        // Speaking time from the pre-merge segments: mergeConsecutive extends a
        // block's endTime across the silence between same-speaker sentences, so the
        // merged segments would overcount. Sentence-level durations are the honest
        // approximation of time actually spent talking.
        var speakingPerSpeaker: [String: TimeInterval] = [:]
        for segment in allSegments {
            speakingPerSpeaker[segment.speaker, default: 0] += max(0, segment.endTime - segment.startTime)
        }

        // Apply to existing known speakers (batched — one disk write)
        let statUpdates = speakerStore.speakers
            .filter { segmentSpeakers.contains($0.name) }
            .map { (id: $0.id,
                    addDuration: meetingDuration,
                    addWords: wordsPerSpeaker[$0.name] ?? 0,
                    addSpeaking: speakingPerSpeaker[$0.name] ?? 0) }
        speakerStore.updateStats(statUpdates)

        // Apply to unmatched speakers
        for i in unmatchedSpeakerInfo.indices {
            let name = unmatchedSpeakerInfo[i].temporaryName
            unmatchedSpeakerInfo[i].totalMeetingDuration = meetingDuration
            unmatchedSpeakerInfo[i].totalWordCount = wordsPerSpeaker[name] ?? 0
            unmatchedSpeakerInfo[i].totalSpeakingTime = speakingPerSpeaker[name] ?? 0
        }

        let userName = settingsStore.settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptDocument(
            title: job.meetingTitle.isEmpty ? "Meeting" : job.meetingTitle,
            startTime: job.startTime,
            endTime: job.endTime,
            participants: allParticipants,
            segments: finalSegments,
            unmatchedSpeakers: unmatchedSpeakerInfo,
            diarizationSegments: diarSegTuples,
            unmatchedRosterNames: unmatchedRosterNamesForPrompt,
            notes: job.notes,
            noteAuthor: userName.isEmpty ? "Me" : userName
        )
    }
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
