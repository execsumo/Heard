import AVFoundation
import SwiftUI

// MARK: - Theme

enum HeardTheme {
    /// Respects the user's System Settings accent color.
    static var accent: Color { .accentColor }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        static let inline: CGFloat = 6
        static let card: CGFloat = 10
        static let hero: CGFloat = 14
    }
}

// MARK: - Menu Bar Dropdown

public struct MenuBarView: View {
    @ObservedObject public var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            }

            statusHeader
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            VStack(spacing: 1) {
                if model.settingsStore.settings.developerMode {
                    if model.recordingManager.activeSession == nil {
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

                if model.settingsStore.settings.dictationEnabled && !model.isDictating {
                    MenuBarRow(title: "Start Dictation", icon: "mic.badge.plus") {
                        model.toggleDictation()
                    }
                }

                MenuBarRow(title: "Open Transcripts", icon: "folder") {
                    model.openOutputDirectory()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            Divider()

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
        .frame(width: 260)
        .onChange(of: model.showNamingPrompt) { _, show in
            if show {
                openWindow(id: "speaker-naming")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: Status Header

    @ViewBuilder
    private var statusHeader: some View {
        if let session = model.recordingManager.activeSession {
            let tapFailed = model.recordingManager.appAudioTapFailed
            StatusHeaderCard(
                dotColor: .red,
                pulsing: true,
                title: tapFailed ? "Recording (mic only)" : "Recording",
                titleColor: .red,
                subtitle: tapFailed
                    ? "No system audio — check Screen Recording permission"
                    : (session.title.isEmpty ? "Meeting" : session.title),
                trailing: AnyView(
                    RecordingTimerView(startTime: session.startTime)
                        .monospacedDigit()
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                )
            )
        } else if let job = model.queueStore.activeJob, job.stage != .complete && job.stage != .failed {
            StatusHeaderCard(
                dotColor: .orange,
                pulsing: true,
                title: "Processing",
                titleColor: .orange,
                subtitle: job.stage.displayName,
                trailing: nil
            )
        } else if model.isDictating {
            StatusHeaderCard(
                dotColor: .red,
                pulsing: true,
                title: "Dictating",
                titleColor: .red,
                subtitle: model.partialTranscript.isEmpty ? "Listening…" : String(model.partialTranscript.suffix(60)),
                trailing: nil
            )
        } else {
            // Idle: tappable Watching/Paused toggle
            Button {
                model.toggleWatching()
            } label: {
                StatusHeaderCard(
                    dotColor: model.meetingDetector.isWatching ? .green : .yellow,
                    pulsing: false,
                    title: model.meetingDetector.isWatching ? "Watching" : "Paused",
                    titleColor: .primary,
                    subtitle: model.meetingDetector.isWatching ? "Waiting for Teams meeting" : "Click to resume",
                    trailing: nil
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Dismiss") { model.acknowledgeError() }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(HeardTheme.accent)
        }
        .padding(10)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

// MARK: - Menu Bar Components

private struct StatusHeaderCard: View {
    let dotColor: Color
    let pulsing: Bool
    let title: String
    let titleColor: Color
    let subtitle: String
    let trailing: AnyView?

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: dotColor, pulsing: pulsing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.callout, design: .default).weight(.semibold))
                    .foregroundStyle(titleColor)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let trailing = trailing {
                trailing
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
        .contentShape(RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
    }
}

private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing && pulse ? 0.35 : 1.0)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if pulsing { pulse = true } }
    }
}

private struct MenuBarRow: View {
    let title: String
    let icon: String
    var accent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(accent ? HeardTheme.accent : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(MenuBarRowStyle())
    }
}

private struct MenuBarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.08)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline)
            )
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
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startTime)
            }
            .onAppear {
                elapsed = Date().timeIntervalSince(startTime)
            }
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
        StatusDot(color: .red, pulsing: true)
            .frame(width: size, height: size)
    }
}

// MARK: - Settings Window

public struct SettingsView: View {
    @ObservedObject public var model: AppModel
    @ObservedObject private var permissionCenter: PermissionCenter
    @State private var isRecordingHotkey = false
    @StateObject private var clipPlayer = SpeakerClipController()

    public init(model: AppModel) {
        self.model = model
        self.permissionCenter = model.permissionCenter
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(
                get: { model.selectedSettingsTab },
                set: { if let tab = $0 { model.selectedSettingsTab = tab } }
            )) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            Group {
                switch model.selectedSettingsTab {
                case .general:   generalSection
                case .dictation: dictationSection
                case .models:    modelsSection
                case .speakers:  speakersSection
                case .about:     aboutSection
                }
            }
            .navigationTitle(model.selectedSettingsTab.label)
            .frame(minWidth: 520, minHeight: 460)
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(isPresented: $isRecordingHotkey) {
            HotkeyRecorderView(
                onCommit: { combo in
                    model.updateDictationHotkey(combo)
                    isRecordingHotkey = false
                },
                onCancel: { isRecordingHotkey = false }
            )
        }
    }

    // MARK: General

    private var generalSection: some View {
        Form {
            Section("Preferences") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.settingsStore.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Auto-Watch on Launch", isOn: settingsBinding(\.autoWatch))
                Toggle("Developer Mode", isOn: settingsBinding(\.developerMode))
                    .help("Shows simulate meeting buttons in the menu bar for testing")
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Add a term (min 3 chars)", text: $model.vocabularyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addVocabularyTerm() }
                    Button("Add") { model.addVocabularyTerm() }
                        .disabled(model.vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }

                if model.settingsStore.settings.customVocabulary.isEmpty {
                    Text("No custom terms. Add domain-specific words to improve recognition.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(model.settingsStore.settings.customVocabulary, id: \.self) { term in
                        HStack(spacing: 5) {
                            Text(term).font(.callout)
                            Button {
                                model.removeVocabularyTerm(term)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }

                Text("\(model.settingsStore.settings.customVocabulary.count) / 50 terms")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Custom Vocabulary")
            }

            Section("Output Folder") {
                Text(model.settingsStore.settings.outputDirectory)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Choose…") { model.chooseOutputDirectory() }
                    Button("Reset") { model.chooseDefaultOutputDirectory() }
                    Button("Open in Finder") { model.openOutputDirectory() }
                }
            }

            Section("Permissions") {
                ForEach(model.permissionCenter.statuses) { permission in
                    PermissionRow(permission: permission, model: model)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Dictation

    private var dictationSection: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.settingsStore.settings.dictationEnabled },
                    set: { model.setDictationEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Dictation")
                        Text("Press the hotkey to start/stop dictating into any text field.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dictation")
            }

            Section("Hotkey") {
                Toggle(isOn: Binding(
                    get: { model.settingsStore.settings.pushToTalk },
                    set: { model.setPushToTalk($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Push to Talk")
                        Text("Hold the hotkey to dictate, release to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.settingsStore.settings.dictationEnabled)

                HStack {
                    Text(model.settingsStore.settings.pushToTalk ? "Hold to dictate" : "Toggle dictation")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.settingsStore.settings.dictationHotkey.displayString)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                    Button("Record…") { isRecordingHotkey = true }
                        .disabled(!model.settingsStore.settings.dictationEnabled)
                }

                if !permissionCenter.isAccessibilityGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Accessibility permission is required for text injection into other apps.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Grant Accessibility Access…") {
                                TextInjector.ensureAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep dictation model loaded for **\(keepAliveLabel(model.settingsStore.settings.dictationKeepAlive))** after stopping.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { model.settingsStore.settings.dictationKeepAlive },
                            set: { model.settingsStore.settings.dictationKeepAlive = $0 }
                        ),
                        in: 0...600,
                        step: 30
                    )
                    HStack {
                        Text("Unload immediately").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("10 minutes").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Button("Unload Dictation Models Now") {
                    model.dictationManager.unloadModels()
                }
                .controlSize(.small)
                .disabled(model.isDictating)
            } header: {
                Text("Model Keep-Alive")
            }

            if model.isDictating {
                Section("Status") {
                    HStack(spacing: 8) {
                        StatusDot(color: .red, pulsing: true)
                        Text("Dictating…")
                    }
                    if !model.partialTranscript.isEmpty {
                        Text(model.partialTranscript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let error = model.dictationError {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Models

    private var modelsSection: some View {
        Form {
            Section("Transcription Model") {
                Picker("Parakeet Version", selection: Binding(
                    get: { model.settingsStore.settings.transcriptionModel },
                    set: { model.setTranscriptionModel($0) }
                )) {
                    ForEach(TranscriptionModel.allCases) { version in
                        Text(version.displayName).tag(version)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("V2 is recommended for English meetings. Changing versions will reload models on the next transcription.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Model Status") {
                ForEach(model.modelCatalog.statuses) { item in
                    ModelStatusRow(item: item, downloadManager: model.downloadManager)
                }

                if !model.downloadManager.allBatchModelsReady {
                    Button {
                        model.downloadManager.downloadAllModels()
                    } label: {
                        Label("Download All Models", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Models download automatically on first meeting, but you can pre-download here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep transcription models loaded for **\(keepAliveLabel(model.settingsStore.settings.pipelineKeepAlive))** after processing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { model.settingsStore.settings.pipelineKeepAlive },
                            set: { model.settingsStore.settings.pipelineKeepAlive = $0 }
                        ),
                        in: 0...600,
                        step: 30
                    )
                    HStack {
                        Text("Unload immediately").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("10 minutes").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text("Keeping models loaded speeds up back-to-back meetings but uses more RAM (~800 MB).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Meeting Transcription Keep-Alive")
            }

            Section("Memory") {
                Text("Force unload all cached models to free RAM/VRAM immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    model.pipelineProcessor.unloadPipelineModels()
                    model.dictationManager.unloadModels()
                } label: {
                    Label("Unload All Models", systemImage: "xmark.circle.fill")
                }
                .disabled(model.pipelineProcessor.isProcessing || model.isDictating)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Speakers

    private var speakersSection: some View {
        VStack(spacing: 0) {
            // Top toolbar area
            VStack(spacing: HeardTheme.Spacing.md) {
                HStack(spacing: HeardTheme.Spacing.sm) {
                    Text("Your Name")
                        .foregroundStyle(.secondary)
                    TextField("Used as speaker label in transcripts", text: settingsBinding(\.userName))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Spacer()
                }

                if !model.namingCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: HeardTheme.Spacing.sm) {
                        Label("New speakers detected — name them", systemImage: "person.badge.plus")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(model.namingCandidates) { candidate in
                            NamingCandidateRow(candidate: candidate) { name in
                                model.saveSpeakerName(candidate: candidate, name: name)
                            }
                        }
                    }
                    .padding(HeardTheme.Spacing.md)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
                }

                HStack(spacing: HeardTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("Search speakers", text: $model.speakerFilter)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                    .frame(maxWidth: 260)

                    Picker("Sort", selection: $model.speakerSortMode) {
                        ForEach(SpeakerSortMode.allCases) { sortMode in
                            Text(sortMode.displayName).tag(sortMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)

                    Spacer()

                    Button("Merge Selected") {
                        model.mergeSelectedSpeakers()
                    }
                    .disabled(model.mergeSelection.count != 2)
                }
            }
            .padding(HeardTheme.Spacing.lg)

            Divider()

            Table(model.filteredSpeakers, selection: $model.mergeSelection) {
                TableColumn("Voice") { speaker in
                    SpeakerVoiceCell(speaker: speaker, controller: clipPlayer)
                }
                .width(56)
                TableColumn("Name") { speaker in
                    InlineEditableText(value: speaker.name) { newValue in
                        model.speakerStore.rename(id: speaker.id, to: newValue)
                    }
                }
                TableColumn("Meetings") { speaker in
                    Text("\(speaker.meetingCount)").monospacedDigit()
                }
                TableColumn("First Seen") { speaker in
                    Text(speaker.firstSeen.formatted(date: .abbreviated, time: .omitted))
                }
                TableColumn("Last Seen") { speaker in
                    Text(speaker.lastSeen.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Delete Speaker", role: .destructive) {
                        clipPlayer.stop()
                        model.speakerStore.delete(id: id)
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: HeardTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 88, height: 88)
                    Image(systemName: "waveform")
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(HeardTheme.accent)
                }

                VStack(spacing: 2) {
                    Text("Heard")
                        .font(.system(.largeTitle, design: .default).weight(.semibold))
                    Text("Version 0.1.0")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Automatic meeting detection, dual-track recording,\non-device transcription and speaker diarization.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.top, 4)

                HStack(spacing: HeardTheme.Spacing.sm) {
                    AboutBadge(icon: "lock.shield", text: "On-Device")
                    AboutBadge(icon: "icloud.slash", text: "No Cloud")
                    AboutBadge(icon: "brain.head.profile", text: "No LLM")
                }
                .padding(.top, 4)

                Text("Powered by FluidAudio · Parakeet TDT · Silero VAD · WeSpeaker")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(HeardTheme.Spacing.lg)

            Spacer()
            Divider()
            Text("Direct Download Distribution")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Helpers

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settingsStore.settings[keyPath: keyPath] },
            set: { model.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    private func keepAliveLabel(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "0s" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 && secs > 0 { return "\(mins)m \(secs)s" }
        if mins > 0 { return "\(mins)m" }
        return "\(secs)s"
    }
}

// MARK: - Model Status Row

private struct ModelStatusRow: View {
    let item: ModelStatusItem
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundStyle(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.modelKind.displayName(for: downloadManager.transcriptionModel))
                    .font(.callout.weight(.medium))

                if let progress = downloadManager.downloadProgress[item.modelKind] {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if let error = downloadManager.errors[item.modelKind] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(item.availability == .ready ? .green : .secondary)
                }
            }

            Spacer()

            if item.availability == .notDownloaded && downloadManager.downloadProgress[item.modelKind] == nil {
                Button("Download") {
                    downloadManager.download(item.modelKind)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        if downloadManager.downloadProgress[item.modelKind] != nil { return "arrow.down.circle" }
        if downloadManager.errors[item.modelKind] != nil { return "exclamationmark.triangle" }
        switch item.availability {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .notDownloaded: return "arrow.down.to.line"
        }
    }

    private var statusColor: Color {
        if downloadManager.downloadProgress[item.modelKind] != nil { return HeardTheme.accent }
        if downloadManager.errors[item.modelKind] != nil { return .red }
        switch item.availability {
        case .ready: return .green
        case .downloading: return HeardTheme.accent
        case .notDownloaded: return .secondary
        }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let permission: PermissionStatus
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconTint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.callout.weight(.medium))
                    if permission.id == "microphone" || permission.id == "screenCapture" {
                        Text("Required")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.12), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(permission.state.badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(permission.state == .granted ? .green : .orange)
                if permission.state != .granted {
                    Button("Grant…") {
                        switch permission.id {
                        case "microphone": model.permissionCenter.requestMicrophone()
                        case "screenCapture": model.permissionCenter.openScreenCaptureSettings()
                        case "accessibility": model.permissionCenter.openAccessibilitySettings()
                        default: break
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch permission.id {
        case "microphone": return "mic.fill"
        case "screenCapture": return "rectangle.dashed.badge.record"
        case "accessibility": return "figure.stand"
        default: return "lock.fill"
        }
    }

    private var iconTint: Color {
        permission.state == .granted ? .green : HeardTheme.accent
    }
}

// MARK: - About Badge

private struct AboutBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Hotkey Recorder

private struct HotkeyRecorderView: View {
    let onCommit: (HotkeyCombo) -> Void
    let onCancel: () -> Void

    @State private var captured: HotkeyCombo? = nil
    @State private var monitorToken: Any? = nil

    var body: some View {
        VStack(spacing: HeardTheme.Spacing.lg) {
            Image(systemName: "keyboard")
                .font(.system(size: 36))
                .foregroundStyle(HeardTheme.accent)

            Text("Record Shortcut")
                .font(.title2.weight(.semibold))

            Text("Press the key combination you want to use for dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Group {
                if let combo = captured {
                    Text(combo.displayString)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(HeardTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                        .foregroundStyle(HeardTheme.accent)
                } else {
                    Text("Waiting for input…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            }
            .frame(height: 44)

            HStack(spacing: HeardTheme.Spacing.md) {
                Button("Cancel") {
                    stopMonitoring()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    stopMonitoring()
                    if let combo = captured { onCommit(combo) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(HeardTheme.Spacing.xl)
        .frame(width: 360)
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isModifierOnlyKeyCode(event.keyCode) else { return event }
            let combo = HotkeyCombo(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift])
            )
            captured = combo
            return nil
        }
    }

    private func stopMonitoring() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }

    private func isModifierOnlyKeyCode(_ code: UInt16) -> Bool {
        let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return modifierCodes.contains(code)
    }
}

// MARK: - Reusable Components

struct InlineEditableText: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        if isEditing {
            TextField("Name", text: $draft, onCommit: commit)
                .textFieldStyle(.roundedBorder)
        } else {
            Text(value)
                .onTapGesture {
                    draft = value
                    isEditing = true
                }
        }
    }

    private func commit() {
        isEditing = false
        guard !draft.isEmpty else { return }
        onCommit(draft)
    }
}

struct NamingCandidateRow: View {
    let candidate: NamingCandidate
    let onSave: (String) -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: HeardTheme.Spacing.sm) {
            Text(candidate.temporaryName)
                .font(.callout.weight(.medium))
                .frame(width: 140, alignment: .leading)
            TextField("Enter speaker name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(draft)
    }
}

// MARK: - Speaker Naming Prompt Window

public struct SpeakerNamingView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [UUID: String] = [:]
    @State private var playingID: UUID?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var countdownSeconds = 120
    @State private var countdownTask: Task<Void, Never>?
    @Environment(\.dismissWindow) private var dismissWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: HeardTheme.Spacing.sm) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(HeardTheme.accent)

                Text("New Speakers Detected")
                    .font(.title2.weight(.semibold))

                Text("Listen to each voice clip and enter their name. Unnamed speakers will be saved with generic labels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Text("Auto-saving in \(countdownSeconds)s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, HeardTheme.Spacing.lg)
            .padding(.bottom, HeardTheme.Spacing.md)

            Divider()

            ScrollView {
                VStack(spacing: HeardTheme.Spacing.sm) {
                    ForEach(model.namingCandidates) { candidate in
                        speakerRow(candidate)
                    }
                }
                .padding(HeardTheme.Spacing.lg)
            }

            Divider()

            HStack {
                Button("Skip All") {
                    stopAudio()
                    model.skipNaming()
                    dismissWindow(id: "speaker-naming")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save & Close") {
                    stopAudio()
                    saveAll()
                    dismissWindow(id: "speaker-naming")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(HeardTheme.Spacing.lg)
        }
        .frame(width: 540)
        .onAppear { startCountdown() }
        .onDisappear {
            stopAudio()
            countdownTask?.cancel()
        }
        .onChange(of: model.namingCandidates) { _, candidates in
            if candidates.isEmpty {
                stopAudio()
                countdownTask?.cancel()
                dismissWindow(id: "speaker-naming")
            }
        }
    }

    private func speakerRow(_ candidate: NamingCandidate) -> some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            Button(action: { togglePlayback(candidate) }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(playButtonColor(candidate).opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: playingID == candidate.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(playButtonColor(candidate))
                }
            }
            .buttonStyle(.plain)
            .disabled(candidate.audioClipURL == nil)
            .help(candidate.audioClipURL == nil ? "No audio clip available" : "Play voice sample")

            VStack(alignment: .leading, spacing: HeardTheme.Spacing.xs) {
                HStack(spacing: 6) {
                    Text(candidate.temporaryName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let suggested = candidate.suggestedName {
                        Text("(maybe \(suggested)?)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                TextField(
                    candidate.suggestedName ?? "Enter speaker name",
                    text: binding(for: candidate)
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveSingle(candidate) }
            }

            Button("Save") { saveSingle(candidate) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draftText(for: candidate).isEmpty)
        }
        .padding(HeardTheme.Spacing.md)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
    }

    // MARK: Playback

    private func togglePlayback(_ candidate: NamingCandidate) {
        if playingID == candidate.id {
            stopAudio()
            return
        }
        stopAudio()

        guard let url = candidate.audioClipURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
            playingID = candidate.id

            Task {
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                if playingID == candidate.id {
                    playingID = nil
                }
            }
        } catch {
            NSLog("Heard: Failed to play audio clip: \(error)")
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    private func playButtonColor(_ candidate: NamingCandidate) -> Color {
        if candidate.audioClipURL == nil { return .secondary }
        return playingID == candidate.id ? .red : HeardTheme.accent
    }

    // MARK: Drafts

    private func binding(for candidate: NamingCandidate) -> Binding<String> {
        Binding(
            get: { drafts[candidate.id] ?? candidate.suggestedName ?? "" },
            set: { drafts[candidate.id] = $0 }
        )
    }

    private func draftText(for candidate: NamingCandidate) -> String {
        let text = drafts[candidate.id] ?? candidate.suggestedName ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveSingle(_ candidate: NamingCandidate) {
        let name = draftText(for: candidate)
        guard !name.isEmpty else { return }
        model.saveSpeakerName(candidate: candidate, name: name)
        drafts.removeValue(forKey: candidate.id)
    }

    private func saveAll() {
        for candidate in model.namingCandidates {
            let name = draftText(for: candidate)
            if !name.isEmpty {
                model.saveSpeakerName(candidate: candidate, name: name)
            }
        }
        if !model.namingCandidates.isEmpty {
            model.skipNaming()
        }
    }

    // MARK: Countdown

    private func startCountdown() {
        countdownSeconds = 120
        countdownTask?.cancel()
        countdownTask = Task {
            while !Task.isCancelled && countdownSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdownSeconds -= 1
            }
        }
    }
}

// MARK: - Speaker Voice Cell (Speakers tab playback)

@MainActor
final class SpeakerClipController: ObservableObject {
    @Published private(set) var playingID: UUID?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(speakerID: UUID, clipURL: URL?) {
        if playingID == speakerID {
            stop()
            return
        }
        stop()
        guard let url = clipURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            playingID = speakerID
            let duration = p.duration
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.1))
                guard let self, !Task.isCancelled else { return }
                if self.playingID == speakerID {
                    self.stop()
                }
            }
        } catch {
            NSLog("Heard: Failed to play speaker clip: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        stopTask?.cancel()
        stopTask = nil
        playingID = nil
    }
}

struct SpeakerVoiceCell: View {
    let speaker: SpeakerProfile
    @ObservedObject var controller: SpeakerClipController

    private var hasClip: Bool {
        guard let url = speaker.audioClipURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isPlaying: Bool { controller.playingID == speaker.id }

    var body: some View {
        Button {
            controller.toggle(speakerID: speaker.id, clipURL: speaker.audioClipURL)
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 12))
                .foregroundStyle(hasClip ? (isPlaying ? Color.red : HeardTheme.accent) : Color.secondary)
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((hasClip ? (isPlaying ? Color.red : HeardTheme.accent) : Color.secondary).opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasClip)
        .help(hasClip ? "Play voice sample" : "No voice sample saved")
    }
}

// MARK: - Flow Layout

struct FlowLayout<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: [Data.Element]
    private let id: KeyPath<Data.Element, ID>
    private let content: (Data.Element) -> Content

    init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = Array(data)
        self.id = id
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(data, id: id, content: content)
        }
    }
}
