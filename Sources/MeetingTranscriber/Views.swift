import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.phase.title)
                    .font(.headline)

                if let session = model.recordingManager.activeSession {
                    Text("\(session.title) in progress")
                        .foregroundStyle(.secondary)
                } else if let job = model.queueStore.activeJob {
                    Text("\(job.meetingTitle) • \(job.stage.displayName)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.meetingDetector.isWatching ? "Auto-watch enabled" : "Idle")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Jobs")
                    .font(.subheadline.weight(.semibold))

                if model.queueStore.recentJobs.isEmpty {
                    Text("No meetings processed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.queueStore.recentJobs) { job in
                        HStack {
                            Text(job.meetingTitle)
                                .lineLimit(1)
                            Spacer()
                            Text(job.stage.displayName)
                                .foregroundStyle(job.stage == .failed ? .red : .secondary)
                            if job.transcriptPath != nil {
                                Button("Open") { model.openTranscript(job) }
                                    .buttonStyle(.link)
                            } else if job.stage == .failed {
                                Button("Retry") { model.retry(job) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
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
                    Button("Name Speakers") {
                        model.selectedSettingsTab = .speakers
                    }
                }

                Button("Open Protocols Folder") {
                    model.openOutputDirectory()
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedSettingsTab) {
            Form {
                TextField("Your Name", text: settingsBinding(\.userName))
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.settingsStore.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Auto-Watch", isOn: settingsBinding(\.autoWatch))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Folder")
                    TextField("Output Folder", text: settingsBinding(\.outputDirectory))
                    HStack {
                        Button("Reset to Default") { model.chooseDefaultOutputDirectory() }
                        Button("Open") { model.openOutputDirectory() }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsTab.general)

            VStack(alignment: .leading, spacing: 16) {
                Text("Custom Vocabulary")
                    .font(.headline)

                HStack {
                    TextField("Add a term", text: $model.vocabularyDraft)
                    Button("Add") { model.addVocabularyTerm() }
                }

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

                Divider()

                Text("Model Status")
                    .font(.headline)

                ForEach(model.modelCatalog.statuses) { item in
                    HStack {
                        Text(item.modelKind.displayName)
                        Spacer()
                        Text(item.detail)
                            .foregroundStyle(item.availability == .ready ? .green : .secondary)
                    }
                }
            }
            .tabItem { Label("Transcription", systemImage: "waveform") }
            .tag(SettingsTab.transcription)

            VStack(spacing: 12) {
                Text("Coming in v2")
                    .font(.title3.weight(.semibold))
                Text("The microphone publisher and model catalog leave room for streaming dictation.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("Dictation", systemImage: "mic.badge.plus") }
            .tag(SettingsTab.dictation)

            VStack(alignment: .leading, spacing: 16) {
                if !model.namingCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Speaker Naming")
                            .font(.headline)
                        ForEach(model.namingCandidates) { candidate in
                            NamingCandidateRow(candidate: candidate) { name in
                                model.saveSpeakerName(candidate: candidate, name: name)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Search speakers", text: $model.speakerFilter)
                    Picker("Sort", selection: $model.speakerSortMode) {
                        ForEach(SpeakerSortMode.allCases) { sortMode in
                            Text(sortMode.rawValue.capitalized).tag(sortMode)
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
            }
            .tabItem { Label("Speakers", systemImage: "person.3") }
            .tag(SettingsTab.speakers)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.permissionCenter.statuses) { permission in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.title)
                                .font(.headline)
                            Text(permission.purpose)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(permission.state.badge)
                            .foregroundStyle(permission.state == .granted ? .green : .orange)
                        Button("Grant") {
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
            }
            .tabItem { Label("Permissions", systemImage: "lock.shield") }
            .tag(SettingsTab.permissions)

            VStack(alignment: .leading, spacing: 12) {
                Text("Meeting Transcriber")
                    .font(.title2.weight(.semibold))
                Text("Version 0.1.0")
                Text("Distribution: Direct Download")
                Text("Build scaffolds the menu bar app, persistence layer, and processing pipeline integration points.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tabItem { Label("About", systemImage: "info.circle") }
            .tag(SettingsTab.about)
        }
        .padding(20)
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settingsStore.settings[keyPath: keyPath] },
            set: { model.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }
}

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
            Button("Save") {
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                onSave(draft)
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
