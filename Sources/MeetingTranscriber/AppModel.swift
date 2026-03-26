import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .dormant
    @Published var errorMessage: String?
    @Published var namingCandidates: [NamingCandidate] = []
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

        let model = AppModel(
            settingsStore: settingsStore,
            speakerStore: speakerStore,
            queueStore: queueStore,
            modelCatalog: modelCatalog,
            permissionCenter: permissionCenter,
            recordingManager: recordingManager
        )

        if settingsStore.settings.autoWatch {
            model.startWatching()
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
        recordingManager: RecordingManager
    ) {
        self.settingsStore = settingsStore
        self.speakerStore = speakerStore
        self.queueStore = queueStore
        self.modelCatalog = modelCatalog
        self.permissionCenter = permissionCenter
        self.recordingManager = recordingManager

        self.pipelineProcessor = PipelineProcessor(
            queueStore: queueStore,
            speakerStore: speakerStore,
            settingsStore: settingsStore,
            modelCatalog: modelCatalog,
            onNamingRequired: { [weak self] candidates in
                self?.namingCandidates = candidates
                self?.phase = .userAction
            }
        )

        self.meetingDetector = MeetingDetector(
            onMeetingStarted: { [weak self] snapshot in
                guard let self else { return }
                do {
                    try self.recordingManager.startRecording(title: snapshot.title)
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
            phase = queueStore.activeJob == nil ? .dormant : .processing
        }
    }

    func mergeSelectedSpeakers() {
        let ids = Array(mergeSelection)
        guard ids.count == 2 else { return }
        speakerStore.merge(primaryID: ids[0], secondaryID: ids[1])
        mergeSelection.removeAll()
    }
}
