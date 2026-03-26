import Foundation

enum AppPhase: String, Codable, CaseIterable {
    case dormant
    case recording
    case processing
    case error
    case userAction

    var title: String {
        switch self {
        case .dormant: return "Watching"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .error: return "Error"
        case .userAction: return "Name Speakers"
        }
    }
}

enum PipelineStage: String, Codable, CaseIterable, Identifiable {
    case queued
    case preprocessing
    case transcribing
    case diarizing
    case assigning
    case complete
    case failed

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct PipelineJob: Codable, Identifiable, Equatable {
    let id: UUID
    var meetingTitle: String
    let startTime: Date
    let endTime: Date
    let appAudioPath: URL
    let micAudioPath: URL
    var transcriptPath: URL?
    var stage: PipelineStage
    var stageStartTime: Date?
    var error: String?
    var retryCount: Int
}

struct SpeakerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var embeddings: [[Float]]
    var firstSeen: Date
    var lastSeen: Date
    var meetingCount: Int
}

struct NamingCandidate: Identifiable, Equatable {
    let id: UUID
    var temporaryName: String
    var suggestedName: String?
}

enum PermissionState: String, Codable, CaseIterable, Identifiable {
    case unknown
    case granted
    case recommended

    var id: String { rawValue }

    var badge: String {
        switch self {
        case .unknown: return "Unknown"
        case .granted: return "Granted"
        case .recommended: return "Recommended"
        }
    }
}

struct PermissionStatus: Identifiable, Equatable {
    let id: String
    let title: String
    let purpose: String
    var state: PermissionState
}

enum SpeakerSortMode: String, CaseIterable, Identifiable {
    case name
    case lastSeen
    case meetingCount

    var id: String { rawValue }
}

struct AppSettings: Codable, Equatable {
    var userName: String
    var launchAtLogin: Bool
    var autoWatch: Bool
    var outputDirectory: String
    var customVocabulary: [String]

    static let `default` = AppSettings(
        userName: "",
        launchAtLogin: false,
        autoWatch: true,
        outputDirectory: FileManager.default.meetingTranscriberOutputDirectory.path,
        customVocabulary: []
    )
}

enum ModelKind: String, CaseIterable, Identifiable {
    case batchParakeet
    case batchVad
    case diarization
    case streamingPlaceholder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .batchParakeet: return "Parakeet TDT V2"
        case .batchVad: return "Silero VAD v6"
        case .diarization: return "LS-EEND + WeSpeaker"
        case .streamingPlaceholder: return "Streaming Dictation Models"
        }
    }
}

enum ModelAvailability: String {
    case notDownloaded
    case downloading
    case ready
}

struct ModelStatusItem: Identifiable {
    let id = UUID()
    let modelKind: ModelKind
    let availability: ModelAvailability
    let detail: String
}

struct TranscriptSegment: Identifiable, Equatable {
    let id = UUID()
    var speaker: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
}

struct TranscriptDocument {
    var title: String
    var startTime: Date
    var endTime: Date
    var participants: [String]
    var segments: [TranscriptSegment]
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case dictation
    case speakers
    case permissions
    case about

    var id: String { rawValue }
}
