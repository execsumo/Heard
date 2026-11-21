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
    private var dictationTask: Task<Void, Never>?
    private let catalog: ModelCatalog

    /// The selected meeting transcription model; drives batch readiness and download.
    public var transcriptionModel: TranscriptionModel = .unified

    /// Whether dictation is enabled. With English Unified selected, dictation also needs English (Optimized).
    public var dictationEnabled = false

    /// Called on the main actor after English (Optimized) finishes downloading for dictation.
    public var onDictationEngineReady: (@MainActor () -> Void)?

    public init(catalog: ModelCatalog) {
        self.catalog = catalog
        refreshStatuses()
    }

    /// Check which models are already cached by looking at FluidAudio's actual cache locations.
    public func refreshStatuses() {
        let fm = FileManager.default

        // VAD: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/silero-vad-coreml/
        let fluidModelsDir = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        let vadDir = fluidModelsDir.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        if fm.fileExists(atPath: vadDir.path) {
            catalog.markReady(.batchVad)
        }

        // Parakeet: only the selected meeting engine counts toward readiness.
        let batchDetailReady = ModelDownloadManager.batchDetail(readiness: "Ready", selected: transcriptionModel, dictationEnabled: dictationEnabled)
        if ModelDownloadManager.batchEngineReady(transcriptionModel) {
            catalog.markReady(.batchParakeet, detail: batchDetailReady)
        } else if activeTasks[.batchParakeet] == nil {
            catalog.markNotDownloaded(.batchParakeet, detail: ModelDownloadManager.batchDetail(readiness: "Download required", selected: transcriptionModel, dictationEnabled: dictationEnabled))
        }

        // Diarizer: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/
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
        downloadDictationEngineIfNeeded()
    }

    /// With English Unified selected and dictation on, fetch English (Optimized) so dictation can run.
    /// Not part of meeting readiness; a no-op in every other case.
    public func downloadDictationEngineIfNeeded() {
        guard dictationEnabled, transcriptionModel.usesUnifiedEngine,
              dictationTask == nil,
              !DictationManager.englishOptimizedCached() else { return }
        dictationTask = Task { [weak self] in
            var loaded = false
            do {
                _ = try await AsrModels.loadFromCache(version: .v2)
                loaded = true
            } catch {
                self?.errors[.batchParakeet] = "Dictation model: \(error.localizedDescription)"
                NSLog("Heard: Dictation model (English Optimized) download failed: \(error)")
            }
            self?.dictationTask = nil
            self?.refreshStatuses()
            if loaded { self?.onDictationEngineReady?() }
        }
    }

    public func download(_ kind: ModelKind) {
        guard activeTasks[kind] == nil else { return }
        errors[kind] = nil
        catalog.markDownloading(kind)
        downloadProgress[kind] = 0

        let selectedVersion = transcriptionModel
        let dictationOn = dictationEnabled

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
                    // Only the selected meeting engine is fetched; dictation's model is handled separately.
                    if selectedVersion.usesUnifiedEngine {
                        let manager = UnifiedAsrManager()
                        try await manager.loadModels(progressHandler: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress[.batchParakeet] = progress.fractionCompleted
                            }
                        })
                        await manager.cleanup()
                    } else {
                        let fluidVersion: AsrModelVersion = selectedVersion == .v3 ? .v3 : .v2
                        let _ = try await AsrModels.loadFromCache(version: fluidVersion) { [weak self] progress in
                            Task { @MainActor [weak self] in
                                self?.downloadProgress[.batchParakeet] = progress.fractionCompleted
                            }
                        }
                    }
                    catalog.markReady(.batchParakeet, detail: ModelDownloadManager.batchDetail(readiness: "Ready", selected: selectedVersion, dictationEnabled: dictationOn))

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
                NSLog("Heard: Model download failed for \(kind): \(error)")
            }
            downloadProgress[kind] = nil
            activeTasks[kind] = nil
            if kind == .batchParakeet { refreshStatuses() }
        }
    }

    public func cancel(_ kind: ModelKind) {
        activeTasks[kind]?.cancel()
        activeTasks[kind] = nil
        downloadProgress[kind] = nil
    }

    // MARK: - Batch engine readiness

    /// Detail line for the batch ASR row. With English Unified selected and dictation on, dictation
    /// needs English (Optimized) as well, so its state is appended.
    nonisolated public static func batchDetail(readiness: String, selected: TranscriptionModel, dictationEnabled: Bool) -> String {
        guard selected.usesUnifiedEngine, dictationEnabled else { return readiness }
        let v2Ready = DictationManager.englishOptimizedCached()
        return "\(readiness) · dictation: \(TranscriptionModel.v2.displayName) \(v2Ready ? "ready" : "not downloaded")"
    }

    /// The selected meeting ASR engine's files are present. Unified checks its own bundle set.
    nonisolated static func batchEngineReady(_ selected: TranscriptionModel) -> Bool {
        switch selected {
        case .unified: return UnifiedModelAssets.isCached
        case .v2: return tdtModelsPresent(version: .v2, repo: .parakeetV2)
        case .v3: return tdtModelsPresent(version: .v3, repo: .parakeetV3)
        }
    }

    /// Parakeet TDT files for `version` exist in FluidAudio's default or Heard's legacy cache.
    nonisolated private static func tdtModelsPresent(version: AsrModelVersion, repo: Repo) -> Bool {
        let defaultDir = AsrModels.defaultCacheDirectory(for: version)
        let customDir = FileManager.default.heardAppSupportDirectory
            .appendingPathComponent(repo.folderName, isDirectory: true)
        return AsrModels.modelsExist(at: defaultDir) || AsrModels.modelsExist(at: customDir)
    }
}
