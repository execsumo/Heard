import Foundation

public enum AppPhase: String, Codable, CaseIterable {
    case dormant
    case recording
    case processing
    case error
    case userAction

    public var title: String {
        switch self {
        case .dormant: return "Watching"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .error: return "Error"
        case .userAction: return "Name Speakers"
        }
    }
}

public enum PipelineStage: String, Codable, CaseIterable, Identifiable {
    case queued
    case preprocessing
    case transcribing
    case diarizing
    case assigning
    case complete
    case failed

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public struct PipelineJob: Codable, Identifiable, Equatable {
    public let id: UUID
    public var meetingTitle: String
    public let startTime: Date
    public let endTime: Date
    public let appAudioPath: URL
    public let micAudioPath: URL
    public var transcriptPath: URL?
    public var stage: PipelineStage
    public var stageStartTime: Date?
    public var error: String?
    public var retryCount: Int
    public var rosterNames: [String]

    public init(
        id: UUID,
        meetingTitle: String,
        startTime: Date,
        endTime: Date,
        appAudioPath: URL,
        micAudioPath: URL,
        transcriptPath: URL?,
        stage: PipelineStage,
        stageStartTime: Date?,
        error: String?,
        retryCount: Int,
        rosterNames: [String] = []
    ) {
        self.id = id
        self.meetingTitle = meetingTitle
        self.startTime = startTime
        self.endTime = endTime
        self.appAudioPath = appAudioPath
        self.micAudioPath = micAudioPath
        self.transcriptPath = transcriptPath
        self.stage = stage
        self.stageStartTime = stageStartTime
        self.error = error
        self.retryCount = retryCount
        self.rosterNames = rosterNames
    }
}

public struct SpeakerProfile: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var embeddings: [[Float]]
    public var firstSeen: Date
    public var lastSeen: Date
    public var meetingCount: Int

    public init(
        id: UUID,
        name: String,
        embeddings: [[Float]],
        firstSeen: Date,
        lastSeen: Date,
        meetingCount: Int
    ) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.meetingCount = meetingCount
    }
}

public struct NamingCandidate: Identifiable, Equatable {
    public let id: UUID
    public var temporaryName: String
    public var suggestedName: String?
    public var audioClipURL: URL?
    public var embedding: [Float]

    public init(
        id: UUID,
        temporaryName: String,
        suggestedName: String? = nil,
        audioClipURL: URL? = nil,
        embedding: [Float] = []
    ) {
        self.id = id
        self.temporaryName = temporaryName
        self.suggestedName = suggestedName
        self.audioClipURL = audioClipURL
        self.embedding = embedding
    }
}

public enum PermissionState: String, Codable, CaseIterable, Identifiable {
    case unknown
    case granted
    case recommended

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .unknown: return "Unknown"
        case .granted: return "Granted"
        case .recommended: return "Recommended"
        }
    }
}

public struct PermissionStatus: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let purpose: String
    public var state: PermissionState

    public init(id: String, title: String, purpose: String, state: PermissionState) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.state = state
    }
}

public enum SpeakerSortMode: String, CaseIterable, Identifiable {
    case name
    case lastSeen
    case meetingCount

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .lastSeen: return "Last Seen"
        case .meetingCount: return "Meeting Count"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public var userName: String
    public var launchAtLogin: Bool
    public var autoWatch: Bool
    public var outputDirectory: String
    public var customVocabulary: [String]
    public var developerMode: Bool
    public var dictationEnabled: Bool
    public var dictationHotkey: HotkeyCombo
    public var pushToTalk: Bool
    /// How long to keep dictation models loaded after stopping (seconds). 0 = unload immediately.
    public var dictationKeepAlive: TimeInterval
    /// How long to keep transcription/diarization models loaded after pipeline processing (seconds). 0 = unload immediately.
    public var pipelineKeepAlive: TimeInterval
    /// Which Parakeet model version to use for transcription (pipeline + dictation).
    public var transcriptionModel: TranscriptionModel

    public static let `default` = AppSettings(
        userName: "",
        launchAtLogin: false,
        autoWatch: true,
        outputDirectory: FileManager.default.heardOutputDirectory.path,
        customVocabulary: [],
        developerMode: false,
        dictationEnabled: false,
        dictationHotkey: .default,
        pushToTalk: false,
        dictationKeepAlive: 120,
        pipelineKeepAlive: 0,
        transcriptionModel: .v2
    )

    public init(
        userName: String,
        launchAtLogin: Bool,
        autoWatch: Bool,
        outputDirectory: String,
        customVocabulary: [String],
        developerMode: Bool = false,
        dictationEnabled: Bool = false,
        dictationHotkey: HotkeyCombo = .default,
        pushToTalk: Bool = false,
        dictationKeepAlive: TimeInterval = 120,
        pipelineKeepAlive: TimeInterval = 0,
        transcriptionModel: TranscriptionModel = .v2
    ) {
        self.userName = userName
        self.launchAtLogin = launchAtLogin
        self.autoWatch = autoWatch
        self.outputDirectory = outputDirectory
        self.customVocabulary = customVocabulary
        self.developerMode = developerMode
        self.dictationEnabled = dictationEnabled
        self.dictationHotkey = dictationHotkey
        self.pushToTalk = pushToTalk
        self.dictationKeepAlive = dictationKeepAlive
        self.pipelineKeepAlive = pipelineKeepAlive
        self.transcriptionModel = transcriptionModel
    }
}

public enum TranscriptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case v2
    case v3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .v2: return "Parakeet V2 — English-optimized"
        case .v3: return "Parakeet V3 — Latest"
        }
    }

    /// TDT decoder blank token ID for this model version.
    public var blankId: Int {
        switch self {
        case .v2: return 1024
        case .v3: return 8192
        }
    }
}

public enum ModelKind: String, CaseIterable, Identifiable {
    case batchParakeet
    case batchVad
    case diarization
    case ctcVocabulary

    public var id: String { rawValue }

    public func displayName(for transcriptionModel: TranscriptionModel = .v2) -> String {
        switch self {
        case .batchParakeet: return transcriptionModel.displayName
        case .batchVad: return "Silero VAD v6"
        case .diarization: return "LS-EEND + WeSpeaker"
        case .ctcVocabulary: return "Parakeet CTC 110M"
        }
    }
}

public enum ModelAvailability: String {
    case notDownloaded
    case downloading
    case ready
}

public struct ModelStatusItem: Identifiable {
    public let id = UUID()
    public let modelKind: ModelKind
    public let availability: ModelAvailability
    public let detail: String

    public init(modelKind: ModelKind, availability: ModelAvailability, detail: String) {
        self.modelKind = modelKind
        self.availability = availability
        self.detail = detail
    }
}

public struct TranscriptSegment: Identifiable, Equatable {
    public let id = UUID()
    public var speaker: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String

    public init(speaker: String, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct TranscriptDocument {
    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var participants: [String]
    public var segments: [TranscriptSegment]
    /// Unmatched speakers from diarization (speakerID, temporary name, embedding).
    public var unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float])]
    /// Diarization segments with original-time timestamps for clip extraction.
    public var diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)]
    /// Roster names not matched to known speakers (potential suggested names).
    public var unmatchedRosterNames: [String]

    public init(
        title: String,
        startTime: Date,
        endTime: Date,
        participants: [String],
        segments: [TranscriptSegment],
        unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float])] = [],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] = [],
        unmatchedRosterNames: [String] = []
    ) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.participants = participants
        self.segments = segments
        self.unmatchedSpeakers = unmatchedSpeakers
        self.diarizationSegments = diarizationSegments
        self.unmatchedRosterNames = unmatchedRosterNames
    }
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictation
    case speakers
    case models
    case about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .models: return "Models"
        case .speakers: return "Speakers"
        case .about: return "About"
        }
    }

    public var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic.badge.plus"
        case .models: return "cpu"
        case .speakers: return "person.3"
        case .about: return "info.circle"
        }
    }
}
