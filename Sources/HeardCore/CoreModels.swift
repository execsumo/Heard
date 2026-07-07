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

/// A message scraped from the meeting app's chat panel via Accessibility APIs
/// (see `ChatReader`). Inserted chronologically into the final transcript,
/// distinct from spoken segments and from the user's own in-meeting notes.
/// Opt-in only — see `AppSettings.includeMeetingChat` — since this passively
/// captures other participants' written words without their per-message consent.
public struct ChatMessage: Codable, Identifiable, Equatable {
    public let id: UUID
    /// Offset in seconds from the recording's `startTime`, captured when the
    /// message was first observed by the poll (not when it was actually sent —
    /// Teams' AX tree doesn't reliably expose per-message send times).
    public let offsetSeconds: TimeInterval
    public let sender: String
    public let text: String

    public init(id: UUID = UUID(), offsetSeconds: TimeInterval, sender: String, text: String) {
        self.id = id
        self.offsetSeconds = offsetSeconds
        self.sender = sender
        self.text = text
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
    /// Messages scraped from the meeting app's chat panel, if the user opted in
    /// (`AppSettings.includeMeetingChat`). Empty for meetings before this feature
    /// existed or where chat scraping is disabled/unavailable.
    public var chatMessages: [ChatMessage]
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
        chatMessages: [ChatMessage] = [],
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
        self.chatMessages = chatMessages
        self.micDelaySeconds = micDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingTitle, startTime, endTime, appAudioPath, micAudioPath
        case transcriptPath, stage, stageStartTime, error, retryCount
        case rosterNames, notes, chatMessages, micDelaySeconds
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
        chatMessages = try c.decodeIfPresent([ChatMessage].self, forKey: .chatMessages) ?? []
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
    /// Total wall-clock duration of meetings this speaker attended.
    public var totalMeetingDuration: TimeInterval
    public var totalWordCount: Int
    /// Cumulative time this speaker actually spent talking (sum of their
    /// transcript segment durations), as opposed to `totalMeetingDuration`
    /// which counts the whole meeting for every attendee.
    public var totalSpeakingTime: TimeInterval
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
        totalSpeakingTime: TimeInterval = 0,
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
        self.totalSpeakingTime = totalSpeakingTime
        self.audioClipURLs = audioClipURLs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, embeddings, firstSeen, lastSeen, meetingCount
        case totalMeetingDuration, totalWordCount, totalSpeakingTime
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
        totalSpeakingTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalSpeakingTime) ?? 0
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
        try c.encode(totalSpeakingTime, forKey: .totalSpeakingTime)
        try c.encode(audioClipURLs, forKey: .audioClipURLs)
    }
}

/// Codable so pending candidates survive an app restart (`NamingCandidateStore`).
public struct NamingCandidate: Identifiable, Equatable, Codable {
    public let id: UUID
    public var temporaryName: String
    /// Roster names not matched to any known speaker this meeting. All of them are
    /// offered as tappable suggestions on every candidate — with several unknown
    /// voices there is no reliable way to pre-pair a specific name to a specific
    /// voice, so the user picks by ear.
    public var suggestedNames: [String]
    /// Voice samples for this candidate, ordered best-first. The naming prompt lets the
    /// user play any of them so they can disambiguate when one sample is silent or has
    /// crosstalk.
    public var audioClipURLs: [URL]
    public var embedding: [Float]
    /// Per-clip embeddings parallel to `audioClipURLs` (an entry may be empty when the
    /// diarizer didn't expose chunk embeddings for that region). Powers "Split voices":
    /// when the clips of one cluster turn out to be different people, each split part is
    /// saved with its own clip-local embedding instead of the polluted cluster centroid.
    public var clipEmbeddings: [[Float]]
    /// Path to the transcript file that uses this temporary name; used to rewrite the file when the speaker is named.
    public var transcriptPath: URL?
    public var totalMeetingDuration: TimeInterval
    public var totalWordCount: Int
    /// Time this voice actually spent talking (sum of its segment durations).
    public var totalSpeakingTime: TimeInterval

    /// The one name worth pre-filling: only when the roster leaves exactly one
    /// unmatched name is the pairing unambiguous enough to type it in for the user.
    public var suggestedName: String? {
        suggestedNames.count == 1 ? suggestedNames.first : nil
    }

    public init(
        id: UUID,
        temporaryName: String,
        suggestedNames: [String] = [],
        audioClipURLs: [URL] = [],
        embedding: [Float] = [],
        clipEmbeddings: [[Float]] = [],
        transcriptPath: URL? = nil,
        totalMeetingDuration: TimeInterval = 0,
        totalWordCount: Int = 0,
        totalSpeakingTime: TimeInterval = 0
    ) {
        self.id = id
        self.temporaryName = temporaryName
        self.suggestedNames = suggestedNames
        self.audioClipURLs = audioClipURLs
        self.embedding = embedding
        self.clipEmbeddings = clipEmbeddings
        self.transcriptPath = transcriptPath
        self.totalMeetingDuration = totalMeetingDuration
        self.totalWordCount = totalWordCount
        self.totalSpeakingTime = totalSpeakingTime
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
    /// Cosine *distance* below which a detected voice is considered the same person
    /// as a stored profile (cross-meeting recognition). Lower = stricter: fewer
    /// false matches against the wrong profile, but more "new speaker" naming
    /// prompts for people already in the database; higher = looser. Distinct from
    /// `diarizationClusteringSimilarity`, which separates voices *within* one
    /// meeting.
    public var speakerMatchThreshold: Double
    public var appearance: AppAppearance
    /// Controls whether preprocessing runs the app and mic tracks sequentially (low
    /// memory) or concurrently. `.auto` decides based on the machine's physical RAM;
    /// `.low`/`.normal` force the behavior. Low-memory preprocessing halves peak RAM
    /// during the VAD stage (~400 MB instead of ~800 MB) at a small speed cost.
    public var memoryMode: MemoryMode

    /// Resolves `memoryMode` to the concrete behavior used by the pipeline. `.auto`
    /// consults `SystemMemory.isLowMemoryMachine`; `.low`/`.normal` return the forced
    /// value.
    public var effectiveLowMemory: Bool {
        switch memoryMode {
        case .auto: return SystemMemory.isLowMemoryMachine
        case .low: return true
        case .normal: return false
        }
    }
    /// How many days of inactivity before a speaker profile is automatically deleted.
    /// 0 means never delete automatically.
    public var speakerRetentionDays: Int
    /// CoreAudio UID of the user-selected input device for dictation and meeting
    /// recording. nil means follow the system default input device.
    public var selectedInputDeviceUID: String?
    /// Reveals the gated Advanced tab (models, performance, diarization, debugging).
    /// Off by default to keep the default settings surface calm.
    public var showAdvancedSettings: Bool
    /// Scrape the meeting app's chat panel via Accessibility APIs and interleave it
    /// into the transcript (see `ChatReader`/`ChatMessage`). Off by default: unlike
    /// the roster (names only) or notes (the user's own words), this passively
    /// captures other participants' written words without their per-message
    /// consent, so it's opt-in rather than automatic.
    public var includeMeetingChat: Bool

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
        meetingNoteHotkey: .meetingNoteDefault,
        showDockIcon: false,
        enableTeamsDetection: true,
        enableZoomDetection: true,
        enableWebexDetection: true,
        diarizationClusteringSimilarity: 0.65,
        speakerMatchThreshold: 0.30,
        appearance: .system,
        memoryMode: .auto,
        speakerRetentionDays: 90,
        selectedInputDeviceUID: nil,
        showAdvancedSettings: false,
        includeMeetingChat: false
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
        meetingNoteHotkey: HotkeyCombo = .meetingNoteDefault,
        showDockIcon: Bool = false,
        enableTeamsDetection: Bool = true,
        enableZoomDetection: Bool = true,
        enableWebexDetection: Bool = true,
        diarizationClusteringSimilarity: Double = 0.65,
        speakerMatchThreshold: Double = 0.30,
        appearance: AppAppearance = .system,
        memoryMode: MemoryMode = .auto,
        speakerRetentionDays: Int = 90,
        selectedInputDeviceUID: String? = nil,
        showAdvancedSettings: Bool = false,
        includeMeetingChat: Bool = false
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
        self.meetingNoteHotkey = meetingNoteHotkey
        self.showDockIcon = showDockIcon
        self.enableTeamsDetection = enableTeamsDetection
        self.enableZoomDetection = enableZoomDetection
        self.enableWebexDetection = enableWebexDetection
        self.diarizationClusteringSimilarity = diarizationClusteringSimilarity
        self.speakerMatchThreshold = speakerMatchThreshold
        self.appearance = appearance
        self.memoryMode = memoryMode
        self.speakerRetentionDays = speakerRetentionDays
        self.selectedInputDeviceUID = selectedInputDeviceUID
        self.showAdvancedSettings = showAdvancedSettings
        self.includeMeetingChat = includeMeetingChat
    }
}

/// How the audio-preprocessing pipeline trades RAM against speed.
public enum MemoryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Decide automatically from the machine's physical RAM (see `SystemMemory`).
    case auto
    /// Always preprocess tracks sequentially (lower peak RAM, slightly slower).
    case low
    /// Always preprocess tracks concurrently (higher peak RAM, faster).
    case normal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .low: return "Force Low"
        case .normal: return "Force Normal"
        }
    }
}

/// Physical-memory inspection used to decide the default (`.auto`) memory mode.
public enum SystemMemory {
    /// Machines at or below this many bytes of physical RAM default to low-memory
    /// preprocessing. 8 GB = 8 * 1024^3 = 8_589_934_592 bytes.
    public static let lowMemoryThresholdBytes: UInt64 = 8 * 1024 * 1024 * 1024

    /// Physical RAM reported by the OS, in bytes.
    public static var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Whether this machine should run in low-memory mode when `memoryMode` is `.auto`.
    public static var isLowMemoryMachine: Bool {
        isLowMemoryMachine(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Pure, testable form of the threshold check.
    public static func isLowMemoryMachine(physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes <= lowMemoryThresholdBytes
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

/// A diarized voice with no confident match in the speaker database, carrying the
/// per-meeting stats that flow into the profile once the user names (or skips) it.
public struct UnmatchedSpeaker {
    public let speakerID: String
    public let temporaryName: String
    public let embedding: [Float]
    /// Wall-clock duration of the meeting this voice appeared in.
    public var totalMeetingDuration: TimeInterval
    public var totalWordCount: Int
    /// Time this voice actually spent talking (sum of its segment durations).
    public var totalSpeakingTime: TimeInterval

    public init(
        speakerID: String,
        temporaryName: String,
        embedding: [Float],
        totalMeetingDuration: TimeInterval = 0,
        totalWordCount: Int = 0,
        totalSpeakingTime: TimeInterval = 0
    ) {
        self.speakerID = speakerID
        self.temporaryName = temporaryName
        self.embedding = embedding
        self.totalMeetingDuration = totalMeetingDuration
        self.totalWordCount = totalWordCount
        self.totalSpeakingTime = totalSpeakingTime
    }
}

public struct TranscriptDocument {
    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var participants: [String]
    public var segments: [TranscriptSegment]
    /// Unmatched speakers from diarization, pending the naming prompt.
    public var unmatchedSpeakers: [UnmatchedSpeaker]
    /// Diarization segments with original-time timestamps for clip extraction.
    public var diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)]
    /// Roster names not matched to known speakers (potential suggested names).
    public var unmatchedRosterNames: [String]
    /// User-authored notes captured via the in-meeting note hotkey. Rendered
    /// chronologically alongside speaker segments in the markdown output.
    public var notes: [MeetingNote]
    /// Display name to attribute notes to. Falls back to "Me" when empty.
    public var noteAuthor: String
    /// Messages scraped from the meeting chat panel, when opted in. Rendered
    /// chronologically alongside speaker segments and notes in the markdown output.
    public var chatMessages: [ChatMessage]

    public init(
        title: String,
        startTime: Date,
        endTime: Date,
        participants: [String],
        segments: [TranscriptSegment],
        unmatchedSpeakers: [UnmatchedSpeaker] = [],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] = [],
        unmatchedRosterNames: [String] = [],
        notes: [MeetingNote] = [],
        noteAuthor: String = "Me",
        chatMessages: [ChatMessage] = []
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
        self.chatMessages = chatMessages
    }
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case recording
    case dictation
    case speakers
    case advanced
    case about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .dictation: return "Dictation"
        case .speakers: return "Speakers"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    public var icon: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .dictation: return "mic.badge.plus"
        case .speakers: return "person.3"
        case .advanced: return "cpu"
        case .about: return "info.circle"
        }
    }
}
