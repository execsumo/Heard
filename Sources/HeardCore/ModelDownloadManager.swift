import FluidAudio
import Foundation

/// Manages pre-downloading CoreML models so they're ready when a meeting ends.
/// FluidAudio auto-downloads models on first use, but pre-downloading avoids delays
/// after the first meeting.
@MainActor
public final class ModelDownloadManager: ObservableObject {

    @Published public private(set) var downloadProgress: [ModelKind: Double] = [:]
    @Published public private(set) var errors: [ModelKind: String] = [:]

    private var activeTasks: [ModelKind: Task<Void, Never>] = [:]
    private let catalog: ModelCatalog

    public init(catalog: ModelCatalog) {
        self.catalog = catalog
        refreshStatuses()
    }

    /// Check which models are already cached by looking at FluidAudio's actual cache locations.
    public func refreshStatuses() {
        let fm = FileManager.default

        // VAD: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/silero-vad-coreml/
        let vadDir = AsrModels.defaultCacheDirectory(for: .v2)
            .deletingLastPathComponent()
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        if fm.fileExists(atPath: vadDir.path) {
            catalog.markReady(.batchVad)
        }

        // Parakeet V2: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml/
        // Also check our custom Models dir (where load(from:) puts it)
        let asrDefaultDir = AsrModels.defaultCacheDirectory(for: .v2)
        let asrCustomDir = FileManager.default.heardAppSupportDirectory
            .appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)
        if fm.fileExists(atPath: asrDefaultDir.path) || fm.fileExists(atPath: asrCustomDir.path) {
            catalog.markReady(.batchParakeet)
        }

        // Diarizer: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/
        let fluidModelsDir = AsrModels.defaultCacheDirectory(for: .v2)
            .deletingLastPathComponent()  // FluidAudio/Models/
        let diarDir = fluidModelsDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        if fm.fileExists(atPath: diarDir.path) {
            catalog.markReady(.diarization)
        }

        // Streaming EOU: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/160ms/
        let eouDir = fluidModelsDir
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("160ms", isDirectory: true)
        let requiredEouFiles = ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"]
        if requiredEouFiles.allSatisfy({ fm.fileExists(atPath: eouDir.appendingPathComponent($0).path) }) {
            catalog.markReady(.streamingEou)
        }
    }

    /// All batch (meeting transcription) models are ready.
    public var allBatchModelsReady: Bool {
        let statuses = catalog.statuses
        return statuses.filter { $0.modelKind != .streamingEou }
            .allSatisfy { $0.availability == .ready }
    }

    /// The streaming EOU model is ready for dictation.
    public var streamingModelReady: Bool {
        catalog.statuses.first { $0.modelKind == .streamingEou }?.availability == .ready
    }

    /// Pre-download all models via FluidAudio's built-in download system.
    public func downloadAllModels() {
        download(.batchVad)
        download(.batchParakeet)
        download(.diarization)
    }

    public func download(_ kind: ModelKind) {
        guard activeTasks[kind] == nil else { return }
        errors[kind] = nil
        catalog.markDownloading(kind)
        downloadProgress[kind] = 0

        activeTasks[kind] = Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .batchVad:
                    // VadManager auto-downloads on init
                    let _ = try await VadManager { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress[.batchVad] = progress.fractionCompleted
                        }
                    }
                    catalog.markReady(.batchVad)

                case .batchParakeet:
                    // Use FluidAudio's default cache so models are shared
                    let _ = try await AsrModels.loadFromCache(version: .v2) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress[.batchParakeet] = progress.fractionCompleted
                        }
                    }
                    catalog.markReady(.batchParakeet)

                case .diarization:
                    let diarizer = OfflineDiarizerManager()
                    try await diarizer.prepareModels()
                    catalog.markReady(.diarization)

                case .streamingEou:
                    // Download to FluidAudio's shared Models dir; downloadRepo appends repo.folderName
                    let fluidModelsDir = AsrModels.defaultCacheDirectory(for: .v2)
                        .deletingLastPathComponent()  // FluidAudio/Models/
                    try await DownloadUtils.downloadRepo(.parakeetEou160, to: fluidModelsDir) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress[.streamingEou] = progress.fractionCompleted
                        }
                    }
                    catalog.markReady(.streamingEou)
                }
                downloadProgress[kind] = 1.0
            } catch {
                errors[kind] = error.localizedDescription
                downloadProgress[kind] = nil
                NSLog("Heard: Model download failed for \(kind): \(error)")
            }
            activeTasks[kind] = nil
        }
    }

    public func cancel(_ kind: ModelKind) {
        activeTasks[kind]?.cancel()
        activeTasks[kind] = nil
        downloadProgress[kind] = nil
    }
}
