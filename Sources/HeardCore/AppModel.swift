import AppKit
import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var phase: AppPhase = .dormant
    @Published public var errorMessage: String?
    @Published public var namingCandidates: [NamingCandidate] = []
    private var namingDismissTask: Task<Void, Never>?
    @Published public var selectedSettingsTab: SettingsTab = .general
    @Published public var speakerFilter = ""
    @Published public var speakerSortMode: SpeakerSortMode = .lastSeen
    @Published public var vocabularyDraft = ""
    @Published public var mergeSelection = Set<UUID>()

    // Dictation state (separate from phase — can coexist with meeting recording)
    @Published public var isDictating = false
    @Published public var partialTranscript = ""
    @Published public var dictationError: String?

    public let settingsStore: SettingsStore
    public let speakerStore: SpeakerStore
    public let queueStore: PipelineQueueStore
    public let modelCatalog: ModelCatalog
    public let permissionCenter: PermissionCenter
    public let recordingManager: RecordingManager
    public let downloadManager: ModelDownloadManager
    public var pipelineProcessor: PipelineProcessor! = nil
    public var meetingDetector: MeetingDetector! = nil
    public let dictationManager: DictationManager
    public var hotkeyManager: HotkeyManager! = nil

    public static func bootstrap() -> AppModel {
        try? FileManager.default.ensureHeardDirectories()

        let settingsStore = SettingsStore()
        let speakerStore = SpeakerStore()
        let queueStore = PipelineQueueStore()
        let modelCatalog = ModelCatalog()
        let permissionCenter = PermissionCenter()
        let recordingManager = RecordingManager()

        let downloadManager = ModelDownloadManager(catalog: modelCatalog)
        let dictationManager = DictationManager()

        let model = AppModel(
            settingsStore: settingsStore,
            speakerStore: speakerStore,
            queueStore: queueStore,
            modelCatalog: modelCatalog,
            permissionCenter: permissionCenter,
            recordingManager: recordingManager,
            downloadManager: downloadManager,
            dictationManager: dictationManager
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

        // Wire dictation: text injection on finalized utterances
        dictationManager.onUtterance = { text in
            TextInjector.inject(text)
        }

        // Activate hotkey if dictation is enabled
        if settingsStore.settings.dictationEnabled {
            model.hotkeyManager = HotkeyManager(hotkey: settingsStore.settings.dictationHotkey) {
                [weak model] in
                model?.toggleDictation()
            }
            model.hotkeyManager.activate()
        }

        return model
    }

    public init(
        settingsStore: SettingsStore,
        speakerStore: SpeakerStore,
        queueStore: PipelineQueueStore,
        modelCatalog: ModelCatalog,
        permissionCenter: PermissionCenter,
        recordingManager: RecordingManager,
        downloadManager: ModelDownloadManager,
        dictationManager: DictationManager
    ) {
        self.settingsStore = settingsStore
        self.speakerStore = speakerStore
        self.queueStore = queueStore
        self.modelCatalog = modelCatalog
        self.permissionCenter = permissionCenter
        self.recordingManager = recordingManager
        self.downloadManager = downloadManager
        self.dictationManager = dictationManager

        self.pipelineProcessor = PipelineProcessor(
            queueStore: queueStore,
            speakerStore: speakerStore,
            settingsStore: settingsStore,
            modelCatalog: modelCatalog,
            onNamingRequired: { [weak self] candidates in
                self?.namingCandidates = candidates
                self?.phase = .userAction
                self?.startNamingAutoDismiss()
            },
            onPipelineIdle: { [weak self] in
                guard let self else { return }
                if self.phase == .processing {
                    self.phase = .dormant
                }
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
                        teamsPID: snapshot.teamsPID,
                        rosterNames: snapshot.rosterNames
                    )
                    self.phase = .recording
                    self.errorMessage = nil
                } catch {
                    self.phase = .error
                    self.errorMessage = error.localizedDescription
                }
            },
            onMeetingEnded: { [weak self] snapshot in
                guard let self else { return }
                // Update the recording session with the final accumulated roster names
                self.recordingManager.updateRosterNames(snapshot.rosterNames)
                guard let session = self.recordingManager.stopRecording() else { return }
                self.pipelineProcessor.enqueueFinishedRecording(session, endedAt: Date())
                self.phase = .processing
            }
        )
    }

    public var menuBarIconName: String {
        if isDictating { return "mic.fill" }
        switch phase {
        case .dormant: return "mic"
        case .recording: return "record.circle.fill"
        case .processing: return "waveform.and.magnifyingglass"
        case .error: return "exclamationmark.circle.fill"
        case .userAction: return "person.crop.circle.badge.exclamationmark"
        }
    }

    public var filteredSpeakers: [SpeakerProfile] {
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

    public func startWatching() {
        meetingDetector.startWatching()
        phase = .dormant
    }

    public func stopWatching() {
        meetingDetector.stopWatching()
        phase = .dormant
    }

    public func toggleWatching() {
        meetingDetector.isWatching ? stopWatching() : startWatching()
    }

    // MARK: - Dictation

    public func toggleDictation() {
        Task {
            if isDictating {
                await dictationManager.stop()
                isDictating = false
                partialTranscript = ""
                dictationError = nil
            } else {
                do {
                    try await dictationManager.start()
                    isDictating = true
                    dictationError = nil
                    // Observe partial transcript updates
                    observeDictationPartials()
                } catch {
                    dictationError = error.localizedDescription
                    NSLog("Heard: Dictation start failed: \(error)")
                }
            }
        }
    }

    public func setDictationEnabled(_ enabled: Bool) {
        settingsStore.settings.dictationEnabled = enabled
        objectWillChange.send()
        if enabled {
            // Prompt for Accessibility permission (needed for text injection)
            TextInjector.ensureAccessibility()

            if hotkeyManager == nil {
                hotkeyManager = HotkeyManager(hotkey: settingsStore.settings.dictationHotkey) {
                    [weak self] in
                    self?.toggleDictation()
                }
            }
            hotkeyManager.activate()
        } else {
            hotkeyManager?.deactivate()
            if isDictating {
                toggleDictation()
            }
        }
    }

    public func updateDictationHotkey(_ hotkey: HotkeyCombo) {
        settingsStore.settings.dictationHotkey = hotkey
        hotkeyManager?.updateHotkey(hotkey)
    }

    private func observeDictationPartials() {
        Task { [weak self] in
            guard let self else { return }
            // Poll the dictation manager's partial transcript (lightweight since it's @Published)
            while self.isDictating {
                self.partialTranscript = self.dictationManager.partialTranscript
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func simulateMeeting() {
        meetingDetector.simulateMeetingStart(title: "Sprint Planning")
    }

    public func endSimulatedMeeting() {
        meetingDetector.simulateMeetingEnd()
    }

    public func acknowledgeError() {
        errorMessage = nil
        phase = .dormant
    }

    public func addVocabularyTerm() {
        let term = vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 3 else { return }
        guard settingsStore.settings.customVocabulary.count < 50 else { return }
        guard !settingsStore.settings.customVocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        settingsStore.settings.customVocabulary.append(term)
        settingsStore.settings.customVocabulary.sort()
        vocabularyDraft = ""
    }

    public func removeVocabularyTerm(_ term: String) {
        settingsStore.settings.customVocabulary.removeAll { $0 == term }
        objectWillChange.send()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        settingsStore.settings.launchAtLogin = enabled
        LaunchAtLogin.setEnabled(enabled)
    }

    public func openSettings(tab: SettingsTab?) {
        if let tab { selectedSettingsTab = tab }
        // Open the Settings window reliably from MenuBarExtra
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func chooseOutputDirectory() {
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

    public func chooseDefaultOutputDirectory() {
        settingsStore.settings.outputDirectory = FileManager.default.heardOutputDirectory.path
    }

    public func openOutputDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true))
    }

    public func openTranscript(_ job: PipelineJob) {
        guard let transcriptPath = job.transcriptPath else { return }
        NSWorkspace.shared.open(transcriptPath)
    }

    public func retry(_ job: PipelineJob) {
        pipelineProcessor.retryFailedJob(job)
        phase = .processing
    }

    public func dismissJob(_ job: PipelineJob) {
        // Delete associated audio files if job is complete or failed
        if job.stage == .complete || job.stage == .failed {
            let fm = FileManager.default
            try? fm.removeItem(at: job.appAudioPath)
            try? fm.removeItem(at: job.micAudioPath)
        }
        queueStore.remove(job)
    }

    public func saveSpeakerName(candidate: NamingCandidate, name: String) {
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

    public func mergeSelectedSpeakers() {
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
