import SwiftUI

// MARK: - Menu Bar Dropdown

public struct MenuBarView: View {
    @ObservedObject public var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Status + core actions
            statusSection

            Divider()

            // Primary actions always visible
            actionsSection

            // Queue at bottom — can be clipped if many jobs
            if !model.queueStore.recentJobs.isEmpty {
                Divider()
                queueSection
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.phase == .recording {
                    PulsingDot()
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
                Text(model.phase.title)
                    .font(.headline)
            }

            if let session = model.recordingManager.activeSession {
                HStack {
                    Text(session.title.isEmpty ? "Meeting" : session.title)
                    Spacer()
                    RecordingTimerView(startTime: session.startTime)
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
                .foregroundStyle(.secondary)
            } else if let job = model.queueStore.activeJob, job.stage != .complete && job.stage != .failed {
                HStack {
                    Text(job.meetingTitle)
                    Spacer()
                    Text(job.stage.displayName)
                        .foregroundStyle(.orange)
                    if let stageStart = job.stageStartTime {
                        RecordingTimerView(startTime: stageStart)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                Text(model.meetingDetector.isWatching ? "Auto-watch enabled" : "Idle")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Dismiss") { model.acknowledgeError() }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .dormant: return .green
        case .recording: return .red
        case .processing: return .orange
        case .error: return .red
        case .userAction: return .yellow
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Jobs")
                .font(.subheadline.weight(.semibold))

            if model.queueStore.recentJobs.isEmpty {
                Text("No meetings processed yet.")
                    .foregroundStyle(.tertiary)
                    .font(.footnote)
            } else {
                ForEach(model.queueStore.recentJobs) { job in
                    HStack(spacing: 8) {
                        Image(systemName: job.stage == .complete ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(job.stage == .complete ? .green : .red)
                            .font(.footnote)
                        Text(job.meetingTitle)
                            .lineLimit(1)
                        Spacer()
                        if job.transcriptPath != nil {
                            Button("Open") { model.openTranscript(job) }
                                .buttonStyle(.link)
                                .font(.footnote)
                        }
                        if job.stage == .failed {
                            Button("Retry") { model.retry(job) }
                                .buttonStyle(.link)
                                .font(.footnote)
                        }
                        Button {
                            model.dismissJob(job)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from list")
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(model.meetingDetector.isWatching ? "Stop Watching" : "Start Watching") {
                model.toggleWatching()
            }

            if model.recordingManager.activeSession == nil {
                Button("Simulate Meeting Start") {
                    model.simulateMeeting()
                }
            } else {
                Button("Simulate Meeting End") {
                    model.endSimulatedMeeting()
                }
            }

            if !model.namingCandidates.isEmpty {
                Button("Name Speakers...") {
                    model.selectedSettingsTab = .speakers
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Button("Open Transcripts Folder") {
                model.openOutputDirectory()
            }

            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
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
    @State private var isPulsing = false

    public init() {}

    public var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
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

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView(selection: $model.selectedSettingsTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)

            dictationTab
                .tabItem { Label("Dictation", systemImage: "mic.badge.plus") }
                .tag(SettingsTab.dictation)

            speakersTab
                .tabItem { Label("Speakers", systemImage: "person.3") }
                .tag(SettingsTab.speakers)

            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
    }

    // MARK: General Tab

    private var generalTab: some View {
        Form {
            TextField("Your Name", text: settingsBinding(\.userName))
                .help("Used as the local speaker label in transcripts")

            Toggle("Launch at Login", isOn: Binding(
                get: { model.settingsStore.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Toggle("Auto-Watch on Launch", isOn: settingsBinding(\.autoWatch))

            VStack(alignment: .leading, spacing: 8) {
                Text("Output Folder")
                    .font(.headline)

                HStack {
                    Text(model.settingsStore.settings.outputDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

                    Button("Choose...") { model.chooseOutputDirectory() }
                    Button("Reset") { model.chooseDefaultOutputDirectory() }
                    Button("Open") { model.openOutputDirectory() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Transcription Tab

    private var transcriptionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Vocabulary")
                .font(.headline)

            HStack {
                TextField("Add a term (min 3 chars)", text: $model.vocabularyDraft)
                    .onSubmit { model.addVocabularyTerm() }
                Button("Add") { model.addVocabularyTerm() }
                    .disabled(model.vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }

            if model.settingsStore.settings.customVocabulary.isEmpty {
                Text("No custom terms. Add domain-specific words to improve recognition.")
                    .foregroundStyle(.tertiary)
                    .font(.footnote)
            } else {
                FlowLayout(model.settingsStore.settings.customVocabulary, id: \.self) { term in
                    HStack(spacing: 6) {
                        Text(term)
                        Button {
                            model.removeVocabularyTerm(term)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }

            Text("\(model.settingsStore.settings.customVocabulary.count)/50 terms")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Divider()

            Text("Model Status")
                .font(.headline)

            ForEach(model.modelCatalog.statuses) { item in
                HStack {
                    Text(item.modelKind.displayName)
                    Spacer()
                    if let progress = model.downloadManager.downloadProgress[item.modelKind] {
                        ProgressView(value: progress)
                            .frame(width: 100)
                        Text("\(Int(progress * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let error = model.downloadManager.errors[item.modelKind] {
                        Text(error)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .font(.footnote)
                    } else {
                        Text(item.detail)
                            .foregroundStyle(item.availability == .ready ? .green : .secondary)
                    }
                }
            }

            if !model.downloadManager.allModelsReady {
                Button("Download All Models") {
                    model.downloadManager.downloadAllModels()
                }
                Text("Models download automatically on first meeting, but you can pre-download here.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Dictation Tab

    private var dictationTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Coming in v2")
                .font(.title3.weight(.semibold))
            Text("Live dictation with streaming transcription.\nThe mic publisher and model catalog are ready for this.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Speakers Tab

    private var speakersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.namingCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("New speakers detected — name them:", systemImage: "person.badge.plus")
                        .font(.headline)
                    ForEach(model.namingCandidates) { candidate in
                        NamingCandidateRow(candidate: candidate) { name in
                            model.saveSpeakerName(candidate: candidate, name: name)
                        }
                    }
                }
                Divider()
            }

            HStack {
                TextField("Search speakers", text: $model.speakerFilter)
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

            Table(model.filteredSpeakers, selection: $model.mergeSelection) {
                TableColumn("Name") { speaker in
                    InlineEditableText(value: speaker.name) { newValue in
                        model.speakerStore.rename(id: speaker.id, to: newValue)
                    }
                }
                TableColumn("Meetings") { speaker in
                    Text("\(speaker.meetingCount)")
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

    // MARK: Permissions Tab

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(model.permissionCenter.statuses) { permission in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(permission.title)
                                .font(.headline)
                            if permission.id == "microphone" {
                                Text("Required")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.red.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.red)
                            }
                        }
                        Text(permission.purpose)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(permission.state.badge)
                        .foregroundStyle(permission.state == .granted ? .green : .orange)
                        .font(.footnote.weight(.medium))
                    Button("Grant...") {
                        switch permission.id {
                        case "microphone": model.permissionCenter.requestMicrophone()
                        case "screen": model.permissionCenter.openScreenRecordingSettings()
                        case "accessibility": model.permissionCenter.openAccessibilitySettings()
                        default: break
                        }
                    }
                    .disabled(permission.state == .granted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: About Tab

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Transcriber")
                .font(.title2.weight(.semibold))
            Text("Version 0.1.0")
            Text("Distribution: Direct Download")
                .foregroundStyle(.secondary)
            Divider()
            Text("Automatic meeting detection, dual-track recording, on-device transcription and speaker diarization. No cloud, no LLM, no external API.")
                .foregroundStyle(.secondary)
            Text("Powered by FluidAudio, Parakeet TDT, Silero VAD, and WeSpeaker.")
                .foregroundStyle(.tertiary)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settingsStore.settings[keyPath: keyPath] },
            set: { model.settingsStore.settings[keyPath: keyPath] = $0 }
        )
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
                .frame(width: 140, alignment: .leading)
            TextField("Enter speaker name", text: $draft)
                .onSubmit { save() }
            Button("Save") { save() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(draft)
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
