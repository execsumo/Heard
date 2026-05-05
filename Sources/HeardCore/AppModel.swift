import AppKit
import Combine
import Foundation

@MainActor
public final class AppModel: ObservableObject {
    @Published public var phase: AppPhase = .dormant
    @Published public var errorMessage: String?
    @Published public var namingCandidates: [NamingCandidate] = []
    /// Set to true when naming prompt should be shown. Observed by the naming window scene.
    @Published public var showNamingPrompt = false
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
    /// Set when AX permission is revoked while dictation is active. Cleared on dismiss or next start.
    @Published public var dictationAXLost = false
    // Prevents concurrent toggles: rapid hotkey presses during start/stop are dropped.
    private var dictationToggleInFlight = false

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

    private var cancellables = Set<AnyCancellable>()

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

        // Propagate persisted model version to managers before first use
        let savedVersion = settingsStore.settings.transcriptionModel
        downloadManager.transcriptionModel = savedVersion
        dictationManager.modelVersion = savedVersion

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

        // Destroy orphaned private aggregate devices left behind by previous crashes
        AudioDeviceCleanup.cleanOrphanAggregateDevices()

        recordingManager.onAppAudioCaptureConfirmed = { [weak permissionCenter] in
            permissionCenter?.markAudioCaptureGranted()
        }

        // Sync launch-at-login state with settings
        let currentlyEnabled = LaunchAtLogin.isEnabled
        if settingsStore.settings.launchAtLogin != currentlyEnabled {
            LaunchAtLogin.setEnabled(settingsStore.settings.launchAtLogin)
        }

        if settingsStore.settings.autoWatch {
            model.startWatching()
        }

        // Retry failed jobs once on relaunch (handles transient failures from previous session)
        queueStore.prepareForResume()

        model.pipelineProcessor.runNextIfNeeded()

        // Wire dictation: text injection on finalized utterances
        dictationManager.onUtterance = { text in
            TextInjector.inject(text)
        }

        // Activate hotkey if dictation is enabled
        if settingsStore.settings.dictationEnabled {
            model.setupHotkeyManager()
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
                NSLog("Heard: AppModel.onNamingRequired received \(candidates.count) candidate(s) — opening naming window")
                self?.namingCandidates = candidates
                self?.phase = .userAction
                self?.showNamingPrompt = true
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

        // Forward child store changes so SwiftUI views observing `AppModel`
        // re-render when nested ObservableObjects update (queue progresses through
        // stages, recording session changes, etc.). Without this bridge, the menu
        // bar status header stays frozen on whatever it showed at the last
        // AppModel.objectWillChange event.
        queueStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        recordingManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

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
        // stopWatching may synchronously fire onMeetingEnded (which sets phase = .processing).
        // Only fall back to .dormant when no meeting was active.
        let phaseBefore = phase
        meetingDetector.stopWatching()
        if phase == phaseBefore {
            phase = .dormant
        }
    }

    public func toggleWatching() {
        meetingDetector.isWatching ? stopWatching() : startWatching()
    }

    // MARK: - Dictation

    public func toggleDictation() {
        // Drop rapid presses while a start/stop is already in progress.
        guard !dictationToggleInFlight else { return }
        dictationToggleInFlight = true
        Task {
            defer { dictationToggleInFlight = false }
            if isDictating {
                dictationManager.modelKeepAliveSeconds = settingsStore.settings.dictationKeepAlive
                await dictationManager.stop()
                isDictating = false
                partialTranscript = ""
                dictationError = nil
                if settingsStore.settings.showDictationHUD { DictationHUD.shared.hide() }
            } else {
                do {
                    dictationAXLost = false
                    dictationManager.customVocabulary = settingsStore.settings.customVocabulary
                    dictationManager.modelVersion = settingsStore.settings.transcriptionModel
                    dictationManager.modelKeepAliveSeconds = settingsStore.settings.dictationKeepAlive
                    try await dictationManager.start()
                    isDictating = true
                    dictationError = nil
                    if settingsStore.settings.showDictationHUD { DictationHUD.shared.show() }
                    // Observe partial transcript and watch for AX revocation
                    observeDictationPartials()
                    startAXPolling()
                } catch {
                    isDictating = false
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
            setupHotkeyManager()
        } else {
            hotkeyManager?.deactivate()
            if isDictating {
                toggleDictation()
            }
        }
    }

    public func setPushToTalk(_ enabled: Bool) {
        settingsStore.settings.pushToTalk = enabled
        objectWillChange.send()
        // Stop dictation if currently active, so the mode switch is clean
        if isDictating {
            toggleDictation()
        }
        // Re-wire hotkey callbacks for the new mode
        if settingsStore.settings.dictationEnabled {
            hotkeyManager?.deactivate()
            setupHotkeyManager()
        }
    }

    public func updateDictationHotkey(_ hotkey: HotkeyCombo) {
        settingsStore.settings.dictationHotkey = hotkey
        hotkeyManager?.updateHotkey(hotkey)
    }

    public func setTranscriptionModel(_ version: TranscriptionModel) {
        settingsStore.settings.transcriptionModel = version
        // Propagate to managers so the next start/download uses the right version
        dictationManager.modelVersion = version
        downloadManager.transcriptionModel = version
        downloadManager.refreshStatuses()
        objectWillChange.send()
    }

    private func setupHotkeyManager() {
        let pushToTalk = settingsStore.settings.pushToTalk
        hotkeyManager = HotkeyManager(
            hotkey: settingsStore.settings.dictationHotkey,
            onPressed: { [weak self] in
                guard let self else { return }
                if pushToTalk {
                    // Push-to-talk: start on press
                    if !self.isDictating { self.toggleDictation() }
                } else {
                    // Toggle mode: flip on press
                    self.toggleDictation()
                }
            },
            onReleased: { [weak self] in
                guard let self else { return }
                if pushToTalk {
                    // Push-to-talk: stop on release
                    if self.isDictating { self.toggleDictation() }
                }
            }
        )
        hotkeyManager.activate()
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

    /// Polls AXIsProcessTrusted() while dictation is active. If access is revoked mid-session,
    /// stops dictation and raises dictationAXLost so the menu bar can show a re-grant banner.
    private func startAXPolling() {
        Task { [weak self] in
            while self?.isDictating == true {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isDictating else { break }
                if !AXIsProcessTrusted() {
                    self.dictationAXLost = true
                    self.isDictating = false
                    if self.settingsStore.settings.showDictationHUD { DictationHUD.shared.hide() }
                    await self.dictationManager.stop()
                    NSLog("Heard: Dictation stopped — Accessibility access revoked mid-session")
                    break
                }
            }
        }
    }

    public func acknowledgeAXLost() {
        dictationAXLost = false
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
        // Move the audio clips to their persistent home so they survive the 48-hour
        // recordings cleanup and can be replayed from the Speakers settings tab.
        let persistedClips = candidate.audioClipURLs.compactMap { AudioClipExtractor.persistClip($0) }
        speakerStore.upsert(
            SpeakerProfile(
                id: UUID(),
                name: trimmed,
                embeddings: candidate.embedding.isEmpty ? [] : [candidate.embedding],
                firstSeen: Date(),
                lastSeen: Date(),
                meetingCount: 1,
                totalSpeechDuration: candidate.totalSpeechDuration,
                totalWordCount: candidate.totalWordCount,
                audioClipURLs: persistedClips
            )
        )
        // Rewrite every transcript that references the placeholder. Speaker
        // numbers are globally unique, so this normally only touches the one
        // transcript in `candidate.transcriptPath`, but scanning the output
        // directory keeps the rename complete if the user moved/renamed files
        // or if the placeholder ever shows up in more than one transcript.
        let outputDir = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
        TranscriptWriter.renameSpeakerInDirectory(outputDir, from: candidate.temporaryName, to: trimmed)
        if let transcriptPath = candidate.transcriptPath,
           transcriptPath.deletingLastPathComponent().standardizedFileURL != outputDir.standardizedFileURL {
            TranscriptWriter.renameSpeaker(in: transcriptPath, from: candidate.temporaryName, to: trimmed)
        }
        namingCandidates.removeAll { $0.id == candidate.id }
        if namingCandidates.isEmpty {
            namingDismissTask?.cancel()
            namingDismissTask = nil
            showNamingPrompt = false
            phase = queueStore.processingJob == nil ? .dormant : .processing
        }
    }

    public func skipNaming() {
        // Store remaining unnamed candidates with generic names (preserving embeddings + clips).
        for candidate in namingCandidates {
            let persistedClips = candidate.audioClipURLs.compactMap { AudioClipExtractor.persistClip($0) }
            speakerStore.upsert(
                SpeakerProfile(
                    id: UUID(),
                    name: candidate.temporaryName,
                    embeddings: candidate.embedding.isEmpty ? [] : [candidate.embedding],
                    firstSeen: Date(),
                    lastSeen: Date(),
                    meetingCount: 1,
                    audioClipURLs: persistedClips
                )
            )
        }
        namingCandidates.removeAll()
        namingDismissTask?.cancel()
        namingDismissTask = nil
        showNamingPrompt = false
        phase = queueStore.activeJob == nil ? .dormant : .processing
    }

    public func renameSpeaker(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        guard let oldProfile = speakerStore.speakers.first(where: { $0.id == id }) else { return }
        let oldName = oldProfile.name
        guard oldName != trimmed else { return }

        speakerStore.rename(id: id, to: trimmed)

        // Prompt the user before retroactively renaming
        if askUserToUpdateTranscripts(oldName: oldName, newName: trimmed) {
            let outputDir = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
            TranscriptWriter.renameSpeakerInDirectory(outputDir, from: oldName, to: trimmed)
        }
    }

    public func mergeSelectedSpeakers() {
        let ids = Array(mergeSelection)
        guard ids.count == 2 else { return }
        
        if let primary = speakerStore.speakers.first(where: { $0.id == ids[0] }),
           let secondary = speakerStore.speakers.first(where: { $0.id == ids[1] }) {
            
            // Prompt the user before retroactively renaming
            if askUserToUpdateTranscripts(oldName: secondary.name, newName: primary.name) {
                let outputDir = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
                TranscriptWriter.renameSpeakerInDirectory(outputDir, from: secondary.name, to: primary.name)
            }
        }

        speakerStore.merge(primaryID: ids[0], secondaryID: ids[1])
        mergeSelection.removeAll()
    }

    private func askUserToUpdateTranscripts(oldName: String, newName: String) -> Bool {
        // If it's a generated placeholder, there's no need to ask, just do it.
        // The user only needs to be asked if they are renaming an already explicitly named speaker.
        if SpeakerMatcher.isPlaceholderName(oldName) {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Update past transcripts?"
        alert.informativeText = "Would you like to retroactively replace '\(oldName)' with '\(newName)' in all previously saved transcripts?"
        alert.addButton(withTitle: "Update Transcripts")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }



    // MARK: - Speaker Naming Auto-Dismiss

    private func startNamingAutoDismiss() {
        namingDismissTask?.cancel()
        namingDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled else { return }
            guard !self.namingCandidates.isEmpty else { return }
            self.skipNaming()
        }
    }
}
