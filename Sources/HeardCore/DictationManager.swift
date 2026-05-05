import AVFoundation
import FluidAudio
import Foundation

public enum DictationState: String {
    case idle
    case loading
    case listening
}

public enum DictationError: Error, LocalizedError {
    case notIdle(current: DictationState)

    public var errorDescription: String? {
        switch self {
        case .notIdle(let s):
            return "Cannot start dictation: already \(s.rawValue). Please wait for the current operation to finish."
        }
    }
}

/// Manages real-time dictation using FluidAudio's SlidingWindowAsrManager.
/// Audio is fed as AVAudioPCMBuffer; the manager handles overlapping windows and
/// stable/volatile split internally. Confirmed text is injected incrementally;
/// any remaining volatile text is flushed on stop.
@MainActor
public final class DictationManager: ObservableObject {

    @Published public private(set) var state: DictationState = .idle
    @Published public var partialTranscript: String = ""

    private var slidingWindowMgr: SlidingWindowAsrManager?
    private var asrModels: AsrModels?
    private var loadedModelVersion: TranscriptionModel?
    private var micEngine: AVAudioEngine?
    private var updateConsumerTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?

    /// Called when new transcribed text is ready for injection.
    public var onUtterance: ((String) -> Void)?

    /// Custom vocabulary terms for boosting. Set before calling start().
    public var customVocabulary: [String] = []

    /// Custom formatting commands for ITN. Set before calling start().
    public var formattingCommands: [FormattingCommand] = []

    /// Which Parakeet model version to use. Changing mid-session reloads models on the next start.
    public var modelVersion: TranscriptionModel = .v2

    /// How long to keep the model loaded after dictation stops (seconds).
    public var modelKeepAliveSeconds: TimeInterval = 120

    /// Full text injected so far in the current session (confirmed deltas only).
    private var injectedText: String = ""

    public init() {}

    // MARK: - Public API

    public func start() async throws {
        guard state == .idle else { throw DictationError.notIdle(current: state) }

        unloadTask?.cancel()
        unloadTask = nil

        state = .loading

        let fluidVersion: AsrModelVersion = modelVersion == .v2 ? .v2 : .v3

        // Load models if needed or version changed; otherwise reuse cached models.
        if asrModels == nil || loadedModelVersion != modelVersion {
            asrModels = nil
            loadedModelVersion = nil
            let models = try await AsrModels.loadFromCache(version: fluidVersion)
            asrModels = models
            loadedModelVersion = modelVersion
        }

        // Create a fresh sliding-window manager for this session.
        // SlidingWindowAsrManager's input stream is single-use (finish() closes it),
        // so a new instance is required each time.
        let mgr = SlidingWindowAsrManager(config: .streaming)
        try await mgr.loadModels(asrModels!)

        // Restore vocab boosting if terms are configured and CTC models are on disk.
        if !customVocabulary.isEmpty {
            let ctcDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
            if CtcModels.modelsExist(at: ctcDir) {
                do {
                    let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    let ctcTokenizer = try await CtcTokenizer.load(from: ctcDir)
                    let terms = customVocabulary.map { term -> CustomVocabularyTerm in
                        let tokenIds = ctcTokenizer.encode(term)
                        return CustomVocabularyTerm(
                            text: term, weight: 10.0,
                            ctcTokenIds: tokenIds.isEmpty ? nil : tokenIds
                        )
                    }
                    try await mgr.configureVocabularyBoosting(
                        vocabulary: CustomVocabularyContext(terms: terms),
                        ctcModels: ctcModels
                    )
                    NSLog("Heard: Dictation vocab boosting configured (%d terms)", customVocabulary.count)
                } catch {
                    NSLog("Heard: Dictation vocab boosting unavailable, continuing without: %@", error.localizedDescription)
                }
            }
        }

        // Apply custom formatting commands
        TextNormalizer.shared.clearRules()
        for cmd in formattingCommands {
            TextNormalizer.shared.addRule(spoken: cmd.spoken, written: cmd.written)
        }

        slidingWindowMgr = mgr
        injectedText = ""
        partialTranscript = ""

        try await mgr.startStreaming(source: .microphone)
        try startMicCapture(mgr: mgr)
        state = .listening

        startUpdateConsumer(mgr: mgr)
    }

    public func stop() async {
        guard state == .listening else { return }

        stopMicCapture()
        updateConsumerTask?.cancel()
        updateConsumerTask = nil

        // Flush remaining audio, inject final text, then clean up fully.
        // cleanup() closes the transcriptionUpdates AsyncStream so the consumer task can exit,
        // and releases the internal ASR manager — required before reusing asrModels next session.
        if let mgr = slidingWindowMgr {
            let finalText = (try? await mgr.finish()) ?? ""
            injectDelta(to: finalText)
            await mgr.cleanup()
        }

        slidingWindowMgr = nil
        injectedText = ""
        partialTranscript = ""
        state = .idle

        scheduleModelUnload()
    }

    public func toggle() async throws {
        if state == .listening {
            await stop()
        } else if state == .idle {
            try await start()
        }
    }

    // MARK: - Update consumption

    private func startUpdateConsumer(mgr: SlidingWindowAsrManager) {
        updateConsumerTask = Task { [weak self] in
            let updates = await mgr.transcriptionUpdates
            for await update in updates {
                guard let self, !Task.isCancelled else { break }
                await self.handleUpdate(update, mgr: mgr)
            }
        }
    }

    private func handleUpdate(
        _ update: SlidingWindowTranscriptionUpdate,
        mgr: SlidingWindowAsrManager
    ) async {
        let confirmed = await mgr.confirmedTranscript
        let volatile = await mgr.volatileTranscript

        // Apply Inverse Text Normalization for the UI display
        let normConfirmed = TextNormalizer.shared.normalizeSentence(confirmed)
        let normVolatile = TextNormalizer.shared.normalizeSentence(volatile)

        // Update the display with the full running transcript.
        partialTranscript = [normConfirmed, normVolatile].filter { !$0.isEmpty }.joined(separator: " ")

        // Inject using the unnormalized transcript to preserve prefix monotonicity,
        // then normalize the delta right before injecting.
        injectDelta(to: confirmed)
    }

    /// Filler words stripped before injection. Matched case-insensitively at word boundaries.
    private static let fillerWords: Set<String> = ["uh", "um", "er", "ah", "hmm", "hm", "uhh", "umm", "mhm"]

    /// Inject the portion of `newText` that extends beyond what we've already injected.
    private func injectDelta(to newText: String) {
        guard newText.count > injectedText.count else { return }
        // Confirmed text always grows — verify prefix hasn't changed.
        guard newText.hasPrefix(injectedText) else { return }

        let raw = String(newText.dropFirst(injectedText.count))
        // Strip filler words before injecting; always advance injectedText so we
        // don't reprocess the same chunk on subsequent calls.
        let needsLeadingSpace = !injectedText.isEmpty
        injectedText = newText
        let delta = stripFillers(raw).trimmingCharacters(in: .whitespaces)
        guard !delta.isEmpty else { return }

        let normalizedDelta = TextNormalizer.shared.normalizeSentence(delta)
        let noLeadingSpace = normalizedDelta.allSatisfy { $0.isPunctuation || $0.isNewline }
        let prefixSpace = (needsLeadingSpace && !noLeadingSpace) ? " " : ""

        onUtterance?(prefixSpace + normalizedDelta)
    }

    private func stripFillers(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let stripped = words.filter { word in
            let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return !Self.fillerWords.contains(bare)
        }
        return stripped.joined(separator: " ")
    }

    // MARK: - Mic Capture

    private func startMicCapture(mgr: SlidingWindowAsrManager) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // SlidingWindowAsrManager handles format conversion internally.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak mgr] buffer, _ in
            guard let mgr else { return }
            // Hop to the actor from the tap thread.
            Task { await mgr.streamAudio(buffer) }
        }

        engine.prepare()
        try engine.start()
        micEngine = engine
    }

    private func stopMicCapture() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }

    // MARK: - Model lifecycle

    private func scheduleModelUnload() {
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.modelKeepAliveSeconds ?? 120))
            guard let self, !Task.isCancelled else { return }
            self.unloadModels()
        }
    }

    public func unloadModels() {
        unloadTask?.cancel()
        unloadTask = nil
        asrModels = nil
        loadedModelVersion = nil
        NSLog("Heard: Dictation models unloaded")
    }
}
