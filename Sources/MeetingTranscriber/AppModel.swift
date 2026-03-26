import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .dormant
    @Published var errorMessage: String?
    @Published var namingCandidates: [NamingCandidate] = []
    private var namingDismissTask: Task<Void, Never>?
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var speakerFilter = ""
    @Published var speakerSortMode: SpeakerSortMode = .lastSeen
    @Published var vocabularyDraft = ""
    @Published var mergeSelection = Set<UUID>()

    let settingsStore: SettingsStore
    let speakerStore: SpeakerStore
    let queueStore: PipelineQueueStore
    let modelCatalog: ModelCatalog
    let permissionCenter: PermissionCenter
    let recordingManager: RecordingManager
    let downloadManager: ModelDownloadManager
    var pipelineProcessor: PipelineProcessor! = nil
    var meetingDetector: MeetingDetector! = nil

    static func bootstrap() -> AppModel {
        try? FileManager.default.ensureMeetingTranscriberDirectories()

        let settingsStore = SettingsStore()
        let speakerStore = SpeakerStore()
        let queueStore = PipelineQueueStore()
        let modelCatalog = ModelCatalog()
        let permissionCenter = PermissionCenter()
        let recordingManager = RecordingManager()

        let downloadManager = ModelDownloadManager(catalog: modelCatalog)

        let model = AppModel(
            settingsStore: settingsStore,
            speakerStore: speakerStore,
            queueStore: queueStore,
            modelCatalog: modelCatalog,
            permissionCenter: permissionCenter,
            recordingManager: recordingManager,
            downloadManager: downloadManager
        )

        // Clean stale recordings (>48h), preserving files referenced by active jobs
        let activeJobPaths = Set(
            queueStore.jobs
                .filter { $0.stage != .complete }
                .flatMap { [$0.appAudioPath, $0.micAudioPath] }
        )
        TempFileCleanup.cleanStaleRecordings(activeJobPaths: activeJobPaths)

        // Sync launch-at-login state with settings
        let currentlyEnabled = LaunchAtLogin.isEnabled
        if settingsStore.settings.launchAtLogin != currentlyEnabled {
            LaunchAtLogin.setEnabled(settingsStore.settings.launchAtLogin)
        }

        if settingsStore.settings.autoWatch {
            model.startWatching()
        }

        // Retry failed jobs once on relaunch (handles transient failures from previous session)
        for var job in queueStore.jobs where job.stage == .failed {
            job.stage = .queued
            job.error = nil
            queueStore.update(job)
        }

        model.pipelineProcessor.runNextIfNeeded()
        return model
    }

    init(
        settingsStore: SettingsStore,
        speakerStore: SpeakerStore,
        queueStore: PipelineQueueStore,
        modelCatalog: ModelCatalog,
        permissionCenter: PermissionCenter,
        recordingManager: RecordingManager,
        downloadManager: ModelDownloadManager
    ) {
        self.settingsStore = settingsStore
        self.speakerStore = speakerStore
        self.queueStore = queueStore
        self.modelCatalog = modelCatalog
        self.permissionCenter = permissionCenter
        self.recordingManager = recordingManager
        self.downloadManager = downloadManager

        self.pipelineProcessor = PipelineProcessor(
            queueStore: queueStore,
            speakerStore: speakerStore,
            settingsStore: settingsStore,
            modelCatalog: modelCatalog,
            onNamingRequired: { [weak self] candidates in
                self?.namingCandidates = candidates
                self?.phase = .userAction
                self?.startNamingAutoDismiss()
            }
        )

        self.recordingManager.onMaxDurationReached = { [weak self] session in
            guard let self else { return }
            self.pipelineProcessor.enqueueFinishedRecording(session, endedAt: Date())
        }

        self.meetingDetector = MeetingDetector(
            onMeetingStarted: { [weak self] snapshot in
                guard let self else { return }
                do {
                    try self.recordingManager.startRecording(
                        title: snapshot.title,
                        teamsPID: snapshot.teamsPID
                    )
                    self.phase = .recording
                    self.errorMessage = nil
                } catch {
                    self.phase = .error
                    self.errorMessage = error.localizedDescription
                }
            },
            onMeetingEnded: { [weak self] _ in
                guard let self else { return }
                guard let session = self.recordingManager.stopRecording() else { return }
                self.pipelineProcessor.enqueueFinishedRecording(session, endedAt: Date())
                self.phase = .processing
            }
        )
    }

    var menuBarIconName: String {
        switch phase {
        case .dormant: return "mic"
        case .recording: return "record.circle.fill"
        case .processing: return "waveform.and.magnifyingglass"
        case .error: return "exclamationmark.circle.fill"
        case .userAction: return "person.crop.circle.badge.exclamationmark"
        }
    }

    var filteredSpeakers: [SpeakerProfile] {
        let filtered = speakerStore.speakers.filter {
            speakerFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(speakerFilter)
        }

        switch speakerSortMode {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .lastSeen:
            return filtered.sorted { $0.lastSeen > $1.lastSeen }
        case .meetingCount:
            return filtered.sorted { $0.meetingCount > $1.meetingCount }
        }
    }

    func startWatching() {
        meetingDetector.startWatching()
        phase = .dormant
    }

    func stopWatching() {
        meetingDetector.stopWatching()
        phase = .dormant
    }

    func toggleWatching() {
        meetingDetector.isWatching ? stopWatching() : startWatching()
    }

    func simulateMeeting() {
        meetingDetector.simulateMeetingStart(title: "Sprint Planning")
    }

    func endSimulatedMeeting() {
        meetingDetector.simulateMeetingEnd()
    }

    func acknowledgeError() {
        errorMessage = nil
        phase = .dormant
    }

    func addVocabularyTerm() {
        let term = vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 4 else { return }
        guard settingsStore.settings.customVocabulary.count < 50 else { return }
        guard !settingsStore.settings.customVocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        settingsStore.settings.customVocabulary.append(term)
        settingsStore.settings.customVocabulary.sort()
        vocabularyDraft = ""
    }

    func removeVocabularyTerm(_ term: String) {
        settingsStore.settings.customVocabulary.removeAll { $0 == term }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settingsStore.settings.launchAtLogin = enabled
        LaunchAtLogin.setEnabled(enabled)
    }

    func openSettings(tab: SettingsTab?) {
        if let tab { selectedSettingsTab = tab }
        // Open the Settings window reliably from MenuBarExtra
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Select output folder for meeting transcripts"
        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.settings.outputDirectory = url.path
        }
    }

    func chooseDefaultOutputDirectory() {
        settingsStore.settings.outputDirectory = FileManager.default.meetingTranscriberOutputDirectory.path
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true))
    }

    func openTranscript(_ job: PipelineJob) {
        guard let transcriptPath = job.transcriptPath else { return }
        NSWorkspace.shared.open(transcriptPath)
    }

    func retry(_ job: PipelineJob) {
        pipelineProcessor.retryFailedJob(job)
        phase = .processing
    }

    func dismissJob(_ job: PipelineJob) {
        // Delete associated audio files if job is complete or failed
        if job.stage == .complete || job.stage == .failed {
            let fm = FileManager.default
            try? fm.removeItem(at: job.appAudioPath)
            try? fm.removeItem(at: job.micAudioPath)
        }
        queueStore.remove(job)
    }

    func saveSpeakerName(candidate: NamingCandidate, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakerStore.upsert(
            SpeakerProfile(
                id: UUID(),
                name: trimmed,
                embeddings: [],
                firstSeen: Date(),
                lastSeen: Date(),
                meetingCount: 1
            )
        )
        namingCandidates.removeAll { $0.id == candidate.id }
        if namingCandidates.isEmpty {
            namingDismissTask?.cancel()
            namingDismissTask = nil
            phase = queueStore.activeJob == nil ? .dormant : .processing
        }
    }

    func mergeSelectedSpeakers() {
        let ids = Array(mergeSelection)
        guard ids.count == 2 else { return }
        speakerStore.merge(primaryID: ids[0], secondaryID: ids[1])
        mergeSelection.removeAll()
    }

    // MARK: - Speaker Naming Auto-Dismiss

    private func startNamingAutoDismiss() {
        namingDismissTask?.cancel()
        namingDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled else { return }
            guard !self.namingCandidates.isEmpty else { return }
            // Store remaining unnamed candidates with generic names
            for candidate in self.namingCandidates {
                self.speakerStore.upsert(
                    SpeakerProfile(
                        id: UUID(),
                        name: candidate.temporaryName,
                        embeddings: [],
                        firstSeen: Date(),
                        lastSeen: Date(),
                        meetingCount: 1
                    )
                )
            }
            self.namingCandidates.removeAll()
            self.phase = self.queueStore.activeJob == nil ? .dormant : .processing
        }
    }
}
