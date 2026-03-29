import AVFoundation
import SwiftUI

// MARK: - Theme

private enum HeardTheme {
    static let accent = Color.indigo
    static let cardBackground = Color(.windowBackgroundColor).opacity(0.5)
    static let cardBorder = Color.primary.opacity(0.06)
    static let sectionSpacing: CGFloat = 12
    static let cornerRadius: CGFloat = 10
}

// MARK: - Menu Bar Dropdown

public struct MenuBarView: View {
    @ObservedObject public var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            // Error banner (only when needed)
            if let errorMessage = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.acknowledgeError() }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HeardTheme.accent)
                }
                .padding(8)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }

            VStack(spacing: 0) {
                // Watching toggle — indicator + button in one
                watchingButton

                // Dictation status / toggle
                if model.settingsStore.settings.dictationEnabled {
                    if model.isDictating {
                        MenuBarStatusRow(icon: "mic.fill", tint: .red) {
                            Text("Dictating")
                                .foregroundStyle(.red)
                            if !model.partialTranscript.isEmpty {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(String(model.partialTranscript.suffix(40)))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        MenuBarButton(
                            title: "Dictation",
                            icon: "mic.badge.plus",
                            tint: .secondary
                        ) {
                            model.toggleDictation()
                        }
                    }
                }

                if model.settingsStore.settings.developerMode {
                    if model.recordingManager.activeSession == nil {
                        MenuBarButton(title: "Simulate Meeting", icon: "bolt.circle", tint: .purple) {
                            model.simulateMeeting()
                        }
                    } else {
                        MenuBarButton(title: "End Simulation", icon: "stop.circle", tint: .red) {
                            model.endSimulatedMeeting()
                        }
                    }
                }

                if !model.namingCandidates.isEmpty {
                    MenuBarButton(title: "Name Speakers…", icon: "person.badge.plus", tint: .yellow) {
                        openWindow(id: "speaker-naming")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }

                MenuBarButton(title: "Open Transcripts", icon: "folder", tint: .secondary) {
                    model.openOutputDirectory()
                }

                MenuBarButton(title: "Settings…", icon: "gearshape", tint: .secondary) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuBarButton(title: "Quit Heard", icon: "power", tint: .secondary) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, model.errorMessage == nil ? 4 : 2)
            .padding(.bottom, 4)
        }
        .frame(width: 220)
        .onChange(of: model.showNamingPrompt) { _, show in
            if show {
                openWindow(id: "speaker-naming")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: Watching Button (indicator + toggle in one)

    @ViewBuilder
    private var watchingButton: some View {
        if let session = model.recordingManager.activeSession {
            // Recording state — not toggleable, just status
            MenuBarStatusRow(icon: "record.circle", tint: .red) {
                Text("Recording")
                    .foregroundStyle(.red)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(session.title.isEmpty ? "Meeting" : session.title)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                RecordingTimerView(startTime: session.startTime)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if let job = model.queueStore.activeJob, job.stage != .complete && job.stage != .failed {
            // Processing state
            MenuBarStatusRow(icon: "waveform", tint: .orange) {
                Text("Processing")
                    .foregroundStyle(.orange)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(job.stage.displayName)
                    .foregroundStyle(.secondary)
            }
        } else {
            // Watching / Paused — clickable toggle
            MenuBarButton(
                title: model.meetingDetector.isWatching ? "Watching" : "Paused",
                icon: model.meetingDetector.isWatching ? "eye" : "pause.circle",
                tint: model.meetingDetector.isWatching ? Color(red: 0.33, green: 0.49, blue: 0.27) : Color(red: 0.82, green: 0.7, blue: 0.2)
            ) {
                model.toggleWatching()
            }
        }
    }
}

// MARK: - Menu Bar Status Row (non-interactive, same layout as MenuBarButton)

private struct MenuBarStatusRow<Content: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 20)
            HStack(spacing: 4) {
                content
            }
            .font(.system(.body, design: .default))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Menu Bar Button

private struct MenuBarButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(title)
                    .font(.system(.body, design: .default))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(MenuBarButtonStyle())
    }
}

private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.08)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}

// MARK: - Job Row

private struct JobRow: View {
    let job: PipelineJob
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: job.stage == .complete ? "checkmark.circle.fill" : job.stage == .failed ? "xmark.circle.fill" : "clock.fill")
                .font(.caption)
                .foregroundStyle(job.stage == .complete ? .green : job.stage == .failed ? .red : .orange)

            Text(job.meetingTitle)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if job.transcriptPath != nil {
                Button { model.openTranscript(job) } label: {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(HeardTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Open transcript")
            }

            if job.stage == .failed {
                Button { model.retry(job) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Retry")
            }

            Button { model.dismissJob(job) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.vertical, 3)
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
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Pulsing Recording Dot

public struct PulsingDot: View {
    var size: CGFloat = 8
    @State private var isPulsing = false

    public init(size: CGFloat = 8) { self.size = size }

    public var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.4).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Settings Window

public struct SettingsView: View {
    @ObservedObject public var model: AppModel
    @ObservedObject private var permissionCenter: PermissionCenter

    public init(model: AppModel) {
        self.model = model
        self.permissionCenter = model.permissionCenter
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarItem(
                        title: tab.label,
                        icon: tab.icon,
                        isSelected: model.selectedSettingsTab == tab
                    ) {
                        model.selectedSettingsTab = tab
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)
            .background(Color(.windowBackgroundColor).opacity(0.4))

            Divider()

            // Content
            Group {
                switch model.selectedSettingsTab {
                case .general: generalSection
                case .dictation: dictationSection
                case .models: modelsSection
                case .speakers: speakersSection
                case .about: aboutSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: General Section (absorbs Permissions)

    private var generalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Preferences
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsSectionHeader(title: "Preferences", icon: "gearshape")

                        Toggle("Launch at Login", isOn: Binding(
                            get: { model.settingsStore.settings.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))

                        Toggle("Auto-Watch on Launch", isOn: settingsBinding(\.autoWatch))

                        Toggle("Developer Mode", isOn: settingsBinding(\.developerMode))
                            .help("Shows simulate meeting buttons in the menu bar for testing")
                    }
                }

                // Custom Vocabulary
                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionHeader(title: "Custom Vocabulary", icon: "textformat.abc")

                        HStack {
                            TextField("Add a term (min 3 chars)", text: $model.vocabularyDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.addVocabularyTerm() }
                            Button("Add") { model.addVocabularyTerm() }
                                .disabled(model.vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                        }

                        if model.settingsStore.settings.customVocabulary.isEmpty {
                            Text("No custom terms. Add domain-specific words to improve recognition.")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        } else {
                            FlowLayout(model.settingsStore.settings.customVocabulary, id: \.self) { term in
                                HStack(spacing: 5) {
                                    Text(term)
                                        .font(.callout)
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
                                .background(HeardTheme.accent.opacity(0.1), in: Capsule())
                            }
                        }

                        Text("\(model.settingsStore.settings.customVocabulary.count)/50 terms")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Output Folder
                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionHeader(title: "Output Folder", icon: "folder")

                        HStack {
                            Text(model.settingsStore.settings.outputDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                            Button("Choose…") { model.chooseOutputDirectory() }
                            Button("Reset") { model.chooseDefaultOutputDirectory() }
                            Button("Open") { model.openOutputDirectory() }
                        }
                    }
                }

                // Permissions
                SectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSectionHeader(title: "Permissions", icon: "lock.shield")

                        ForEach(model.permissionCenter.statuses) { permission in
                            PermissionCard(permission: permission, model: model)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: Dictation Section

    private var dictationSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Enable / Disable
                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionHeader(title: "Dictation", icon: "mic.badge.plus")

                        Toggle(isOn: Binding(
                            get: { model.settingsStore.settings.dictationEnabled },
                            set: { model.setDictationEnabled($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Dictation")
                                    .font(.callout.weight(.medium))
                                Text("Press the hotkey to start/stop dictating into any text field.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Hotkey
                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionHeader(title: "Hotkey", icon: "command")

                        Toggle(isOn: Binding(
                            get: { model.settingsStore.settings.pushToTalk },
                            set: { model.setPushToTalk($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Push to Talk")
                                    .font(.callout.weight(.medium))
                                Text("Hold the hotkey to dictate, release to stop.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!model.settingsStore.settings.dictationEnabled)

                        HStack {
                            Text(model.settingsStore.settings.pushToTalk ? "Hold to dictate:" : "Toggle dictation:")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Text(model.settingsStore.settings.dictationHotkey.displayString)
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                            Spacer()

                            Button("Record Shortcut") {
                                isRecordingHotkey = true
                            }
                            .disabled(!model.settingsStore.settings.dictationEnabled)
                        }

                        if !permissionCenter.isAccessibilityGranted {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Accessibility permission is required for text injection into other apps.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Grant Accessibility Access...") {
                                        TextInjector.ensureAccessibility()
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                // Status
                if model.isDictating {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                Text("Dictating...")
                                    .font(.callout.weight(.medium))
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
                }

                if let error = model.dictationError {
                    SectionCard {
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
            .padding(20)
        }
        .sheet(isPresented: $isRecordingHotkey) {
            HotkeyRecorderView(
                onCommit: { saveHotkey($0) },
                onCancel: { isRecordingHotkey = false }
            )
        }
    }

    @State private var isRecordingHotkey = false

    private func saveHotkey(_ combo: HotkeyCombo) {
        model.updateDictationHotkey(combo)
        isRecordingHotkey = false
    }

    // MARK: Models Section

    private var modelsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Model Status
                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionHeader(title: "Model Status", icon: "cpu")

                        ForEach(model.modelCatalog.statuses) { item in
                            ModelStatusCard(item: item, downloadManager: model.downloadManager)
                        }

                        if !model.downloadManager.allBatchModelsReady {
                            Button {
                                model.downloadManager.downloadAllModels()
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Download All Models")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HeardTheme.accent)

                            Text("Models download automatically on first meeting, but you can pre-download here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            }
            .padding(20)
        }
    }

    // MARK: Speakers Section

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Your Name
            HStack(spacing: 10) {
                Text("Your Name")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Used as speaker label in transcripts", text: settingsBinding(\.userName))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if !model.namingCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("New speakers detected — name them:", systemImage: "person.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(model.namingCandidates) { candidate in
                        NamingCandidateRow(candidate: candidate) { name in
                            model.saveSpeakerName(candidate: candidate, name: name)
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: HeardTheme.cornerRadius))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search speakers", text: $model.speakerFilter)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                Picker("Sort", selection: $model.speakerSortMode) {
                    ForEach(SpeakerSortMode.allCases) { sortMode in
                        Text(sortMode.displayName).tag(sortMode)
                    }
                }
                .pickerStyle(.segmented)

                Button("Merge Selected") {
                    model.mergeSelectedSpeakers()
                }
                .disabled(model.mergeSelection.count != 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Table(model.filteredSpeakers, selection: $model.mergeSelection) {
                TableColumn("Name") { speaker in
                    InlineEditableText(value: speaker.name) { newValue in
                        model.speakerStore.rename(id: speaker.id, to: newValue)
                    }
                }
                TableColumn("Meetings") { speaker in
                    Text("\(speaker.meetingCount)")
                        .monospacedDigit()
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
                        model.speakerStore.delete(id: id)
                    }
                }
            }
        }
    }

    // MARK: About Section

    private var aboutSection: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [HeardTheme.accent, HeardTheme.accent.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(spacing: 4) {
                    Text("Heard")
                        .font(.system(.title, design: .rounded).weight(.bold))
                    Text("Version 0.1.0")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Automatic meeting detection, dual-track recording,\non-device transcription and speaker diarization.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)

                HStack(spacing: 16) {
                    AboutBadge(icon: "lock.shield.fill", text: "On-Device")
                    AboutBadge(icon: "icloud.slash.fill", text: "No Cloud")
                    AboutBadge(icon: "brain.head.profile.fill", text: "No LLM")
                }

                Text("Powered by FluidAudio · Parakeet TDT · Silero VAD · WeSpeaker")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Divider()

            Text("Direct Download Distribution")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settingsStore.settings[keyPath: keyPath] },
            set: { model.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Sidebar Item

private struct SidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(.body, design: .default))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? AnyShapeStyle(HeardTheme.accent)
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Section Components

private struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: HeardTheme.cornerRadius))
    }
}

private struct SettingsSectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(.headline, design: .rounded))
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Model Status Card

private struct ModelStatusCard: View {
    let item: ModelStatusItem
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 16))
                .foregroundStyle(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.modelKind.displayName)
                    .font(.callout.weight(.medium))

                if let progress = downloadManager.downloadProgress[item.modelKind] {
                    ProgressView(value: progress)
                        .tint(HeardTheme.accent)
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
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(HeardTheme.accent)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - Permission Card

private struct PermissionCard: View {
    let permission: PermissionStatus
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.callout.weight(.medium))
                    if permission.id == "microphone" {
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
                        case "accessibility": model.permissionCenter.openAccessibilitySettings()
                        default: break
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(HeardTheme.accent)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: HeardTheme.cornerRadius))
    }

    private var iconName: String {
        switch permission.id {
        case "microphone": return "mic.fill"
        case "accessibility": return "figure.stand"
        default: return "lock.fill"
        }
    }

    private var iconColor: Color {
        permission.state == .granted ? .green : HeardTheme.accent
    }
}

// MARK: - About Badge

private struct AboutBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }
}

// MARK: - Hotkey Recorder

/// Modal sheet that listens for a single keypress and saves it as the new hotkey.
private struct HotkeyRecorderView: View {
    let onCommit: (HotkeyCombo) -> Void
    let onCancel: () -> Void

    @State private var captured: HotkeyCombo? = nil
    @State private var monitorToken: Any? = nil

    var body: some View {
        VStack(spacing: 20) {
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

            // Preview of captured key
            Group {
                if let combo = captured {
                    Text(combo.displayString)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(HeardTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(HeardTheme.accent)
                } else {
                    Text("Waiting for input…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                }
            }
            .frame(height: 44)

            HStack(spacing: 12) {
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
                .tint(HeardTheme.accent)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Ignore lone modifier keypresses (keyCode 54–63 range, etc.)
            guard !isModifierOnlyKeyCode(event.keyCode) else { return event }

            let combo = HotkeyCombo(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift])
            )
            captured = combo
            // Swallow the event so it doesn't type into anything
            return nil
        }
    }

    private func stopMonitoring() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }

    /// Returns true for key codes that represent modifier keys by themselves.
    private func isModifierOnlyKeyCode(_ code: UInt16) -> Bool {
        // Shift, Control, Option, Command, Fn, Caps Lock virtual key codes
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
        HStack {
            Text(candidate.temporaryName)
                .font(.callout.weight(.medium))
                .frame(width: 140, alignment: .leading)
            TextField("Enter speaker name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(HeardTheme.accent)
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

/// Dedicated window for naming unmatched speakers after a meeting.
/// Shows audio clips for each speaker so the user can identify who's who.
public struct SpeakerNamingView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [UUID: String] = [:]
    @State private var playingID: UUID?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var countdownSeconds = 120
    @State private var countdownTask: Task<Void, Never>?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(HeardTheme.accent)

                Text("New Speakers Detected")
                    .font(.title2.weight(.semibold))

                Text("Listen to each voice clip and enter their name. Unnamed speakers will be saved with generic labels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Text("Auto-saving in \(countdownSeconds)s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Speaker list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.namingCandidates) { candidate in
                        speakerRow(candidate)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Skip All") {
                    stopAudio()
                    model.skipNaming()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save All") {
                    stopAudio()
                    saveAll()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(HeardTheme.accent)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear { startCountdown() }
        .onDisappear {
            stopAudio()
            countdownTask?.cancel()
        }
        .onChange(of: model.namingCandidates) { _, candidates in
            if candidates.isEmpty {
                stopAudio()
                countdownTask?.cancel()
            }
        }
    }

    private func speakerRow(_ candidate: NamingCandidate) -> some View {
        HStack(spacing: 12) {
            // Play button
            Button(action: { togglePlayback(candidate) }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(playButtonColor(candidate).opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: playingID == candidate.id ? "stop.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(playButtonColor(candidate))
                }
            }
            .buttonStyle(.plain)
            .disabled(candidate.audioClipURL == nil)
            .help(candidate.audioClipURL == nil ? "No audio clip available" : "Play voice sample")

            VStack(alignment: .leading, spacing: 4) {
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
                .tint(HeardTheme.accent)
                .controlSize(.small)
                .disabled(draftText(for: candidate).isEmpty)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: HeardTheme.cornerRadius))
    }

    // MARK: - Audio Playback

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

            // Auto-stop when done
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

    // MARK: - Draft Management

    private func binding(for candidate: NamingCandidate) -> Binding<String> {
        Binding(
            get: {
                drafts[candidate.id] ?? candidate.suggestedName ?? ""
            },
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
        // Skip any remaining without names
        if !model.namingCandidates.isEmpty {
            model.skipNaming()
        }
    }

    // MARK: - Countdown

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
