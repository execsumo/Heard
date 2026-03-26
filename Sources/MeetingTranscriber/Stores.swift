import Combine
import Foundation

extension FileManager {
    var meetingTranscriberAppSupportDirectory: URL {
        let base = urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetingTranscriber", isDirectory: true)
    }

    var meetingTranscriberOutputDirectory: URL {
        let base = urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetingTranscriber", isDirectory: true)
    }

    func ensureMeetingTranscriberDirectories() throws {
        let support = meetingTranscriberAppSupportDirectory
        try createDirectory(at: support, withIntermediateDirectories: true)
        try createDirectory(at: support.appendingPathComponent("Models", isDirectory: true), withIntermediateDirectories: true)
        try createDirectory(at: support.appendingPathComponent("recordings", isDirectory: true), withIntermediateDirectories: true)
        try createDirectory(at: meetingTranscriberOutputDirectory, withIntermediateDirectories: true)
    }
}

enum AppPaths {
    static var queueFile: URL {
        FileManager.default.meetingTranscriberAppSupportDirectory.appendingPathComponent("pipeline_queue.json")
    }

    static var speakersFile: URL {
        FileManager.default.meetingTranscriberAppSupportDirectory.appendingPathComponent("speakers.json")
    }
}

enum Formatting {
    static let recordingFileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static let transcriptDatePrefixFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    static let transcriptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

extension String {
    func sanitizedFileName(maxLength: Int = 80) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let replaced = components(separatedBy: illegal).joined(separator: "_")
        let compact = replaced
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((compact.isEmpty ? "meeting" : compact).prefix(maxLength))
    }
}

extension TimeInterval {
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
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = AppSettings.default
        settings = AppSettings(
            userName: defaults.string(forKey: "userName") ?? base.userName,
            launchAtLogin: defaults.object(forKey: "launchAtLogin") as? Bool ?? base.launchAtLogin,
            autoWatch: defaults.object(forKey: "autoWatch") as? Bool ?? base.autoWatch,
            outputDirectory: defaults.string(forKey: "outputDirectory") ?? base.outputDirectory,
            customVocabulary: defaults.stringArray(forKey: "customVocabulary") ?? base.customVocabulary
        )
    }

    private func persist() {
        defaults.set(settings.userName, forKey: "userName")
        defaults.set(settings.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(settings.autoWatch, forKey: "autoWatch")
        defaults.set(settings.outputDirectory, forKey: "outputDirectory")
        defaults.set(settings.customVocabulary, forKey: "customVocabulary")
    }
}

@MainActor
final class SpeakerStore: ObservableObject {
    @Published private(set) var speakers: [SpeakerProfile]

    private let store = JSONStore()
    private let url: URL

    init(url: URL = AppPaths.speakersFile) {
        self.url = url
        speakers = store.load([SpeakerProfile].self, from: url, defaultValue: [])
    }

    func upsert(_ speaker: SpeakerProfile) {
        if let index = speakers.firstIndex(where: { $0.id == speaker.id }) {
            speakers[index] = speaker
        } else {
            speakers.append(speaker)
        }
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].name = name
        persist()
    }

    func delete(id: UUID) {
        speakers.removeAll { $0.id == id }
        persist()
    }

    func merge(primaryID: UUID, secondaryID: UUID) {
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
        speakers[primaryIndex] = primary
        speakers.remove(at: secondaryIndex)
        persist()
    }

    private func persist() {
        try? store.save(speakers, to: url)
    }
}

@MainActor
final class PipelineQueueStore: ObservableObject {
    @Published private(set) var jobs: [PipelineJob]

    private let store = JSONStore()
    private let url: URL

    init(url: URL = AppPaths.queueFile) {
        self.url = url
        jobs = store.load([PipelineJob].self, from: url, defaultValue: [])
    }

    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        persist()
    }

    func update(_ job: PipelineJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        persist()
    }

    var activeJob: PipelineJob? {
        jobs.first { $0.stage != .complete }
    }

    var recentJobs: [PipelineJob] {
        Array(jobs.sorted(by: { $0.endTime > $1.endTime }).prefix(3))
    }

    private func persist() {
        try? store.save(jobs, to: url)
    }
}
