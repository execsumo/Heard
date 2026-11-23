import AVFoundation
import FluidAudio
import Foundation

public enum DictationState: String {
    case idle
    case loading
    case listening
    case transcribing
}

public enum DictationError: Error, LocalizedError {
    case notIdle(current: DictationState)
    case microphoneDenied
    case micStalled
    case englishOptimizedNotDownloaded
    /// A start was superseded by a stop, a meeting, a model change, or an unload. Not shown to the user.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notIdle(let s):
            return "Cannot start dictation: already \(s.rawValue). Please wait for the current operation to finish."
        case .microphoneDenied:
            return "Microphone access is required for dictation. Grant it in System Settings → Privacy & Security → Microphone."
        case .micStalled:
            return "The microphone didn't start delivering audio. Try dictating again; if it keeps happening, unplug/replug your input device or restart Heard."
        case .englishOptimizedNotDownloaded:
            return "Dictation needs English (Optimized), which isn't downloaded yet. Download it from the Models tab, then try again."
        case .cancelled:
            return "Dictation was cancelled."
        }
    }
}

/// Transcript type returned by a dictation engine. Lets callers name it without importing FluidAudio.
public typealias DictationTranscription = ASRResult

/// Batch speech engine for dictation sessions.
@MainActor
public protocol DictationEngine: AnyObject {
    func transcribe(_ samples: [Float]) async throws -> DictationTranscription
}

/// Supplies the engine dictation runs for a selected transcription model.
/// Production waits for model readiness, then loads from cache. Tests inject fakes.
@MainActor
public protocol DictationEngineProvider: AnyObject {
    func loadEngine(for selection: TranscriptionModel) async throws -> DictationEngine
}

/// Microphone capture for dictation. Samples arrive as 16 kHz mono on the main actor.
@MainActor
public protocol DictationMicSource: AnyObject {
    /// True when microphone access was denied or restricted.
    var isMicrophoneDenied: Bool { get }
    /// Starts capture. Throws only after releasing anything it acquired. `deliver` runs until `stop()` or `cancel()`.
    func start(deviceUID: String?, deliver: @escaping @MainActor ([Float]) -> Void) throws
    /// Stops capture after delivering audio already buffered.
    func stop() async
    /// Stops capture now and discards buffered audio. Safe to call repeatedly.
    func cancel()
}

/// Manages burst-mode dictation using FluidAudio's batch `AsrManager` (Parakeet
/// TDT). The user presses a hotkey, speaks, presses again; on stop the full
/// session audio is transcribed in one pass with optional vocabulary rescoring,
/// and the result is delivered through `onUtterance`.
///
/// Session model: every start gets a session ID. Anything that can finish late
/// (model load, first-buffer wait, mic callbacks) checks the ID before it
/// changes state or captures audio, so a cancelled or superseded start cannot
/// clobber a newer session or leave the microphone running.
@MainActor
public final class DictationManager: ObservableObject {

    /// Authority for dictation phase. `.loading` means preparing: no microphone yet.
    @Published public private(set) var state: DictationState = .idle

    /// Selected transcription model. Dictation runs `engine`, which is English (Optimized)
    /// while English Unified is selected. Changing the engine cancels a pending start.
    public var modelVersion: TranscriptionModel = .unified {
        didSet {
            if oldValue.dictationEngine != modelVersion.dictationEngine, state == .loading {
                cancelPendingStart()
            }
        }
    }

    /// The TDT engine dictation uses for the current selection.
    private var engine: TranscriptionModel { modelVersion.dictationEngine }

    /// Called when transcription completes for a session with the final text. Runs on the main actor.
    public var onUtterance: (@MainActor (String) -> Void)?

    /// Called when a stop produced no usable text despite the user having listened for a non-trivial
    /// duration. Runs on the main actor.
    public var onNoAudioCaptured: (@MainActor () -> Void)?

    /// Called with a user-facing message when a finished session cannot be transcribed. Runs on the main actor.
    public var onFailure: (@MainActor (String) -> Void)?

    /// Custom vocabulary terms for boosting. Applied as CTC rescoring after
    /// the TDT transcription completes. Silently skipped when the CTC model is missing.
    public var customVocabulary: [String] = []

    /// Custom formatting commands for ITN.
    public var formattingCommands: [FormattingCommand] = []

    /// How long to keep the model loaded after dictation stops (seconds).
    public var modelKeepAliveSeconds: TimeInterval = 120

    /// CoreAudio UID of the input device to capture from. nil = follow the system default input.
    public var inputDeviceUID: String?

    /// Samples buffered for the current session. Read-only diagnostic.
    public var bufferedSampleCount: Int { audioBuffer.count }

    /// FluidAudio's default location for English (Optimized), the model dictation runs under English Unified.
    nonisolated public static var englishOptimizedCacheDirectory: URL { AsrModels.defaultCacheDirectory(for: .v2) }

    /// True when English (Optimized) loads from `directory`. The single check for dictation's v2 model.
    nonisolated public static func englishOptimizedCached(at directory: URL = englishOptimizedCacheDirectory) -> Bool {
        AsrModels.modelsExist(at: directory)
    }

    private let provider: DictationEngineProvider
    private let mic: DictationMicSource

    /// Identifies the current start or listen session. Bumped on every transition out of a session.
    private var sessionID: UInt64 = 0
    /// Identifies the current engine load. Bumped when a new load starts and when the engine is dropped.
    private var loadGeneration: UInt64 = 0
    /// Engine kept for later sessions. Nil until loaded, and after an unload or an engine change.
    private var asrEngine: DictationEngine?
    private var loadedEngine: TranscriptionModel?
    /// The single in-flight engine load. Preload and start share it instead of loading twice.
    private var inFlightLoad: InFlightLoad?
    /// Engine captured when the current session started. Stop uses this, so a concurrent engine change cannot affect it.
    private var sessionEngine: DictationEngine?

    private var audioBuffer: [Float] = []
    private var unloadTask: Task<Void, Never>?
    private var bufferCount = 0
    private var bufferCapWarned = false
    /// Set once the first mic buffer of the current session lands. Used to confirm the tap delivers audio.
    private var firstBufferArrived = false
    private var micStartedAt: Date?
    /// Wall-clock time the session entered `.listening`, used to distinguish a genuine capture failure from a quick tap.
    private var listeningStartedAt: Date?

    /// Hard cap on buffered audio: 4 hours at 16 kHz (matches the recording manager's max duration).
    private static let maxBufferSamples = 4 * 3600 * 16_000

    private struct InFlightLoad {
        let id: UInt64
        let engine: TranscriptionModel
        let task: Task<Void, Error>
    }

    public init(provider: DictationEngineProvider, mic: DictationMicSource) {
        self.provider = provider
        self.mic = mic
    }

    /// Production wiring. `prepareEngine` runs before each engine load: it waits for or starts the
    /// model download and throws if the model is still unavailable.
    public convenience init(
        prepareEngine: @escaping @MainActor (TranscriptionModel) async throws -> Void = { _ in }
    ) {
        self.init(
            provider: FluidDictationEngineProvider(prepare: prepareEngine),
            mic: AVDictationMicSource()
        )
    }

    // MARK: - Public API

    /// Starts a session. Throws `DictationError.cancelled` if a stop, meeting, unload, or model change supersedes it.
    /// Every failure leaves `state == .idle` and the microphone released, so a later start can retry.
    @discardableResult
    public func start() async throws -> UInt64 {
        // An attempt cancelled before it first ran must not touch the model, the mic, or the state.
        if Task.isCancelled { throw DictationError.cancelled }
        DebugFileLog.log("DictationManager.start entry — state=\(state.rawValue) asrLoaded=\(asrEngine != nil) inputUID=\(inputDeviceUID ?? "default")")
        guard state == .idle else {
            DebugFileLog.log("DictationManager.start refused — not idle (state=\(state.rawValue))")
            throw DictationError.notIdle(current: state)
        }
        // Checked before any state change: a denied microphone must not reach the loading path.
        if mic.isMicrophoneDenied {
            DebugFileLog.log("DictationManager.start throwing microphoneDenied")
            throw DictationError.microphoneDenied
        }

        unloadTask?.cancel()
        unloadTask = nil

        let session = beginSession()
        var listening = false
        defer {
            if !listening { rollback(session) }
        }

        let loaded = try await ensureEngineLoaded()
        try checkCurrent(session)

        // Custom formatting rules are applied only for sessions that get this far.
        TextNormalizer.shared.clearRules()
        for cmd in formattingCommands {
            TextNormalizer.shared.addRule(spoken: cmd.spoken, written: cmd.written)
        }

        audioBuffer.removeAll(keepingCapacity: true)
        bufferCapWarned = false
        try startMicCapture(session: session)
        try checkCurrent(session)

        // Confirm the tap delivers audio. A stalled tap is rebuilt once, then reported.
        let delivering = await waitForFirstBuffer(session: session, timeout: 0.75)
        try checkCurrent(session)
        if !delivering {
            DebugFileLog.log("DictationManager.start mic tap stalled (<750ms no audio) — rebuilding engine once")
            mic.cancel()
            audioBuffer.removeAll(keepingCapacity: true)
            bufferCapWarned = false
            try startMicCapture(session: session)
            try checkCurrent(session)
            let recovered = await waitForFirstBuffer(session: session, timeout: 1.0)
            try checkCurrent(session)
            guard recovered else {
                DebugFileLog.log("DictationManager.start mic tap still stalled after rebuild — throwing micStalled")
                throw DictationError.micStalled
            }
            DebugFileLog.log("DictationManager.start mic tap recovered after rebuild")
        }

        sessionEngine = loaded
        listeningStartedAt = Date()
        state = .listening
        listening = true
        DebugFileLog.log("DictationManager.start success — state=listening")
        return session
    }

    /// Cancels a start that is still loading or waiting for audio. Synchronous: the microphone is
    /// released before this returns, and nothing from the cancelled start is delivered afterwards.
    /// Does nothing in other states.
    public func cancelPendingStart() {
        guard state == .loading else { return }
        DebugFileLog.log("DictationManager.cancelPendingStart — state=loading")
        endSessionResources()
        state = .idle
        scheduleModelUnload()
    }

    /// Ends dictation in whatever phase it is: cancels a pending start, or stops and transcribes a listening session.
    public func requestStop() async {
        switch state {
        case .loading:
            cancelPendingStart()
        case .listening:
            await stop()
        case .idle, .transcribing:
            return
        }
    }

    /// Stops the listening session `session` only if it is still the current one. A superseded start uses this
    /// so it can never stop a newer session.
    public func requestStop(session: UInt64) async {
        guard state == .listening, session == sessionID else {
            DebugFileLog.log("DictationManager.requestStop(session:) ignored — stale session \(session)")
            return
        }
        await stop()
    }

    /// The session ID of the current listening session. Read before a stop is scheduled, so the stop targets that session only.
    public var currentSession: UInt64 { sessionID }
    public func stop() async {
        DebugFileLog.log("DictationManager.stop entry — state=\(state.rawValue) bufferCount=\(bufferCount) sampleCount=\(audioBuffer.count)")
        guard state == .listening else {
            DebugFileLog.log("DictationManager.stop refused — not listening (state=\(state.rawValue))")
            return
        }

        let listenedFor = listeningStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        listeningStartedAt = nil

        // Set before the drain await so a second stop cannot run concurrently.
        state = .transcribing
        defer {
            state = .idle
            scheduleModelUnload()
            DebugFileLog.log("DictationManager.stop exit — back to idle")
        }

        // Flush buffered audio into the sample buffer, then end this session so late callbacks are dropped.
        await mic.stop()
        DebugFileLog.log("DictationManager.stop drain complete — sampleCount=\(audioBuffer.count)")
        sessionID &+= 1

        let transcriber = sessionEngine
        sessionEngine = nil
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)

        // Parakeet requires at least 1s of audio (16k samples at 16kHz).
        let minSamples = 16_000
        guard samples.count >= minSamples else {
            NSLog("Heard: Dictation audio too short to transcribe (%d samples)", samples.count)
            DebugFileLog.log("DictationManager.stop short audio — sampleCount=\(samples.count) < \(minSamples) listenedFor=\(String(format: "%.1f", listenedFor))s")
            notifyIfAudioWasExpected(listenedFor: listenedFor)
            return
        }

        guard let transcriber else {
            DebugFileLog.log("DictationManager.stop no engine for session — reporting failure")
            onFailure?("Dictation stopped before its speech model was ready. Try again.")
            return
        }

        do {
            DebugFileLog.log("DictationManager.stop calling transcribe — samples=\(samples.count)")
            let result = try await transcriber.transcribe(samples)
            DebugFileLog.log("DictationManager.stop transcribe returned — rawLen=\(result.text.count)")
            let boosted = await rescoreWithVocabulary(result: result, samples: samples)
            let normalized = TextNormalizer.shared.normalize(result: boosted).text
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugFileLog.log("DictationManager.stop final len=\(trimmed.count)")
            guard !trimmed.isEmpty else {
                DebugFileLog.log("DictationManager.stop empty after normalize — skipping inject listenedFor=\(String(format: "%.1f", listenedFor))s")
                notifyIfAudioWasExpected(listenedFor: listenedFor)
                return
            }
            DebugFileLog.log("DictationManager.stop firing onUtterance")
            onUtterance?(trimmed)
        } catch {
            NSLog("Heard: Dictation transcription failed: %@", error.localizedDescription)
            DebugFileLog.log("DictationManager.stop transcribe threw: \(error)")
            onFailure?("Dictation couldn't transcribe that. \(error.localizedDescription)")
        }
    }

    /// Notifies the UI of a no-speech result, but only when the user held the
    /// session long enough that they clearly expected audio.
    private func notifyIfAudioWasExpected(listenedFor: TimeInterval) {
        guard listenedFor >= 1.5 else { return }
        DebugFileLog.log("DictationManager firing onNoAudioCaptured — listenedFor=\(String(format: "%.1f", listenedFor))s")
        onNoAudioCaptured?()
    }

    public func toggle() async throws {
        if state == .listening {
            await stop()
        } else if state == .idle {
            try await start()
        }
    }

    // MARK: - Model loading

    /// Starts loading the engine in the background so the first press doesn't pay the cold-start cost.
    /// Shares the in-flight load with a concurrent start. No-op when the engine is already loaded.
    public func preloadModelsInBackground() {
        guard asrEngine == nil || loadedEngine != engine else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.ensureEngineLoaded()
                NSLog("Heard: Dictation TDT model preloaded")
            } catch {
                NSLog("Heard: Dictation TDT preload failed: %@", error.localizedDescription)
            }
        }
    }

    /// Returns the engine for the current selection, loading it if needed.
    /// Throws `DictationError.cancelled` if the engine was dropped or changed while loading.
    private func ensureEngineLoaded() async throws -> DictationEngine {
        let target = engine
        if let loaded = asrEngine, loadedEngine == target {
            return loaded
        }
        if let load = inFlightLoad, load.engine == target {
            try await load.task.value
        } else {
            try await startEngineLoad(for: target)
        }
        guard let loaded = asrEngine, loadedEngine == target else {
            throw DictationError.cancelled
        }
        return loaded
    }

    private func startEngineLoad(for target: TranscriptionModel) async throws {
        dropLoadedEngine()
        let id = loadGeneration
        let selection = modelVersion
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            let loaded: DictationEngine
            do {
                loaded = try await self.provider.loadEngine(for: selection)
            } catch is CancellationError {
                throw DictationError.cancelled
            }
            // Install only if no unload or new load happened meanwhile, and the selection still wants this engine.
            guard self.loadGeneration == id, self.engine == target else { return }
            self.asrEngine = loaded
            self.loadedEngine = target
        }
        inFlightLoad = InFlightLoad(id: id, engine: target, task: task)
        defer {
            if inFlightLoad?.id == id { inFlightLoad = nil }
        }
        try await task.value
    }

    /// Drops the loaded engine. Bumps the load generation so an in-flight load cannot install itself afterwards.
    private func dropLoadedEngine() {
        loadGeneration &+= 1
        asrEngine = nil
        loadedEngine = nil
    }

    // MARK: - Vocabulary rescoring

    /// Runs CTC keyword spotting over the same audio, then rewrites low-confidence words against the
    /// user's vocabulary. Skipped silently when no terms are set or the CTC model is not downloaded.
    private func rescoreWithVocabulary(result: ASRResult, samples: [Float]) async -> ASRResult {
        guard !customVocabulary.isEmpty else { return result }

        let ctcDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard CtcModels.modelsExist(at: ctcDir) else {
            NSLog("Heard: Dictation vocab boost skipped — CTC 110M not downloaded")
            return result
        }

        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            return result
        }

        do {
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: ctcDir)
            let terms = customVocabulary.map { term -> CustomVocabularyTerm in
                let ids = tokenizer.encode(term)
                return CustomVocabularyTerm(
                    text: term, weight: 10.0,
                    ctcTokenIds: ids.isEmpty ? nil : ids,
                    minSimilarity: term.defaultVocabularySimilarityThreshold
                )
            }
            let context = CustomVocabularyContext(terms: terms)
            let spotter = CtcKeywordSpotter(models: ctcModels)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: context, ctcModelDirectory: ctcDir
            )
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: context
            )
            let rescored = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration
            )
            guard rescored.wasModified else { return result }
            let detected = spot.detections.map(\.term.text)
            let applied = rescored.replacements
                .filter(\.shouldReplace)
                .compactMap(\.replacementWord)
            return result.withRescoring(text: rescored.text, detected: detected, applied: applied)
        } catch {
            NSLog("Heard: Dictation vocab boost failed — keeping raw transcript: %@", error.localizedDescription)
            return result
        }
    }

    // MARK: - Session lifecycle

    /// Starts a new session. Synchronous, so the state change happens before the first suspension.
    private func beginSession() -> UInt64 {
        sessionID &+= 1
        state = .loading
        return sessionID
    }

    private func checkCurrent(_ session: UInt64) throws {
        guard session == sessionID else { throw DictationError.cancelled }
    }

    /// Unwinds a start that failed or was superseded. Does nothing if a newer session owns the state.
    /// The loaded engine is kept, so a retry does not reload it.
    private func rollback(_ session: UInt64) {
        guard session == sessionID, state == .loading else { return }
        endSessionResources()
        state = .idle
        scheduleModelUnload()
    }

    /// Releases the microphone and discards session audio. Bumps the session so late callbacks are dropped.
    private func endSessionResources() {
        sessionID &+= 1
        mic.cancel()
        audioBuffer.removeAll(keepingCapacity: true)
        listeningStartedAt = nil
        sessionEngine = nil
    }

    // MARK: - Mic capture

    private func startMicCapture(session: UInt64) throws {
        bufferCount = 0
        firstBufferArrived = false
        micStartedAt = Date()
        try mic.start(deviceUID: inputDeviceUID) { [weak self] samples in
            self?.appendSamples(samples, session: session)
        }
    }

    /// Polls for the first mic buffer of `session`. Returns early when the session is no longer current.
    private func waitForFirstBuffer(session: UInt64, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while session == sessionID && !firstBufferArrived && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return session == sessionID && firstBufferArrived
    }

    private func appendSamples(_ samples: [Float], session: UInt64) {
        // A late buffer from a cancelled or finished session must not reach the current one.
        guard session == sessionID else { return }
        guard audioBuffer.count < Self.maxBufferSamples else {
            if !bufferCapWarned {
                bufferCapWarned = true
                NSLog("Heard: Dictation buffer hit the 4-hour cap — dropping further audio until stop")
            }
            return
        }
        audioBuffer.append(contentsOf: samples)
        bufferCount += 1
        if bufferCount == 1 {
            firstBufferArrived = true
            let latencyMs = micStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            NSLog("Heard: Dictation received first mic buffer")
            DebugFileLog.log("appendSamples first buffer received — samples=\(samples.count) latencyMs=\(latencyMs.map(String.init) ?? "?")")
        } else if bufferCount % 60 == 0 {
            NSLog("Heard: Dictation buffers streamed=%d totalSamples=%d", bufferCount, audioBuffer.count)
            DebugFileLog.log("appendSamples buffers=\(bufferCount) totalSamples=\(audioBuffer.count)")
        }
    }

    // MARK: - Model lifecycle

    private func scheduleModelUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.modelKeepAliveSeconds ?? 120))
            guard let self, !Task.isCancelled else { return }
            self.unloadModels()
        }
    }

    /// Drops the cached engine. Ignored while a session or load is active, so it cannot pull the engine out from under a start.
    public func unloadModels() {
        guard state == .idle else { return }
        unloadTask?.cancel()
        unloadTask = nil
        dropLoadedEngine()
        inFlightLoad = nil
        NSLog("Heard: Dictation models unloaded")
    }
}
