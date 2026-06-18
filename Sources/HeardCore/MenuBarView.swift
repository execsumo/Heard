import AVFoundation
import SwiftUI

// MARK: - Menu Bar Dropdown

public struct MenuBarView: View {
    @ObservedObject public var model: AppModel
    // MenuBarExtra(.window) does not reliably re-render from forwarded child-store
    // objectWillChange events, so observe each store the dropdown reads from
    // directly. Otherwise the status header stays stuck on "Processing" after
    // jobs finish and the Recent Transcripts list never appears.
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var queueStore: PipelineQueueStore
    @ObservedObject private var recordingManager: RecordingManager
    @ObservedObject private var pipelineProcessor: PipelineProcessor
    @ObservedObject private var meetingDetector: MeetingDetector
    @ObservedObject private var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
        self.settingsStore = model.settingsStore
        self.queueStore = model.queueStore
        self.recordingManager = model.recordingManager
        self.pipelineProcessor = model.pipelineProcessor
        self.meetingDetector = model.meetingDetector
        self.updateChecker = model.updateChecker
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pinned top — banners and status header always visible
            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }
            if model.dictationAXLost {
                axLostBanner
            }
            if recordingManager.appAudioTapFailed && recordingManager.activeSession != nil {
                tapFailedBanner
            }
            if recordingManager.micCaptureFailed && recordingManager.activeSession != nil {
                micFailedBanner
            }

            statusHeader
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            HeardTheme.Paper.borderSoft.frame(height: 0.5)

            // Action rows — rendered directly (no ScrollView) so they always
            // size to their natural content height. Wrapping them in a
            // ScrollView inside MenuBarExtra(.window) caused the whole middle
            // section to collapse to zero height in some layout passes.
            VStack(spacing: 1) {
                if let version = updateChecker.availableVersion, let url = updateChecker.releaseURL {
                    MenuBarRow(title: "Update available — v\(version)", icon: "arrow.down.circle.fill", accent: true) {
                        NSWorkspace.shared.open(url)
                    }
                }

                if settingsStore.settings.developerMode {
                    if recordingManager.activeSession == nil {
                        MenuBarRow(title: "Simulate Meeting", icon: "bolt.circle") {
                            model.simulateMeeting()
                        }
                    } else {
                        MenuBarRow(title: "End Simulation", icon: "stop.circle") {
                            model.endSimulatedMeeting()
                        }
                    }
                }

                if !model.namingCandidates.isEmpty {
                    MenuBarRow(title: "Name Speakers…", icon: "person.badge.plus", accent: true) {
                        openWindow(id: "speaker-naming")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }

                if recordingManager.activeSession == nil && !meetingDetector.isWatching {
                    MenuBarRow(title: "Start Recording", icon: "record.circle") {
                        model.startManualRecording()
                    }
                } else if recordingManager.activeSession != nil && !meetingDetector.isWatching {
                    MenuBarRow(title: "Stop Recording", icon: "stop.circle") {
                        model.stopManualRecording()
                    }
                }

                if recordingManager.activeSession != nil {
                    MenuBarRow(
                        title: "Add Note…",
                        icon: "square.and.pencil",
                        hotkey: settingsStore.settings.meetingNoteHotkey.displayString
                    ) {
                        model.presentMeetingNoteComposer()
                    }
                }

                if settingsStore.settings.dictationEnabled && !model.isDictating
                    && recordingManager.activeSession == nil {
                    MenuBarRow(
                        title: "Start Dictation",
                        icon: "mic.badge.plus",
                        hotkey: settingsStore.settings.dictationHotkey.displayString
                    ) {
                        model.toggleDictation()
                    }
                } else if settingsStore.settings.dictationEnabled && model.isDictating {
                    MenuBarRow(
                        title: "Stop Dictation",
                        icon: "mic.slash",
                        hotkey: settingsStore.settings.dictationHotkey.displayString
                    ) {
                        model.toggleDictation()
                    }
                }

                MenuBarRow(title: "Open Transcripts", icon: "folder") {
                    model.openOutputDirectory()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            // Recent Transcripts — rendered directly (no ScrollView) so the
            // section expands to show all rows naturally, matching the approach
            // used for action rows above. recentTranscripts is already capped at 3.
            if !queueStore.recentTranscripts.isEmpty {
                HeardTheme.Paper.borderSoft.frame(height: 0.5)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent Transcripts")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(HeardTheme.Paper.mute)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(queueStore.recentTranscripts) { job in
                            JobRow(job: job, model: model)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Pinned bottom — always reachable
            HeardTheme.Paper.borderSoft.frame(height: 0.5)

            VStack(spacing: 1) {
                MenuBarRow(title: "Settings…", icon: "gearshape") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuBarRow(title: "Quit Heard", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 268)
        .background(HeardTheme.Paper.bg)
        .onChange(of: model.showNamingPrompt) { _, show in
            NSLog("Heard: MenuBarView observed showNamingPrompt=\(show)")
            if show {
                openWindow(id: "speaker-naming")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onChange(of: model.namingCandidates.isEmpty) { wasEmpty, isEmpty in
            if wasEmpty && !isEmpty {
                NSLog("Heard: MenuBarView observed namingCandidates became non-empty (\(model.namingCandidates.count))")
                openWindow(id: "speaker-naming")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: Status Header

    @ViewBuilder
    private var statusHeader: some View {
        if let session = recordingManager.activeSession {
            let tapFailed = recordingManager.appAudioTapFailed
            let micFailed = recordingManager.micCaptureFailed
            StatusHeaderCard(
                dotColor: HeardTheme.Paper.bad,
                pulsing: true,
                title: tapFailed ? "Recording (mic only)" : (micFailed ? "Recording (no mic)" : "Recording"),
                subtitle: tapFailed
                    ? "No system audio — check Screen Recording"
                    : micFailed
                        ? "Mic capture failed — check input device"
                        : (session.title.isEmpty ? "Meeting" : session.title),
                dark: true,
                trailing: AnyView(
                    RecordingTimerView(startTime: session.startTime)
                        .monospacedDigit()
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(HeardTheme.Paper.recordingInk.opacity(0.7))
                )
            )
        } else if pipelineProcessor.isProcessing, let job = queueStore.processingJob {
            // Only show the Processing card when the processor is actually running.
            // A non-terminal job left in the queue with no active processor (e.g. after
            // a cancellation that didn't mark it failed) used to stick the header on
            // "Processing" forever even though the transcript was already written.
            StatusHeaderCard(
                dotColor: HeardTheme.Paper.warn,
                pulsing: true,
                title: "Processing",
                subtitle: processingSubtitle(for: job),
                dark: false,
                trailing: nil
            )
        } else if model.phase == .processing && pipelineProcessor.isProcessing {
            StatusHeaderCard(
                dotColor: HeardTheme.Paper.warn,
                pulsing: true,
                title: "Processing",
                subtitle: "Preparing transcription…",
                dark: false,
                trailing: nil
            )
        } else if model.isDictating {
            StatusHeaderCard(
                dotColor: HeardTheme.Paper.bad,
                pulsing: true,
                title: "Dictating",
                subtitle: "Listening…",
                dark: true,
                trailing: nil
            )
        } else {
            Button { model.toggleWatching() } label: {
                StatusHeaderCard(
                    dotColor: meetingDetector.isWatching ? HeardTheme.Paper.good : HeardTheme.Paper.warn,
                    pulsing: false,
                    title: meetingDetector.isWatching ? "Watching" : "Paused",
                    subtitle: meetingDetector.isWatching ? "Waiting for meeting" : "Click to resume",
                    dark: false,
                    trailing: nil
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func processingSubtitle(for job: PipelineJob) -> String {
        switch job.stage {
        case .queued:        return "Queued — preparing to transcribe"
        case .preprocessing: return "Preprocessing audio"
        case .transcribing:
            if let p = pipelineProcessor.transcriptionProgress {
                return "Transcribing — \(Int(p * 100))%"
            }
            return "Transcribing"
        case .diarizing:     return "Identifying speakers"
        case .assigning:     return "Matching speakers"
        case .complete, .failed: return job.stage.displayName
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeardTheme.Paper.bad)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(HeardTheme.Paper.ink)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Dismiss") { model.acknowledgeError() }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(HeardTheme.Paper.accent)
        }
        .padding(10)
        .background(HeardTheme.Paper.badSoft, in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var axLostBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeardTheme.Paper.warn)
                .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility access was revoked. Dictation text injection stopped.")
                    .font(.caption)
                    .foregroundStyle(HeardTheme.Paper.ink)
                    .lineLimit(3)
                Button("Re-grant Access…") {
                    TextInjector.ensureAccessibility()
                    model.acknowledgeAXLost()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(HeardTheme.Paper.accent)
            }
            Spacer(minLength: 4)
            Button("Dismiss") { model.acknowledgeAXLost() }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(HeardTheme.Paper.mute)
        }
        .padding(10)
        .background(HeardTheme.Paper.warnSoft, in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var tapFailedBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeardTheme.Paper.warn)
                .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text("System audio tap failed. Recording only your voice.")
                    .font(.caption)
                    .foregroundStyle(HeardTheme.Paper.ink)
                    .lineLimit(3)
                Text("Verify Screen Recording permission in System Settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(HeardTheme.Paper.warnSoft, in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var micFailedBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeardTheme.Paper.warn)
                .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mic capture failed. Recording only the other participants.")
                    .font(.caption)
                    .foregroundStyle(HeardTheme.Paper.ink)
                    .lineLimit(3)
                Text("Check the input device in Settings → General and the Microphone permission.")
                    .font(.system(size: 10))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }
            Spacer(minLength: 4)
        }
        .padding(10)
        .background(HeardTheme.Paper.warnSoft, in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

// MARK: - Menu Bar Components
struct StatusHeaderCard: View {
    let dotColor: Color
    let pulsing: Bool
    let title: String
    let subtitle: String
    var dark: Bool = false
    let trailing: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: dotColor, pulsing: pulsing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? HeardTheme.Paper.recordingInk : HeardTheme.Paper.ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(dark ? HeardTheme.Paper.recordingInk.opacity(0.65) : HeardTheme.Paper.mute)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HeardTheme.Radius.card)
                .fill(dark ? HeardTheme.Paper.recordingBg : HeardTheme.Paper.surfaceAlt)
        )
        .contentShape(RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
    }
}
struct MenuBarRow: View {
    let title: String
    let icon: String
    var accent: Bool = false
    var hotkey: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(accent ? HeardTheme.Paper.accent : HeardTheme.Paper.ink2)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent ? HeardTheme.Paper.accent : HeardTheme.Paper.ink)
                Spacer()
                if let hotkey {
                    Text(hotkey)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HeardTheme.Paper.mute)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(MenuBarRowStyle())
    }
}
struct MenuBarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? HeardTheme.Paper.surfaceAlt : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}
struct JobRow: View {
    let job: PipelineJob
    @ObservedObject var model: AppModel

    var body: some View {
        Button(action: {
            if job.stage == .complete { model.openTranscript(job) }
        }) {
            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.meetingTitle.isEmpty ? "Meeting" : job.meetingTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HeardTheme.Paper.ink)
                        .lineLimit(1)
                    Text(job.startTime.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(HeardTheme.Paper.mute)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(MenuBarRowStyle())
        .contextMenu {
            if job.stage == .complete {
                Button("Reveal in Finder") {
                    if let url = job.transcriptPath {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            } else if job.stage == .failed {
                Button("Retry") { model.retry(job) }
            }
            Button("Dismiss") { model.dismissJob(job) }
        }
    }

    private var iconName: String {
        switch job.stage {
        case .complete: return "doc.text.fill"
        case .failed:   return "exclamationmark.triangle.fill"
        default:        return "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch job.stage {
        case .complete: return HeardTheme.Paper.mute
        case .failed:   return HeardTheme.Paper.bad
        default:        return HeardTheme.Paper.warn
        }
    }
}

// MARK: - Recording Timer

public struct RecordingTimerView: View {
    public let startTime: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(startTime: Date) { self.startTime = startTime }

    public var body: some View {
        Text(formatDuration(elapsed))
            .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(startTime) }
            .onAppear { elapsed = Date().timeIntervalSince(startTime) }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

/// Kept for public API compatibility.
public struct PulsingDot: View {
    var size: CGFloat = 8
    public init(size: CGFloat = 8) { self.size = size }
    public var body: some View {
        StatusDot(color: HeardTheme.Paper.bad, pulsing: true)
            .frame(width: size, height: size)
    }
}

