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
        retryCount: Int
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

    public init(id: UUID, temporaryName: String, suggestedName: String? = nil) {
        self.id = id
        self.temporaryName = temporaryName
        self.suggestedName = suggestedName
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

    public static let `default` = AppSettings(
        userName: "",
        launchAtLogin: false,
        autoWatch: true,
        outputDirectory: FileManager.default.lurkOutputDirectory.path,
        customVocabulary: []
    )

    public init(
        userName: String,
        launchAtLogin: Bool,
        autoWatch: Bool,
        outputDirectory: String,
        customVocabulary: [String]
    ) {
        self.userName = userName
        self.launchAtLogin = launchAtLogin
        self.autoWatch = autoWatch
        self.outputDirectory = outputDirectory
        self.customVocabulary = customVocabulary
    }
}

public enum ModelKind: String, CaseIterable, Identifiable {
    case batchParakeet
    case batchVad
    case diarization
    case streamingPlaceholder

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .batchParakeet: return "Parakeet TDT V2"
        case .batchVad: return "Silero VAD v6"
        case .diarization: return "LS-EEND + WeSpeaker"
        case .streamingPlaceholder: return "Streaming Dictation Models"
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

    public init(title: String, startTime: Date, endTime: Date, participants: [String], segments: [TranscriptSegment]) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.participants = participants
        self.segments = segments
    }
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case dictation
    case speakers
    case permissions
    case about

    public var id: String { rawValue }
}
