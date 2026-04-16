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
        let vadDir = AsrModels.defaultCacheDirectory(for: .v3)
            .deletingLastPathComponent()
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        if fm.fileExists(atPath: vadDir.path) {
            catalog.markReady(.batchVad)
        }

        // Parakeet V3: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/
        let asrDefaultDir = AsrModels.defaultCacheDirectory(for: .v3)
        let asrCustomDir = FileManager.default.heardAppSupportDirectory
            .appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)
        if fm.fileExists(atPath: asrDefaultDir.path) || fm.fileExists(atPath: asrCustomDir.path) {
            catalog.markReady(.batchParakeet)
        }

        // Diarizer: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/
        let fluidModelsDir = AsrModels.defaultCacheDirectory(for: .v3)
            .deletingLastPathComponent()  // FluidAudio/Models/
        let diarDir = fluidModelsDir.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        if fm.fileExists(atPath: diarDir.path) {
            catalog.markReady(.diarization)
        }

        // CTC 110M: Used for custom vocabulary boosting
        let ctcDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        if CtcModels.modelsExist(at: ctcDir) {
            catalog.markReady(.ctcVocabulary)
        }

    }

    /// All batch (meeting transcription) models are ready (excludes optional CTC).
    public var allBatchModelsReady: Bool {
        let requiredKinds: [ModelKind] = [.batchVad, .batchParakeet, .diarization]
        return requiredKinds.allSatisfy { kind in
            catalog.statuses.first(where: { $0.modelKind == kind })?.availability == .ready
        }
    }

    /// CTC vocabulary model is ready.
    public var ctcModelsReady: Bool {
        catalog.statuses.first(where: { $0.modelKind == .ctcVocabulary })?.availability == .ready
    }

    /// Pre-download all models via FluidAudio's built-in download system.
    public func downloadAllModels() {
        download(.batchVad)
        download(.batchParakeet)
        download(.diarization)
        download(.ctcVocabulary)
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
                    let _ = try await AsrModels.loadFromCache(version: .v3) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress[.batchParakeet] = progress.fractionCompleted
                        }
                    }
                    catalog.markReady(.batchParakeet)

                case .diarization:
                    let diarizer = OfflineDiarizerManager()
                    try await diarizer.prepareModels()
                    catalog.markReady(.diarization)

                case .ctcVocabulary:
                    let _ = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    catalog.markReady(.ctcVocabulary)

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
