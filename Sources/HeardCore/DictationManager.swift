import AVFoundation
import FluidAudio
import Foundation

public enum DictationState: String {
    case idle
    case loading
    case listening
}

/// Manages real-time dictation using FluidAudio's batch AsrManager with a polling loop.
/// Re-transcribes accumulated audio every 0.6s and uses stability-based tracking to
/// only inject words that have been consistent across consecutive transcription cycles.
@MainActor
public final class DictationManager: ObservableObject {

    @Published public private(set) var state: DictationState = .idle
    @Published public var partialTranscript: String = ""

    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var micEngine: AVAudioEngine?
    private var streamingTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?

    /// Thread-safe audio sample buffer
    private let audioBuffer = LockedAudioBuffer()

    /// Called when new transcribed text is ready for injection.
    public var onUtterance: ((String) -> Void)?

    /// Custom vocabulary terms to boost during transcription. Set before calling start().
    public var customVocabulary: [String] = []

    /// Vocabulary that was last configured on the ASR manager, to detect changes.
    private var configuredVocabulary: [String] = []

    /// How long to keep the model loaded after dictation stops (seconds).
    private let modelKeepAliveSeconds: TimeInterval = 120

    /// How often to re-transcribe accumulated audio (seconds).
    private let chunkInterval: TimeInterval = 0.6

    /// Minimum samples before attempting transcription (1s at 16kHz).
    private let minSamples: Int = 16000

    // MARK: - Injection tracking

    /// Words that have been injected into the target app (irreversible).
    private var committedWords: [String] = []

    /// Previous cycle's transcript split into words, for stability comparison.
    private var prevCycleWords: [String] = []

    public init() {}

    // MARK: - Public API

    public func start() async throws {
        guard state == .idle else { return }

        unloadTask?.cancel()
        unloadTask = nil

        state = .loading

        // Load batch ASR models if needed
        if asrModels == nil {
            let models = try await AsrModels.loadFromCache(version: .v2)
            asrModels = models
        }

        if asrManager == nil {
            let manager = AsrManager(config: ASRConfig.default)
            try await manager.initialize(models: asrModels!)
            asrManager = manager
            configuredVocabulary = []
        }

        // (Re)configure vocabulary boosting if terms changed since last start
        if customVocabulary != configuredVocabulary, let manager = asrManager {
            if customVocabulary.isEmpty {
                await manager.disableVocabularyBoosting()
                configuredVocabulary = []
            } else {
                do {
                    let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                    let ctcTokenizer = try await CtcTokenizer.load(
                        from: CtcModels.defaultCacheDirectory(for: .ctc110m)
                    )
                    let terms = customVocabulary.map { term in
                        let tokenIds = ctcTokenizer.encode(term)
                        return CustomVocabularyTerm(text: term, weight: 10.0, ctcTokenIds: tokenIds.isEmpty ? nil : tokenIds)
                    }
                    let context = CustomVocabularyContext(terms: terms)
                    try await manager.configureVocabularyBoosting(
                        vocabulary: context,
                        ctcModels: ctcModels
                    )
                    configuredVocabulary = customVocabulary
                    NSLog("Heard: Vocab boosting configured with \(terms.count) terms")
                } catch {
                    NSLog("Heard: Vocab boosting failed: \(error)")
                }
            }
        }

        // Reset state
        audioBuffer.clear()
        committedWords = []
        prevCycleWords = []
        partialTranscript = ""

        // Start mic capture
        try startMicCapture()
        state = .listening

        // Start streaming transcription loop
        startStreamingLoop()
    }

    public func stop() async {
        guard state == .listening else { return }

        stopMicCapture()
        streamingTask?.cancel()
        streamingTask = nil

        // Do one final transcription of all accumulated audio
        await transcribeAccumulated(isFinal: true)

        audioBuffer.clear()
        committedWords = []
        prevCycleWords = []
        partialTranscript = ""
        state = .idle

        // Schedule model unload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.modelKeepAliveSeconds ?? 120))
            guard let self, !Task.isCancelled else { return }
            self.unloadModels()
        }
    }

    public func toggle() async throws {
        if state == .listening {
            await stop()
        } else if state == .idle {
            try await start()
        }
    }

    // MARK: - Streaming Loop

    private func startStreamingLoop() {
        streamingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { break }
                await self.transcribeAccumulated(isFinal: false)
            }
        }
    }

    private func transcribeAccumulated(isFinal: Bool) async {
        guard let manager = asrManager else { return }

        let sampleCount = audioBuffer.count
        guard sampleCount >= minSamples else { return }

        let samples = audioBuffer.getSamples()

        do {
            let result = try await manager.transcribe(samples)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty else { return }

            let words = trimmed.split(separator: " ").map(String.init)
            partialTranscript = trimmed

            if isFinal {
                injectFinal(words)
            } else {
                injectStable(words)
            }
        } catch {
            NSLog("Heard: Dictation transcription error: \(error)")
        }
    }

    // MARK: - Stability-based injection

    /// Inject words that are stable (same in this cycle and the previous cycle)
    /// and haven't been injected yet.
    private func injectStable(_ words: [String]) {
        // Find how many words match between this cycle and previous cycle
        var stableCount = 0
        for (a, b) in zip(words, prevCycleWords) {
            if normalizedMatch(a, b) { stableCount += 1 } else { break }
        }

        prevCycleWords = words

        // Verify committed prefix still matches the current transcript
        guard committedPrefixMatches(words) else { return }

        // Inject any stable words beyond what we've already committed
        if stableCount > committedWords.count {
            let newWords = Array(words[committedWords.count..<stableCount])
            let space = committedWords.isEmpty ? "" : " "
            let text = space + newWords.joined(separator: " ")
            onUtterance?(text)
            committedWords.append(contentsOf: newWords)
        }
    }

    /// On stop, inject any remaining words beyond what was committed.
    private func injectFinal(_ words: [String]) {
        guard committedPrefixMatches(words) else { return }

        if words.count > committedWords.count {
            let newWords = Array(words[committedWords.count...])
            let space = committedWords.isEmpty ? "" : " "
            let text = space + newWords.joined(separator: " ")
            onUtterance?(text)
            committedWords.append(contentsOf: newWords)
        }
    }

    /// Check that our committed words still match the start of the transcript.
    /// If the model has rewritten text we already injected, we can't fix it,
    /// so we stop injecting to avoid duplicates.
    private func committedPrefixMatches(_ words: [String]) -> Bool {
        guard !committedWords.isEmpty else { return true }
        guard words.count >= committedWords.count else { return false }
        for (i, committed) in committedWords.enumerated() {
            if !normalizedMatch(committed, words[i]) {
                return false
            }
        }
        return true
    }

    /// Compare two words ignoring case and trailing punctuation,
    /// so "working" matches "working." and "Mom" matches "mom".
    private func normalizedMatch(_ a: String, _ b: String) -> Bool {
        a.lowercased().trimmingCharacters(in: .punctuationCharacters)
            == b.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Resample to 16kHz for ASR
        let targetRate: Double = 16000
        let sourceSampleRate = hwFormat.sampleRate
        let audioBuffer = self.audioBuffer

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: monoFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

            // Linear interpolation resample to 16kHz
            let ratio = sourceSampleRate / targetRate
            let outputCount = Int(Double(frameCount) / ratio)
            var resampled = [Float](repeating: 0, count: outputCount)
            for i in 0..<outputCount {
                let srcIdx = Double(i) * ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx < frameCount - 1 {
                    resampled[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
                } else if idx < frameCount {
                    resampled[i] = samples[idx]
                }
            }
            audioBuffer.append(resampled)
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

    private func unloadModels() {
        asrManager = nil
        asrModels = nil
    }
}

// MARK: - Thread-safe audio buffer

private final class LockedAudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func getSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}
