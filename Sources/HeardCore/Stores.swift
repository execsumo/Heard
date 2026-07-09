import Combine
import Foundation

public extension FileManager {
    var heardAppSupportDirectory: URL {
        let base = urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Heard", isDirectory: true)
    }

    var heardOutputDirectory: URL {
        let base = urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Heard", isDirectory: true)
    }

    func ensureHeardDirectories() throws {
        let support = heardAppSupportDirectory
        try createDirectory(at: support, withIntermediateDirectories: true)
        try createDirectory(at: support.appendingPathComponent("Models", isDirectory: true), withIntermediateDirectories: true)
        try createDirectory(at: support.appendingPathComponent("recordings", isDirectory: true), withIntermediateDirectories: true)
        try createDirectory(at: support.appendingPathComponent("speaker_clips", isDirectory: true), withIntermediateDirectories: true)
        try createDirectory(at: heardOutputDirectory, withIntermediateDirectories: true)
    }

    var heardSpeakerClipsDirectory: URL {
        heardAppSupportDirectory.appendingPathComponent("speaker_clips", isDirectory: true)
    }
}

public enum AppPaths {
    public static var queueFile: URL {
        FileManager.default.heardAppSupportDirectory.appendingPathComponent("pipeline_queue.json")
    }

    public static var speakersFile: URL {
        FileManager.default.heardAppSupportDirectory.appendingPathComponent("speakers.json")
    }

    public static var namingCandidatesFile: URL {
        FileManager.default.heardAppSupportDirectory.appendingPathComponent("naming_candidates.json")
    }
}

public enum Formatting {
    public static let recordingFileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    public static let transcriptDatePrefixFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    public static let transcriptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

public extension String {
    func sanitizedFileName(maxLength: Int = 80) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let replaced = components(separatedBy: illegal).joined(separator: "_")
        let compact = replaced
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((compact.isEmpty ? "meeting" : compact).prefix(maxLength))
    }
}

public extension TimeInterval {
    var timestampString: String {
        let total = Int(self.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

final class JSONStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL, defaultValue: @autoclosure () -> T) -> T {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return defaultValue()
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Self.quarantine(url, decodeError: error)
            return defaultValue()
        }
    }

    /// A store file exists but can't be decoded — don't silently reset over it.
    /// Move it aside so the data stays recoverable and the decode bug debuggable.
    static func quarantine(_ url: URL, decodeError: Error) {
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        NSLog("Heard: Failed to decode %@ (%@) — moved aside to %@ and starting fresh",
              url.lastPathComponent, decodeError.localizedDescription, backup.lastPathComponent)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = AppSettings.default

        var hotkey = base.dictationHotkey
        if let hotkeyData = defaults.data(forKey: "dictationHotkey"),
           let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: hotkeyData) {
            hotkey = decoded
        }

        var meetingNoteHotkey = base.meetingNoteHotkey
        if let data = defaults.data(forKey: "meetingNoteHotkey"),
           let decoded = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            meetingNoteHotkey = decoded
        }

        var formattingCommands = base.formattingCommands
        if let commandsData = defaults.data(forKey: "formattingCommands"),
           let decoded = try? JSONDecoder().decode([FormattingCommand].self, from: commandsData) {
            formattingCommands = decoded
        }

        var modelKeepAlive = base.modelKeepAlive
        if let val = defaults.object(forKey: "modelKeepAlive") as? NSNumber {
            modelKeepAlive = val.intValue
        } else if let val = defaults.object(forKey: "dictationKeepAlive") as? NSNumber {
            modelKeepAlive = val.doubleValue >= 30 ? Int(val.doubleValue / 60) : val.intValue
        } else if let val = defaults.object(forKey: "pipelineKeepAlive") as? NSNumber {
            modelKeepAlive = val.doubleValue >= 30 ? Int(val.doubleValue / 60) : val.intValue
        }

        var transcriptionModel = base.transcriptionModel
        if let modelString = defaults.string(forKey: "transcriptionModel"),
           let decoded = TranscriptionModel(rawValue: modelString) {
            transcriptionModel = decoded
        }

        var diarizationClusteringSimilarity = base.diarizationClusteringSimilarity
        if let val = defaults.object(forKey: "diarizationClusteringSimilarity") as? NSNumber {
            diarizationClusteringSimilarity = val.doubleValue
        }

        var speakerMatchThreshold = base.speakerMatchThreshold
        if let val = defaults.object(forKey: "speakerMatchThreshold") as? NSNumber {
            speakerMatchThreshold = val.doubleValue
        }

        var speakerRetentionDays = base.speakerRetentionDays
        if let val = defaults.object(forKey: "speakerRetentionDays") as? NSNumber {
            speakerRetentionDays = val.intValue
        }

        var memoryMode = base.memoryMode
        if let modeString = defaults.string(forKey: "memoryMode"),
           let decoded = MemoryMode(rawValue: modeString) {
            memoryMode = decoded
        } else if let legacy = defaults.object(forKey: "lowMemoryMode") as? Bool {
            // Migrate the old boolean toggle: an explicit "on" becomes a forced
            // low-memory override; "off" falls back to the new automatic default.
            memoryMode = legacy ? .low : .auto
        }

        settings = AppSettings(
            userName: defaults.string(forKey: "userName") ?? base.userName,
            launchAtLogin: defaults.object(forKey: "launchAtLogin") as? Bool ?? base.launchAtLogin,
            autoWatch: defaults.object(forKey: "autoWatch") as? Bool ?? base.autoWatch,
            outputDirectory: defaults.string(forKey: "outputDirectory") ?? base.outputDirectory,
            customVocabulary: defaults.stringArray(forKey: "customVocabulary") ?? base.customVocabulary,
            formattingCommands: formattingCommands,
            developerMode: defaults.object(forKey: "developerMode") as? Bool ?? base.developerMode,
            dictationEnabled: defaults.object(forKey: "dictationEnabled") as? Bool ?? base.dictationEnabled,
            dictationHotkey: hotkey,
            pushToTalk: defaults.object(forKey: "pushToTalk") as? Bool ?? base.pushToTalk,
            modelKeepAlive: modelKeepAlive,
            transcriptionModel: transcriptionModel,
            showDictationHUD: defaults.object(forKey: "showDictationHUD") as? Bool ?? base.showDictationHUD,
            meetingNoteHotkey: meetingNoteHotkey,
            enableTeamsDetection: defaults.object(forKey: "enableTeamsDetection") as? Bool ?? base.enableTeamsDetection,
            enableZoomDetection: defaults.object(forKey: "enableZoomDetection") as? Bool ?? base.enableZoomDetection,
            enableWebexDetection: defaults.object(forKey: "enableWebexDetection") as? Bool ?? base.enableWebexDetection,
            diarizationClusteringSimilarity: diarizationClusteringSimilarity,
            speakerMatchThreshold: speakerMatchThreshold,
            memoryMode: memoryMode,
            speakerRetentionDays: speakerRetentionDays,
            selectedInputDeviceUID: defaults.string(forKey: "selectedInputDeviceUID"),
            showAdvancedSettings: defaults.object(forKey: "showAdvancedSettings") as? Bool ?? base.showAdvancedSettings,
            includeMeetingChat: defaults.object(forKey: "includeMeetingChat") as? Bool ?? base.includeMeetingChat
        )
    }

    private func persist() {
        // Keep the debug logger's gate in sync — it has no other way to
        // observe the Developer Mode toggle flipping at runtime.
        DebugFileLog.isEnabled = settings.developerMode
        defaults.set(settings.userName, forKey: "userName")
        defaults.set(settings.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(settings.autoWatch, forKey: "autoWatch")
        defaults.set(settings.outputDirectory, forKey: "outputDirectory")
        defaults.set(settings.customVocabulary, forKey: "customVocabulary")
        if let commandsData = try? JSONEncoder().encode(settings.formattingCommands) {
            defaults.set(commandsData, forKey: "formattingCommands")
        }
        defaults.set(settings.developerMode, forKey: "developerMode")
        defaults.set(settings.dictationEnabled, forKey: "dictationEnabled")
        defaults.set(settings.pushToTalk, forKey: "pushToTalk")
        defaults.set(settings.modelKeepAlive, forKey: "modelKeepAlive")
        defaults.set(settings.transcriptionModel.rawValue, forKey: "transcriptionModel")
        defaults.set(settings.showDictationHUD, forKey: "showDictationHUD")
        if let hotkeyData = try? JSONEncoder().encode(settings.dictationHotkey) {
            defaults.set(hotkeyData, forKey: "dictationHotkey")
        }
        if let data = try? JSONEncoder().encode(settings.meetingNoteHotkey) {
            defaults.set(data, forKey: "meetingNoteHotkey")
        }
        defaults.set(settings.enableTeamsDetection, forKey: "enableTeamsDetection")
        defaults.set(settings.enableZoomDetection, forKey: "enableZoomDetection")
        defaults.set(settings.enableWebexDetection, forKey: "enableWebexDetection")
        defaults.set(settings.diarizationClusteringSimilarity, forKey: "diarizationClusteringSimilarity")
        defaults.set(settings.speakerMatchThreshold, forKey: "speakerMatchThreshold")
        defaults.set(settings.speakerRetentionDays, forKey: "speakerRetentionDays")
        defaults.set(settings.memoryMode.rawValue, forKey: "memoryMode")
        defaults.set(settings.showAdvancedSettings, forKey: "showAdvancedSettings")
        defaults.set(settings.includeMeetingChat, forKey: "includeMeetingChat")
        if let uid = settings.selectedInputDeviceUID {
            defaults.set(uid, forKey: "selectedInputDeviceUID")
        } else {
            defaults.removeObject(forKey: "selectedInputDeviceUID")
        }
    }
}

@MainActor
public final class SpeakerStore: ObservableObject {
    @Published public private(set) var speakers: [SpeakerProfile]

    private let store = JSONStore()
    private let url: URL

    /// On-disk schema. Encoded alongside the speakers array so the counter
    /// survives relaunches. Older app versions wrote a bare `[SpeakerProfile]`
    /// array; the loader detects that shape and migrates.
    private struct PersistedContents: Codable {
        var speakers: [SpeakerProfile]
    }

    public init(url: URL = AppPaths.speakersFile) {
        self.url = url
        self.speakers = Self.loadContents(from: url)
    }

    public func upsert(_ speaker: SpeakerProfile) {
        if let index = speakers.firstIndex(where: { $0.id == speaker.id }) {
            speakers[index] = speaker
        } else {
            speakers.append(speaker)
        }
        persist()
    }

    public func rename(id: UUID, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
        persist()
    }

    public func updateStats(id: UUID, addDuration: TimeInterval, addWords: Int, addSpeaking: TimeInterval = 0) {
        updateStats([(id: id, addDuration: addDuration, addWords: addWords, addSpeaking: addSpeaking)])
    }

    /// Batched variant: one disk write for the whole meeting's stat updates
    /// instead of a full JSON rewrite per speaker.
    public func updateStats(_ updates: [(id: UUID, addDuration: TimeInterval, addWords: Int, addSpeaking: TimeInterval)]) {
        var changed = false
        for update in updates {
            guard let index = speakers.firstIndex(where: { $0.id == update.id }) else { continue }
            speakers[index].totalMeetingDuration += update.addDuration
            speakers[index].totalWordCount += update.addWords
            speakers[index].totalSpeakingTime += update.addSpeaking
            changed = true
        }
        if changed { persist() }
    }

    public func delete(id: UUID) {
        if let clips = speakers.first(where: { $0.id == id })?.audioClipURLs {
            for clipURL in clips {
                try? FileManager.default.removeItem(at: clipURL)
            }
        }
        speakers.removeAll { $0.id == id }
        persist()
    }

    /// Deletes speakers whose `lastSeen` is older than `retentionDays` days.
    /// Pass 0 to skip archiving entirely.
    @discardableResult
    public func archiveInactiveSpeakers(retentionDays: Int) -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let stale = speakers.filter { $0.lastSeen < cutoff }
        guard !stale.isEmpty else { return 0 }
        // Batched: delete clips per speaker but rewrite the JSON file once,
        // not once per archived profile.
        let staleIDs = Set(stale.map(\.id))
        for speaker in stale {
            for clipURL in speaker.audioClipURLs {
                try? FileManager.default.removeItem(at: clipURL)
            }
        }
        speakers.removeAll { staleIDs.contains($0.id) }
        persist()
        return stale.count
    }

    /// Deletes placeholder-named profiles ("Speaker_XXXXXX") that have no playable
    /// voice clip on disk. Placeholders are excluded from voice matching, so a profile
    /// that offers neither a name nor audio can never be identified — it only adds
    /// noise (and a dead play button) to the Speakers list. Returns the number removed.
    @discardableResult
    public func pruneUnidentifiablePlaceholders() -> Int {
        let fm = FileManager.default
        let doomed = speakers.filter { profile in
            SpeakerMatcher.isPlaceholderName(profile.name)
                && !profile.audioClipURLs.contains { fm.fileExists(atPath: $0.path) }
        }
        guard !doomed.isEmpty else { return 0 }
        let doomedIDs = Set(doomed.map(\.id))
        for profile in doomed {
            // Clip entries exist but the files are gone; removal is a no-op safety net.
            for clipURL in profile.audioClipURLs {
                try? fm.removeItem(at: clipURL)
            }
        }
        speakers.removeAll { doomedIDs.contains($0.id) }
        persist()
        NSLog("Heard: pruned \(doomed.count) unidentifiable placeholder speaker(s)")
        return doomed.count
    }

    /// Cap on embeddings and voice clips a merged profile may accumulate. Matching
    /// scans every stored embedding, so unbounded growth from repeated (or N-way)
    /// merges would slow matching and raise false-match risk; overflow clips are
    /// deleted from disk.
    static let maxMergedEmbeddings = SpeakerMatcher.maxEmbeddingsPerSpeaker
    static let maxMergedClips = 5

    public func merge(primaryID: UUID, secondaryID: UUID) {
        guard
            let primaryIndex = speakers.firstIndex(where: { $0.id == primaryID }),
            let secondaryIndex = speakers.firstIndex(where: { $0.id == secondaryID }),
            primaryIndex != secondaryIndex
        else { return }

        var primary = speakers[primaryIndex]
        let secondary = speakers[secondaryIndex]
        // Keep the primary's entries first — they belong to the surviving identity.
        primary.embeddings = Array((primary.embeddings + secondary.embeddings).prefix(Self.maxMergedEmbeddings))
        let combinedClips = primary.audioClipURLs + secondary.audioClipURLs
        primary.audioClipURLs = Array(combinedClips.prefix(Self.maxMergedClips))
        for dropped in combinedClips.dropFirst(Self.maxMergedClips) {
            try? FileManager.default.removeItem(at: dropped)
        }
        primary.firstSeen = min(primary.firstSeen, secondary.firstSeen)
        primary.lastSeen = max(primary.lastSeen, secondary.lastSeen)
        primary.meetingCount += secondary.meetingCount
        primary.totalMeetingDuration += secondary.totalMeetingDuration
        primary.totalWordCount += secondary.totalWordCount
        primary.totalSpeakingTime += secondary.totalSpeakingTime
        speakers[primaryIndex] = primary
        speakers.remove(at: secondaryIndex)
        persist()
    }

    private func persist() {
        let contents = PersistedContents(speakers: speakers)
        try? store.save(contents, to: url)
    }

    private static func loadContents(from url: URL) -> [SpeakerProfile] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let contents = try? decoder.decode(PersistedContents.self, from: data) {
            return contents.speakers
        }
        // Legacy format: bare [SpeakerProfile].
        do {
            return try decoder.decode([SpeakerProfile].self, from: data)
        } catch {
            // The speaker database is the one store whose silent loss really
            // hurts (voice embeddings accumulate over months) — quarantine it.
            JSONStore.quarantine(url, decodeError: error)
            return []
        }
    }
}

/// Persists pending naming candidates so they survive an app restart — naming is
/// user-paced and may be deferred across sessions. Loading drops clips whose files
/// are gone (48-hour recordings cleanup, crashes) and whole candidates left with no
/// playable clip, mirroring the pipeline's "can't listen → can't identify" rule.
@MainActor
public final class NamingCandidateStore {
    private let store = JSONStore()
    private let url: URL

    public init(url: URL = AppPaths.namingCandidatesFile) {
        self.url = url
    }

    public func load() -> [NamingCandidate] {
        let raw = store.load([NamingCandidate].self, from: url, defaultValue: [])
        let fm = FileManager.default
        return raw.compactMap { candidate in
            var kept = candidate
            // Keep clipEmbeddings parallel to the surviving clips.
            let pairs = candidate.audioClipURLs.enumerated().filter { fm.fileExists(atPath: $0.element.path) }
            kept.audioClipURLs = pairs.map { $0.element }
            kept.clipEmbeddings = pairs.compactMap { index, _ in
                index < candidate.clipEmbeddings.count ? candidate.clipEmbeddings[index] : nil
            }
            return kept.audioClipURLs.isEmpty ? nil : kept
        }
    }

    public func save(_ candidates: [NamingCandidate]) {
        if candidates.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? store.save(candidates, to: url)
        }
    }
}

@MainActor
public final class PipelineQueueStore: ObservableObject {
    @Published public private(set) var jobs: [PipelineJob]

    private let store = JSONStore()
    private let url: URL

    public init(url: URL = AppPaths.queueFile) {
        self.url = url
        jobs = store.load([PipelineJob].self, from: url, defaultValue: [])
    }

    public func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        persist()
    }

    public func update(_ job: PipelineJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        persist()
    }

    public func remove(_ job: PipelineJob) {
        jobs.removeAll { $0.id == job.id }
        persist()
    }

    public var activeJob: PipelineJob? {
        jobs.first { $0.stage != .complete }
    }

    /// The first non-terminal job in the queue — either currently being processed
    /// or waiting to be picked up. Excludes `.complete` and `.failed` so a stale
    /// failed job can't masquerade as the active job and cause the menu bar status
    /// to fall through to "Watching" while a real job is in flight behind it.
    public var processingJob: PipelineJob? {
        jobs.first { $0.stage != .complete && $0.stage != .failed }
    }

    public var recentJobs: [PipelineJob] {
        Array(jobs.sorted(by: { $0.endTime > $1.endTime }).prefix(3))
    }

    public var recentTranscripts: [PipelineJob] {
        Array(jobs
            .filter { $0.stage == .complete && $0.transcriptPath != nil }
            .sorted(by: { $0.endTime > $1.endTime })
            .prefix(3))
    }

    /// Prepare persisted queue state for a fresh app launch. Any job not in a
    /// terminal state (`.complete`) is re-queued: failed jobs get another attempt,
    /// and mid-stage jobs (orphaned by a crash) are recovered. `retryCount` is
    /// preserved so the lifetime retry ceiling still applies across sessions —
    /// jobs at/above `PipelineProcessor.lifetimeRetryLimit` stay `.failed` and
    /// must be explicitly retried by the user.
    /// Returns the IDs of jobs that were modified.
    @discardableResult
    public func prepareForResume() -> [UUID] {
        var changed: [UUID] = []
        for index in jobs.indices {
            let stage = jobs[index].stage
            guard stage != .complete, stage != .queued else { continue }
            if jobs[index].retryCount >= PipelineProcessor.lifetimeRetryLimit {
                // Permanently-failed job — don't burn another round of retries.
                if stage != .failed {
                    jobs[index].stage = .failed
                    changed.append(jobs[index].id)
                }
                continue
            }
            jobs[index].stage = .queued
            jobs[index].error = nil
            jobs[index].stageStartTime = nil
            changed.append(jobs[index].id)
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    private func persist() {
        try? store.save(jobs, to: url)
    }
}
