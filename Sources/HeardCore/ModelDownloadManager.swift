import FluidAudio
import Foundation

/// Readiness of the dictation TDT engine: English (Optimized) when English Unified is selected,
/// otherwise the selected v2 or v3 model. Derived from the disk cache plus in-memory attempt state.
public enum DictationReadiness: Equatable {
    /// Dictation is off, so no dictation model is needed.
    case notRequired
    case notDownloaded
    case downloading
    case ready
    /// The last attempt failed with this message. `prepareDictationEngine()` retries.
    case failed(String)
}

/// Thrown by `prepareDictationEngine()` when the download finished but the engine is not cache-complete.
public enum DictationReadinessError: Error, LocalizedError {
    case notReady

    public var errorDescription: String? {
        "The dictation model finished downloading but is incomplete. Retry the download."
    }
}

/// Loads a dictation TDT engine, downloading it when missing.
public typealias DictationEngineLoader = @MainActor (TranscriptionModel) async throws -> Void

/// True when a dictation TDT engine's files are complete in FluidAudio's default cache.
public typealias DictationEngineCacheCheck = @MainActor (TranscriptionModel) -> Bool

/// Manages pre-downloading CoreML models so they're ready when a meeting ends.
/// FluidAudio auto-downloads models on first use, but pre-downloading avoids delays
/// after the first meeting.
@MainActor
public final class ModelDownloadManager: ObservableObject {

    @Published public private(set) var downloadProgress: [ModelKind: Double] = [:]
    @Published public private(set) var errors: [ModelKind: String] = [:]
    /// Single authority for dictation readiness. Recomputed from disk and in-memory attempt state.
    @Published public private(set) var dictationReadiness: DictationReadiness = .notRequired

    private var activeTasks: [ModelKind: Task<Void, Never>] = [:]
    private let catalog: ModelCatalog
    private let dictationLoader: DictationEngineLoader
    private let dictationCached: DictationEngineCacheCheck

    /// One in-flight dictation download. Its id decides whether an outcome may still be published.
    private struct DictationAttempt {
        let id: UUID
        let engine: TranscriptionModel
        let task: Task<Void, Error>
    }
    private var dictationAttempt: DictationAttempt?
    /// Last failed dictation attempt. Cleared on disable, engine change, or a new attempt.
    private var dictationFailure: (engine: TranscriptionModel, message: String)?

    /// The selected meeting transcription model; drives batch readiness and download.
    public var transcriptionModel: TranscriptionModel = .unified {
        didSet { reconcileDictation() }
    }

    /// Whether dictation is enabled. Changing it cancels or clears dictation state that no longer applies.
    public var dictationEnabled = false {
        didSet { reconcileDictation() }
    }

    /// Called on the main actor after a dictation engine download succeeds for the current engine.
    public var onDictationEngineReady: (@MainActor () -> Void)?

    public init(
        catalog: ModelCatalog,
        dictationLoader: DictationEngineLoader? = nil,
        dictationCached: DictationEngineCacheCheck? = nil
    ) {
        self.catalog = catalog
        if let dictationLoader {
            self.dictationLoader = dictationLoader
        } else {
            self.dictationLoader = { engine in try await ModelDownloadManager.loadDictationEngineFromCache(engine) }
        }
        if let dictationCached {
            self.dictationCached = dictationCached
        } else {
            self.dictationCached = { engine in ModelDownloadManager.dictationCacheReady(engine) }
        }
        refreshStatuses()
    }

    /// Check which models are already cached by looking at FluidAudio's actual cache locations.
    public func refreshStatuses() {
        recomputeDictationReadiness()
        let fm = FileManager.default

        // VAD: FluidAudio stores in ~/Library/Application Support/FluidAudio/Models/silero-vad-coreml/
        let fluidModelsDir = AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent()
        let vadDir = fluidModelsDir.appendingPathComponent(Repo.vad.folderName, isDirectory: true)
        if fm.fileExists(atPath: vadDir.path) {
            catalog.markReady(.batchVad)
        }

        // Parakeet: only the selected meeting engine counts toward readiness.
        if ModelDownloadManager.batchEngineReady(transcriptionModel) {
            catalog.markReady(.batchParakeet, detail: batchRowDetail(readiness: "Ready"))
        } else if activeTasks[.batchParakeet] == nil {
            catalog.markNotDownloaded(.batchParakeet, detail: batchRowDetail(readiness: "Download required"))
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

    /// Auto trigger for launch, enable, and selection change. Starts one download when dictation is on
    /// and its engine is not cached. Never throws; failures show in `dictationReadiness`.
    public func downloadDictationEngineIfNeeded() {
        _ = attemptIfNeeded()
    }

    /// Explicit trigger for the hotkey and retry. Returns at once when dictation is off or the engine is
    /// cached. Otherwise awaits the one in-flight download, or starts one (a failed state is retried).
    /// Throws the download error so the caller can report it.
    public func prepareDictationEngine() async throws {
        guard let attempt = attemptIfNeeded() else { return }
        try await attempt.task.value
        // Re-check after the await: a disable or engine change may have superseded this attempt.
        // Never report a superseded engine as prepared.
        guard currentDictationEngine == attempt.engine else { throw CancellationError() }
        guard dictationCached(attempt.engine) else { throw DictationReadinessError.notReady }
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

    // MARK: - Dictation engine

    /// The dictation TDT engine for the current selection; nil when dictation is off.
    private var currentDictationEngine: TranscriptionModel? {
        dictationEnabled ? transcriptionModel.dictationEngine : nil
    }

    /// The attempt for the current engine, starting one when that engine is not cached.
    /// Returns nil when dictation is off or the engine is already cached.
    private func attemptIfNeeded() -> DictationAttempt? {
        guard let engine = currentDictationEngine else { return nil }
        if let existing = dictationAttempt, existing.engine == engine { return existing }
        guard !dictationCached(engine) else { return nil }
        return startDictationAttempt(engine)
    }

    private func startDictationAttempt(_ engine: TranscriptionModel) -> DictationAttempt {
        dictationAttempt?.task.cancel()
        let id = UUID()
        let load = dictationLoader
        let task = Task<Void, Error> { [weak self] in
            do {
                try await load(engine)
            } catch {
                self?.finishDictationAttempt(id: id, engine: engine, error: error)
                throw error
            }
            if let notReady = self?.finishDictationAttempt(id: id, engine: engine, error: nil) {
                throw notReady
            }
        }
        let attempt = DictationAttempt(id: id, engine: engine, task: task)
        dictationAttempt = attempt
        dictationFailure = nil
        refreshStatuses()
        return attempt
    }

    /// Applies an attempt's outcome only while it is still the current attempt. A cancelled or
    /// superseded attempt returns without touching state, so it cannot publish stale ready or errors.
    /// Returns the error the attempt must throw. A load that returns while the cache is still incomplete
    /// publishes `failed(notReady)` and never fires `onDictationEngineReady`.
    @discardableResult
    private func finishDictationAttempt(id: UUID, engine: TranscriptionModel, error: Error?) -> Error? {
        guard dictationAttempt?.id == id else { return nil }
        dictationAttempt = nil
        var outcome = error
        if outcome == nil, !dictationCached(engine) {
            outcome = DictationReadinessError.notReady
        }
        guard let outcome else {
            dictationFailure = nil
            refreshStatuses()
            onDictationEngineReady?()
            return nil
        }
        dictationFailure = (engine, outcome.localizedDescription)
        NSLog("Heard: Dictation model (\(engine.displayName)) download failed: \(outcome)")
        refreshStatuses()
        return outcome
    }

    /// Cancels an attempt for an engine that no longer applies, drops failures that no longer apply, and republishes.
    private func reconcileDictation() {
        if let attempt = dictationAttempt, attempt.engine != currentDictationEngine {
            attempt.task.cancel()
            dictationAttempt = nil
        }
        if let failure = dictationFailure, failure.engine != currentDictationEngine {
            dictationFailure = nil
        }
        refreshStatuses()
    }

    private func recomputeDictationReadiness() {
        guard let engine = currentDictationEngine else {
            dictationReadiness = .notRequired
            return
        }
        if dictationCached(engine) {
            dictationReadiness = .ready
        } else if dictationAttempt?.engine == engine {
            dictationReadiness = .downloading
        } else if let failure = dictationFailure, failure.engine == engine {
            dictationReadiness = .failed(failure.message)
        } else {
            dictationReadiness = .notDownloaded
        }
    }

    private var dictationStatusText: String {
        switch dictationReadiness {
        case .notRequired: return ""
        case .notDownloaded: return "not downloaded"
        case .downloading: return "downloading"
        case .ready: return "ready"
        case .failed(let message): return "failed (\(message))"
        }
    }

    /// Batch row detail. With English Unified selected and dictation on, dictation's state is appended.
    private func batchRowDetail(readiness: String) -> String {
        guard transcriptionModel.usesUnifiedEngine, dictationEnabled else { return readiness }
        return "\(readiness) · dictation: \(TranscriptionModel.v2.displayName) \(dictationStatusText)"
    }

    /// Exact loader predicate for a dictation engine: its FluidAudio default cache directory is complete.
    /// The same directory and check that `loadDictationEngineFromCache` loads from.
    nonisolated static func dictationCacheReady(_ engine: TranscriptionModel) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: fluidVersion(engine)))
    }

    nonisolated static func loadDictationEngineFromCache(_ engine: TranscriptionModel) async throws {
        _ = try await AsrModels.loadFromCache(version: fluidVersion(engine))
    }

    /// Maps through `dictationEngine`, so English Unified resolves to the v2 dictation engine.
    nonisolated private static func fluidVersion(_ engine: TranscriptionModel) -> AsrModelVersion {
        engine.dictationEngine == .v3 ? .v3 : .v2
    }

    // MARK: - Batch engine readiness

    /// Detail line for the batch ASR row, computed from disk. Used by the pipeline when a job finishes.
    nonisolated public static func batchDetail(readiness: String, selected: TranscriptionModel, dictationEnabled: Bool) -> String {
        guard selected.usesUnifiedEngine, dictationEnabled else { return readiness }
        let v2Ready = dictationCacheReady(.v2)
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
