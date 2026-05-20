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

public enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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

/// A user-authored note typed during a meeting via the in-meeting note hotkey.
/// Inserted chronologically into the final transcript and rendered as supplemental
/// info attributed to the local user, distinct from spoken segments.
public struct MeetingNote: Codable, Identifiable, Equatable {
    public let id: UUID
    /// Offset in seconds from the recording's `startTime`. Anchored at the moment
    /// the user invoked the composer (not when they submitted), so a slow typer's
    /// note still lands at the right point in the conversation.
    public let offsetSeconds: TimeInterval
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), offsetSeconds: TimeInterval, text: String, createdAt: Date = Date()) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.text = text
        self.createdAt = createdAt
    }
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
    public var notes: [MeetingNote]
    /// `mic.start − app.start` in seconds. Used during speaker assignment to
    /// align mic-track segments with app-track segments for cross-track
    /// deduplication. Defaults to 0 for jobs persisted before this field
    /// existed.
    public var micDelaySeconds: TimeInterval

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
        rosterNames: [String] = [],
        notes: [MeetingNote] = [],
        micDelaySeconds: TimeInterval = 0
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
        self.notes = notes
        self.micDelaySeconds = micDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingTitle, startTime, endTime, appAudioPath, micAudioPath
        case transcriptPath, stage, stageStartTime, error, retryCount
        case rosterNames, notes, micDelaySeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        meetingTitle = try c.decode(String.self, forKey: .meetingTitle)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        appAudioPath = try c.decode(URL.self, forKey: .appAudioPath)
        micAudioPath = try c.decode(URL.self, forKey: .micAudioPath)
        transcriptPath = try c.decodeIfPresent(URL.self, forKey: .transcriptPath)
        stage = try c.decode(PipelineStage.self, forKey: .stage)
        stageStartTime = try c.decodeIfPresent(Date.self, forKey: .stageStartTime)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        retryCount = try c.decode(Int.self, forKey: .retryCount)
        rosterNames = try c.decodeIfPresent([String].self, forKey: .rosterNames) ?? []
        notes = try c.decodeIfPresent([MeetingNote].self, forKey: .notes) ?? []
        micDelaySeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .micDelaySeconds) ?? 0
    }
}

public struct SpeakerProfile: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var embeddings: [[Float]]
    public var firstSeen: Date
    public var lastSeen: Date
    public var meetingCount: Int
    public var totalMeetingDuration: TimeInterval
    public var totalWordCount: Int
    /// Persisted voice samples for this speaker (used for replay in settings).
    /// Ordered best-first; multiple samples help the user disambiguate when one is silent.
    public var audioClipURLs: [URL]

    public init(
        id: UUID,
        name: String,
        embeddings: [[Float]],
        firstSeen: Date,
        lastSeen: Date,
        meetingCount: Int,
        totalMeetingDuration: TimeInterval = 0,
        totalWordCount: Int = 0,
        audioClipURLs: [URL] = []
    ) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.meetingCount = meetingCount
        self.totalMeetingDuration = totalMeetingDuration
        self.totalWordCount = totalWordCount
        self.audioClipURLs = audioClipURLs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, embeddings, firstSeen, lastSeen, meetingCount
        case totalMeetingDuration, totalWordCount
        case audioClipURLs
        case audioClipURL // legacy single-URL field
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        embeddings = try c.decode([[Float]].self, forKey: .embeddings)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        meetingCount = try c.decode(Int.self, forKey: .meetingCount)
        totalMeetingDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .totalMeetingDuration) ?? 0
        totalWordCount = try c.decodeIfPresent(Int.self, forKey: .totalWordCount) ?? 0
        if let urls = try c.decodeIfPresent([URL].self, forKey: .audioClipURLs) {
            audioClipURLs = urls
        } else if let legacy = try c.decodeIfPresent(URL.self, forKey: .audioClipURL) {
            audioClipURLs = [legacy]
        } else {
            audioClipURLs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(embeddings, forKey: .embeddings)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encode(lastSeen, forKey: .lastSeen)
        try c.encode(meetingCount, forKey: .meetingCount)
        try c.encode(totalMeetingDuration, forKey: .totalMeetingDuration)
        try c.encode(totalWordCount, forKey: .totalWordCount)
        try c.encode(audioClipURLs, forKey: .audioClipURLs)
    }
}

public struct NamingCandidate: Identifiable, Equatable {
    public let id: UUID
    public var temporaryName: String
    public var suggestedName: String?
    /// Voice samples for this candidate, ordered best-first. The naming prompt lets the
    /// user play any of them so they can disambiguate when one sample is silent or has
    /// crosstalk.
    public var audioClipURLs: [URL]
    public var embedding: [Float]
    /// Path to the transcript file that uses this temporary name; used to rewrite the file when the speaker is named.
    public var transcriptPath: URL?
    public var totalMeetingDuration: TimeInterval
    public var totalWordCount: Int

    public init(
        id: UUID,
        temporaryName: String,
        suggestedName: String? = nil,
        audioClipURLs: [URL] = [],
        embedding: [Float] = [],
        transcriptPath: URL? = nil,
        totalMeetingDuration: TimeInterval = 0,
        totalWordCount: Int = 0
    ) {
        self.id = id
        self.temporaryName = temporaryName
        self.suggestedName = suggestedName
        self.audioClipURLs = audioClipURLs
        self.embedding = embedding
        self.transcriptPath = transcriptPath
        self.totalMeetingDuration = totalMeetingDuration
        self.totalWordCount = totalWordCount
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
        case .recommended: return "Not Granted"
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

public enum FilenameFormat: String, Codable, CaseIterable, Identifiable {
    case isoDate = "YYYY-MM-DD_Name"
    case isoDateTime = "YYYY-MM-DD_HH-mm_Name"
    case shortDateTime = "MM-DD_HH-mm_Name"
    case nameFirstIso = "Name_YYYY-MM-DD"
    case nameOnly = "Name"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .isoDate: return "YYYY-MM-DD_MeetingName"
        case .isoDateTime: return "YYYY-MM-DD_HH-mm_MeetingName"
        case .shortDateTime: return "MM-DD_HH-mm_MeetingName"
        case .nameFirstIso: return "MeetingName_YYYY-MM-DD"
        case .nameOnly: return "MeetingName"
        }
    }
}

public struct FormattingCommand: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var spoken: String
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }
}

public struct AppSettings: Codable, Equatable {
    public var userName: String
    public var launchAtLogin: Bool
    public var autoWatch: Bool
    public var outputDirectory: String
    public var customVocabulary: [String]
    public var formattingCommands: [FormattingCommand]
    public var developerMode: Bool
    public var dictationEnabled: Bool
    public var dictationHotkey: HotkeyCombo
    public var pushToTalk: Bool
    /// How long to keep models loaded after use (minutes). 0 = unload immediately.
    public var modelKeepAlive: Int
    /// Which Parakeet model version to use for transcription (pipeline + dictation).
    public var transcriptionModel: TranscriptionModel
    /// Show a floating HUD while dictation is active (opt-in).
    public var showDictationHUD: Bool
    /// Format used for the transcript filename.
    public var filenameFormat: FilenameFormat
    /// Hotkey to open the in-meeting note composer. Active only while a meeting is recording.
    public var meetingNoteHotkey: HotkeyCombo
    /// Whether to show the app icon in the Dock.
    public var showDockIcon: Bool
    /// Detect Microsoft Teams meetings (classic + new Teams).
    public var enableTeamsDetection: Bool
    /// Detect Zoom meetings.
    public var enableZoomDetection: Bool
    /// Detect Cisco Webex meetings.
    public var enableWebexDetection: Bool
    /// Cosine similarity threshold for speaker clustering during diarization.
    /// FluidAudio's AHC merges two embeddings when their cosine similarity is at or
    /// above this value, so higher = stricter separation (more clusters, fewer
    /// merges); lower = looser (fewer clusters, more chance of two voices
    /// collapsing into one). FluidAudio's default is 0.6; we bias slightly
    /// stricter so the user can always merge over-split speakers in the Speakers
    /// tab, which is easier than recovering from a merged-embedding poisoning a
    /// profile.
    public var diarizationClusteringSimilarity: Double
    public var appearance: AppAppearance
    /// When enabled, preprocessing runs the app and mic tracks sequentially rather than
    /// concurrently, halving peak RAM during the VAD stage (~400 MB instead of ~800 MB).
    /// Useful on machines with 8 GB unified memory under heavy load.
    public var lowMemoryMode: Bool
    /// How many days of inactivity before a speaker profile is automatically deleted.
    /// 0 means never delete automatically.
    public var speakerRetentionDays: Int

    public static let `default` = AppSettings(
        userName: "",
        launchAtLogin: false,
        autoWatch: true,
        outputDirectory: FileManager.default.heardOutputDirectory.path,
        customVocabulary: [],
        formattingCommands: [
            FormattingCommand(spoken: "new line", written: "\n"),
            FormattingCommand(spoken: "new paragraph", written: "\n\n")
        ],
        developerMode: false,
        dictationEnabled: false,
        dictationHotkey: .default,
        pushToTalk: false,
        modelKeepAlive: 2,
        transcriptionModel: .v2,
        showDictationHUD: false,
        filenameFormat: .isoDate,
        meetingNoteHotkey: .meetingNoteDefault,
        showDockIcon: false,
        enableTeamsDetection: true,
        enableZoomDetection: true,
        enableWebexDetection: true,
        diarizationClusteringSimilarity: 0.65,
        appearance: .system,
        lowMemoryMode: false,
        speakerRetentionDays: 90
    )

    public init(
        userName: String,
        launchAtLogin: Bool,
        autoWatch: Bool,
        outputDirectory: String,
        customVocabulary: [String],
        formattingCommands: [FormattingCommand] = AppSettings.default.formattingCommands,
        developerMode: Bool = false,
        dictationEnabled: Bool = false,
        dictationHotkey: HotkeyCombo = .default,
        pushToTalk: Bool = false,
        modelKeepAlive: Int = 2,
        transcriptionModel: TranscriptionModel = .v2,
        showDictationHUD: Bool = false,
        filenameFormat: FilenameFormat = .isoDate,
        meetingNoteHotkey: HotkeyCombo = .meetingNoteDefault,
        showDockIcon: Bool = false,
        enableTeamsDetection: Bool = true,
        enableZoomDetection: Bool = true,
        enableWebexDetection: Bool = true,
        diarizationClusteringSimilarity: Double = 0.65,
        appearance: AppAppearance = .system,
        lowMemoryMode: Bool = false,
        speakerRetentionDays: Int = 90
    ) {
        self.userName = userName
        self.launchAtLogin = launchAtLogin
        self.autoWatch = autoWatch
        self.outputDirectory = outputDirectory
        self.customVocabulary = customVocabulary
        self.formattingCommands = formattingCommands
        self.developerMode = developerMode
        self.dictationEnabled = dictationEnabled
        self.dictationHotkey = dictationHotkey
        self.pushToTalk = pushToTalk
        self.modelKeepAlive = modelKeepAlive
        self.transcriptionModel = transcriptionModel
        self.showDictationHUD = showDictationHUD
        self.filenameFormat = filenameFormat
        self.meetingNoteHotkey = meetingNoteHotkey
        self.showDockIcon = showDockIcon
        self.enableTeamsDetection = enableTeamsDetection
        self.enableZoomDetection = enableZoomDetection
        self.enableWebexDetection = enableWebexDetection
        self.diarizationClusteringSimilarity = diarizationClusteringSimilarity
        self.appearance = appearance
        self.lowMemoryMode = lowMemoryMode
        self.speakerRetentionDays = speakerRetentionDays
    }
}

public enum TranscriptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case v2
    case v3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .v2: return "English (Optimized)"
        case .v3: return "European Languages (Beta)"
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
    /// Unmatched speakers from diarization (speakerID, temporary name, embedding, totalMeetingDuration, totalWordCount).
    public var unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float], duration: TimeInterval, words: Int)]
    /// Diarization segments with original-time timestamps for clip extraction.
    public var diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)]
    /// Roster names not matched to known speakers (potential suggested names).
    public var unmatchedRosterNames: [String]
    /// User-authored notes captured via the in-meeting note hotkey. Rendered
    /// chronologically alongside speaker segments in the markdown output.
    public var notes: [MeetingNote]
    /// Display name to attribute notes to. Falls back to "Me" when empty.
    public var noteAuthor: String

    public init(
        title: String,
        startTime: Date,
        endTime: Date,
        participants: [String],
        segments: [TranscriptSegment],
        unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float], duration: TimeInterval, words: Int)] = [],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] = [],
        unmatchedRosterNames: [String] = [],
        notes: [MeetingNote] = [],
        noteAuthor: String = "Me"
    ) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.participants = participants
        self.segments = segments
        self.unmatchedSpeakers = unmatchedSpeakers
        self.diarizationSegments = diarizationSegments
        self.unmatchedRosterNames = unmatchedRosterNames
        self.notes = notes
        self.noteAuthor = noteAuthor
    }
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case transcription
    case dictation
    case speakers
    case advanced
    case about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .transcription: return "Transcription"
        case .dictation: return "Dictation"
        case .speakers: return "Speakers"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    public var icon: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform.and.mic"
        case .dictation: return "mic.badge.plus"
        case .speakers: return "person.3"
        case .advanced: return "cpu"
        case .about: return "info.circle"
        }
    }
}
