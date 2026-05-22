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
    @Published public var selectedSettingsTab: SettingsTab = .general
    @Published public var speakerFilter = ""
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
    // Tracks whether the push-to-talk key is currently held. Set on press, cleared on release.
    // Used to detect key-up events that arrive before model loading completes.
    private var pushToTalkKeyHeld = false

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
    public var meetingNoteHotkeyManager: HotkeyManager! = nil
    public let updateChecker: UpdateChecker

    private var cancellables = Set<AnyCancellable>()
    private var stageWatchdogTimer: Timer?
    private var namingDismissTask: Task<Void, Never>?
    // 90 minutes is generous for any realistic workload (4-hour meeting transcription
    // on slow hardware). A genuine FluidAudio hang shows up well within this window.
    private static let maxStageSeconds: TimeInterval = 90 * 60

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
        let updateChecker = UpdateChecker()

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
            dictationManager: dictationManager,
            updateChecker: updateChecker
        )

        // Archive speaker profiles inactive beyond the configured retention window
        speakerStore.archiveInactiveSpeakers(retentionDays: settingsStore.settings.speakerRetentionDays)

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

        // Apply dock icon visibility
        WindowActivationCoordinator.persistentDockIcon = settingsStore.settings.showDockIcon
        WindowActivationCoordinator.syncPolicy()

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

        // Note hotkey is always active — checks recording state when fired
        model.setupMeetingNoteHotkey()

        // Defer update check so it doesn't block app startup
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            model.updateChecker.checkIfNeeded()
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
        dictationManager: DictationManager,
        updateChecker: UpdateChecker
    ) {
        self.settingsStore = settingsStore
        self.speakerStore = speakerStore
        self.queueStore = queueStore
        self.modelCatalog = modelCatalog
        self.permissionCenter = permissionCenter
        self.recordingManager = recordingManager
        self.downloadManager = downloadManager
        self.dictationManager = dictationManager
        self.updateChecker = updateChecker

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
        pipelineProcessor.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settingsStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateChecker.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        self.meetingDetector = MeetingDetector(
            enabledSources: { [weak self] in
                guard let self else { return Set(MeetingApp.allCases) }
                var enabled: Set<MeetingApp> = []
                let s = self.settingsStore.settings
                if s.enableTeamsDetection { enabled.insert(.teams) }
                if s.enableZoomDetection { enabled.insert(.zoom) }
                if s.enableWebexDetection { enabled.insert(.webex) }
                return enabled
            },
            onMeetingStarted: { [weak self] snapshot in
                guard let self else { return }
                // Stop dictation before recording starts — mic should not transcribe
                // remote participants' audio (which the mic picks up from speakers).
                self.stopDictationIfActive()
                do {
                    try self.recordingManager.startRecording(
                        title: snapshot.title,
                        meetingPID: snapshot.meetingPID,
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

        meetingDetector.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        stageWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForStuckPipelineStage()
            }
        }
    }

    private func checkForStuckPipelineStage() {
        guard pipelineProcessor.isProcessing,
              let job = queueStore.processingJob,
              let stageStart = job.stageStartTime,
              Date().timeIntervalSince(stageStart) > Self.maxStageSeconds else { return }
        NSLog("Heard: pipeline stage '\(job.stage)' stuck for >90 min — aborting job")
        pipelineProcessor.abortAndFailCurrentJob()
    }

public var filteredSpeakers: [SpeakerProfile] {
        speakerStore.speakers.filter {
            speakerFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(speakerFilter)
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
        setAutoWatch(!meetingDetector.isWatching)
    }

    public func setAutoWatch(_ enabled: Bool) {
        settingsStore.settings.autoWatch = enabled
        if enabled {
            if !meetingDetector.isWatching { startWatching() }
        } else {
            if meetingDetector.isWatching { stopWatching() }
        }
    }

    // MARK: - Dictation

    public func toggleDictation() {
        // Drop rapid presses while a start/stop is already in progress.
        guard !dictationToggleInFlight else { return }
        // Don't start dictation while a meeting is being recorded.
        if !isDictating && recordingManager.activeSession != nil { return }
        dictationToggleInFlight = true
        Task {
            defer { dictationToggleInFlight = false }
            if isDictating {
                dictationManager.modelKeepAliveSeconds = TimeInterval(settingsStore.settings.modelKeepAlive * 60)
                await dictationManager.stop()
                isDictating = false
                partialTranscript = ""
                dictationError = nil
                if settingsStore.settings.showDictationHUD { DictationHUD.shared.hide() }
            } else {
                do {
                    dictationAXLost = false
                    dictationManager.customVocabulary = settingsStore.settings.customVocabulary
                    dictationManager.formattingCommands = settingsStore.settings.formattingCommands
                    dictationManager.modelVersion = settingsStore.settings.transcriptionModel
                    dictationManager.modelKeepAliveSeconds = TimeInterval(settingsStore.settings.modelKeepAlive * 60)
                    try await dictationManager.start()
                    // Push-to-talk race: if the key was released before loading finished,
                    // stop immediately rather than leaving dictation stuck on.
                    if settingsStore.settings.pushToTalk && !pushToTalkKeyHeld {
                        dictationManager.modelKeepAliveSeconds = TimeInterval(settingsStore.settings.modelKeepAlive * 60)
                        await dictationManager.stop()
                        dictationError = nil
                        return
                    }
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

    // MARK: - In-Meeting Notes

    public func updateMeetingNoteHotkey(_ hotkey: HotkeyCombo) {
        settingsStore.settings.meetingNoteHotkey = hotkey
        meetingNoteHotkeyManager?.updateHotkey(hotkey)
    }

    private func setupMeetingNoteHotkey() {
        meetingNoteHotkeyManager = HotkeyManager(
            id: 2,
            hotkey: settingsStore.settings.meetingNoteHotkey,
            onPressed: { [weak self] in self?.presentMeetingNoteComposer() }
        )
        meetingNoteHotkeyManager.activate()
    }

    /// Open the note composer. During an active recording the note is attached to
    /// that session and interleaved into the final transcript. Outside of a meeting
    /// it writes a standalone Markdown file to the user's output folder.
    public func presentMeetingNoteComposer() {
        if let session = recordingManager.activeSession {
            MeetingNoteComposer.shared.present(
                meetingTitle: session.title,
                recordingStart: session.startTime,
                onSubmit: { [weak self] openedAt, text in
                    self?.commitMeetingNote(openedAt: openedAt, text: text)
                }
            )
        } else {
            MeetingNoteComposer.shared.present(
                meetingTitle: "",
                recordingStart: nil,
                onSubmit: { [weak self] openedAt, text in
                    self?.commitStandaloneNote(at: openedAt, text: text)
                }
            )
        }
    }

    private func commitMeetingNote(openedAt: Date, text: String) {
        // Common path: still recording — append directly to the active session
        // and the note rides into the PipelineJob when recording stops.
        if recordingManager.activeSession != nil {
            recordingManager.addNote(at: openedAt, text: text)
            return
        }
        // Fallback: composer was open when the meeting ended. Find the
        // matching just-enqueued job and attach there instead.
        let attached = pipelineProcessor.attachNoteToFinishedJob(at: openedAt, text: text)
        if !attached {
            NSLog("Heard: Discarded meeting note — no active session and no matching job found.")
        }
    }

    private func commitStandaloneNote(at date: Date, text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: date)
        let outputDir = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)

        var candidate = outputDir.appendingPathComponent("\(timestamp)_note.md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("\(timestamp)_note_\(suffix).md")
            suffix += 1
        }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let content = "# Note\n\n**Date:** \(displayFormatter.string(from: date))\n\n---\n\n\(text)\n"

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try content.write(to: candidate, atomically: true, encoding: .utf8)
            NSLog("Heard: Standalone note saved to \(candidate.path)")
        } catch {
            NSSound.beep()
            errorMessage = "Could not save note: \(error.localizedDescription)"
            NSLog("Heard: Failed to save standalone note: \(error)")
        }
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
            id: 1,
            hotkey: settingsStore.settings.dictationHotkey,
            onPressed: { [weak self] in
                guard let self else { return }
                if pushToTalk {
                    self.pushToTalkKeyHeld = true
                    if !self.isDictating { self.toggleDictation() }
                } else {
                    self.toggleDictation()
                }
            },
            onReleased: { [weak self] in
                guard let self else { return }
                if pushToTalk {
                    self.pushToTalkKeyHeld = false
                    // Normal case: key released after dictation started.
                    // The race case (released during load) is handled inside toggleDictation().
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

    /// Unconditionally stops dictation if it is active. Used for externally-triggered stops
    /// (e.g. meeting start) that must succeed regardless of dictationToggleInFlight.
    private func stopDictationIfActive() {
        guard isDictating else { return }
        Task {
            dictationManager.modelKeepAliveSeconds = TimeInterval(settingsStore.settings.modelKeepAlive * 60)
            await dictationManager.stop()
            isDictating = false
            partialTranscript = ""
            dictationError = nil
            if settingsStore.settings.showDictationHUD { DictationHUD.shared.hide() }
            NSLog("Heard: Dictation stopped — meeting recording started")
        }
    }

    public func simulateMeeting() {
        meetingDetector.simulateMeetingStart(title: "Sprint Planning")
    }

    public func endSimulatedMeeting() {
        meetingDetector.simulateMeetingEnd()
    }

    public func startManualRecording() {
        guard recordingManager.activeSession == nil else { return }
        stopDictationIfActive()
        do {
            try recordingManager.startRecording(title: "Manual Recording", meetingPID: nil, rosterNames: [])
            phase = .recording
            errorMessage = nil
        } catch {
            phase = .error
            errorMessage = error.localizedDescription
        }
    }

    public func stopManualRecording() {
        guard let session = recordingManager.stopRecording() else { return }
        pipelineProcessor.enqueueFinishedRecording(session, endedAt: Date())
        phase = .processing
    }

    public func acknowledgeError() {
        errorMessage = nil
        phase = .dormant
    }

    public func addVocabularyTerm() {
        let term = vocabularyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return }
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

    public func addFormattingCommand(spoken: String, written: String) {
        let cleanSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanWritten = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSpoken.isEmpty && !cleanWritten.isEmpty else { return }
        // Don't add if spoken phrase already exists
        guard !settingsStore.settings.formattingCommands.contains(where: { $0.spoken == cleanSpoken }) else { return }
        
        let newCommand = FormattingCommand(spoken: cleanSpoken, written: cleanWritten)
        settingsStore.settings.formattingCommands.append(newCommand)
        objectWillChange.send()
    }

    public func removeFormattingCommand(id: UUID) {
        settingsStore.settings.formattingCommands.removeAll { $0.id == id }
        objectWillChange.send()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        settingsStore.settings.launchAtLogin = enabled
        LaunchAtLogin.setEnabled(enabled)
    }

    public func setDockIconVisible(_ visible: Bool) {
        settingsStore.settings.showDockIcon = visible
        WindowActivationCoordinator.persistentDockIcon = visible
        WindowActivationCoordinator.syncPolicy()
        objectWillChange.send()
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
                totalMeetingDuration: candidate.totalMeetingDuration,
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
            showNamingPrompt = false
            phase = queueStore.processingJob == nil ? .dormant : .processing
        }
    }

    /// Drop a candidate without creating a SpeakerProfile. Used when the user
    /// listens to the clips and realizes diarization collapsed two voices into
    /// one cluster — saving would poison the speaker database with a merged
    /// embedding. The transcript keeps the placeholder ("Speaker N"). The
    /// temporary clip files are deleted since they aren't going anywhere.
    public func discardCandidate(_ candidate: NamingCandidate) {
        for url in candidate.audioClipURLs {
            try? FileManager.default.removeItem(at: url)
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

        // Prefer the human-given name: if ids[0] is a placeholder but ids[1] is not,
        // swap so the real name survives as primary.
        var primaryID = ids[0]
        var secondaryID = ids[1]
        if let p0 = speakerStore.speakers.first(where: { $0.id == ids[0] }),
           let p1 = speakerStore.speakers.first(where: { $0.id == ids[1] }),
           SpeakerMatcher.isPlaceholderName(p0.name) && !SpeakerMatcher.isPlaceholderName(p1.name) {
            primaryID = ids[1]
            secondaryID = ids[0]
        }

        if let primary = speakerStore.speakers.first(where: { $0.id == primaryID }),
           let secondary = speakerStore.speakers.first(where: { $0.id == secondaryID }) {
            if askUserToUpdateTranscripts(oldName: secondary.name, newName: primary.name) {
                let outputDir = URL(fileURLWithPath: settingsStore.settings.outputDirectory, isDirectory: true)
                TranscriptWriter.renameSpeakerInDirectory(outputDir, from: secondary.name, to: primary.name)
            }
        }

        speakerStore.merge(primaryID: primaryID, secondaryID: secondaryID)
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



}
