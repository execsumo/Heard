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
            let data = try? Data(contentsOf: url),
            let value = try? decoder.decode(type, from: data)
        else {
            return defaultValue()
        }
        return value
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

        var formattingCommands = base.formattingCommands
        if let commandsData = defaults.data(forKey: "formattingCommands"),
           let decoded = try? JSONDecoder().decode([FormattingCommand].self, from: commandsData) {
            formattingCommands = decoded
        }

        var transcriptDateFormat = base.transcriptDateFormat
        if let formatString = defaults.string(forKey: "transcriptDateFormat"),
           let decoded = TranscriptDateFormat(rawValue: formatString) {
            transcriptDateFormat = decoded
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
            transcriptDateFormat: transcriptDateFormat
        )
    }

    private func persist() {
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
        defaults.set(settings.transcriptDateFormat.rawValue, forKey: "transcriptDateFormat")
        if let hotkeyData = try? JSONEncoder().encode(settings.dictationHotkey) {
            defaults.set(hotkeyData, forKey: "dictationHotkey")
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

    public func updateStats(id: UUID, addDuration: TimeInterval, addWords: Int) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].totalSpeechDuration += addDuration
        speakers[index].totalWordCount += addWords
        persist()
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

    public func merge(primaryID: UUID, secondaryID: UUID) {
        guard
            let primaryIndex = speakers.firstIndex(where: { $0.id == primaryID }),
            let secondaryIndex = speakers.firstIndex(where: { $0.id == secondaryID }),
            primaryIndex != secondaryIndex
        else { return }

        var primary = speakers[primaryIndex]
        let secondary = speakers[secondaryIndex]
        primary.embeddings.append(contentsOf: secondary.embeddings)
        primary.firstSeen = min(primary.firstSeen, secondary.firstSeen)
        primary.lastSeen = max(primary.lastSeen, secondary.lastSeen)
        primary.meetingCount += secondary.meetingCount
        primary.totalSpeechDuration += secondary.totalSpeechDuration
        primary.totalWordCount += secondary.totalWordCount
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
        if let speakers = try? decoder.decode([SpeakerProfile].self, from: data) {
            return speakers
        }
        return []
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
