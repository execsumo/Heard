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

    public var errorDescription: String? {
        switch self {
        case .notIdle(let s):
            return "Cannot start dictation: already \(s.rawValue). Please wait for the current operation to finish."
        case .microphoneDenied:
            return "Microphone access is required for dictation. Grant it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Manages burst-mode dictation using FluidAudio's batch `AsrManager` (Parakeet
/// TDT 0.6B). The user presses a hotkey, speaks, presses again; on stop the
/// full session audio is transcribed in one pass with optional vocabulary
/// rescoring, and the result is injected. The TDT model is loaded eagerly on
/// `start()` so the post-stop transcription begins immediately.
///
/// No live/streaming text injection — earlier attempts with a true-streaming
/// engine produced worse accuracy than batch (decoder loops, hallucinated
/// repetitions). Batch on stop is faster than the user can read for typical
/// dictation lengths.
@MainActor
public final class DictationManager: ObservableObject {

    @Published public private(set) var state: DictationState = .idle
    /// Unused by the batch engine — kept @Published so existing UI bindings
    /// continue to compile. Always empty.
    @Published public var partialTranscript: String = ""

    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var loadedModelVersion: TranscriptionModel?
    private let audioConverter = AudioConverter()
    private var audioBuffer: [Float] = []

    private var micEngine: AVAudioEngine?
    private var unloadTask: Task<Void, Never>?
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var micForwardTask: Task<Void, Never>?
    private var bufferCount = 0

    /// Called when transcription completes for a session with the final text.
    public var onUtterance: ((String) -> Void)?

    /// Custom vocabulary terms for boosting. Applied as CTC rescoring after
    /// the TDT transcription completes. Requires the CTC 110M model to be
    /// downloaded (Models tab) — silently skipped otherwise.
    public var customVocabulary: [String] = []

    /// Custom formatting commands for ITN.
    public var formattingCommands: [FormattingCommand] = []

    /// Which Parakeet model version to use for transcription. Changing
    /// mid-session reloads models on the next start.
    public var modelVersion: TranscriptionModel = .v2

    /// How long to keep the model loaded after dictation stops (seconds).
    public var modelKeepAliveSeconds: TimeInterval = 120

    /// CoreAudio UID of the input device to capture from. nil = follow the
    /// system default input device.
    public var inputDeviceUID: String?

    public init() {}

    // MARK: - Public API

    public func start() async throws {
        guard state == .idle else { throw DictationError.notIdle(current: state) }

        // Surface mic-permission denial up front rather than letting the user
        // stare at a silently-failing HUD — without mic access, AVAudioEngine
        // starts but no tap callbacks fire.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            throw DictationError.microphoneDenied
        }

        unloadTask?.cancel()
        unloadTask = nil

        state = .loading

        // Load (or reuse) the TDT model eagerly so the post-stop transcription
        // can start immediately instead of paying a cold-start cost while the
        // user waits for text to appear.
        try await ensureAsrManagerLoaded()

        // Apply custom formatting commands
        TextNormalizer.shared.clearRules()
        for cmd in formattingCommands {
            TextNormalizer.shared.addRule(spoken: cmd.spoken, written: cmd.written)
        }

        audioBuffer.removeAll(keepingCapacity: true)
        partialTranscript = ""

        try startMicCapture()
        state = .listening
    }

    public func stop() async {
        guard state == .listening else { return }

        // Drain mic — see drainAndStopMicCapture for why awaiting matters.
        await drainAndStopMicCapture()

        state = .transcribing
        defer {
            state = .idle
            scheduleModelUnload()
        }

        // Snapshot and clear the buffer so a fast next-start doesn't see
        // stale audio if the user re-triggers before we finish processing.
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)

        // Parakeet requires at least 1s of audio (16k samples at 16kHz).
        let minSamples = 16_000
        guard samples.count >= minSamples else {
            NSLog("Heard: Dictation audio too short to transcribe (%d samples)", samples.count)
            return
        }

        guard let mgr = asrManager else { return }

        do {
            var decoderState = TdtDecoderState.make()
            let result = try await mgr.transcribe(
                samples, decoderState: &decoderState, language: .english
            )
            let boosted = await rescoreWithVocabulary(result: result, samples: samples)
            let normalized = TextNormalizer.shared.normalize(result: boosted).text
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            onUtterance?(trimmed)
        } catch {
            NSLog("Heard: Dictation transcription failed: %@", error.localizedDescription)
        }
    }

    public func toggle() async throws {
        if state == .listening {
            await stop()
        } else if state == .idle {
            try await start()
        }
    }

    // MARK: - Model loading

    /// Kick off a background load of the TDT model so the first hotkey press
    /// doesn't pay a multi-second cold-start delay before the mic starts.
    /// Idempotent — repeated calls while already loaded or loading are no-ops.
    public func preloadModelsInBackground() {
        guard asrManager == nil || loadedModelVersion != modelVersion else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureAsrManagerLoaded()
                NSLog("Heard: Dictation TDT model preloaded")
            } catch {
                NSLog("Heard: Dictation TDT preload failed: %@", error.localizedDescription)
            }
        }
    }

    private func ensureAsrManagerLoaded() async throws {
        if asrManager != nil, loadedModelVersion == modelVersion { return }

        // Version changed (or first load) — drop the old manager and reload.
        asrManager = nil
        asrModels = nil
        loadedModelVersion = nil

        let fluidVersion: AsrModelVersion = modelVersion == .v2 ? .v2 : .v3
        let models = try await AsrModels.loadFromCache(version: fluidVersion)
        let asrConfig = ASRConfig(
            tdtConfig: TdtConfig(blankId: modelVersion.blankId),
            encoderHiddenSize: fluidVersion.encoderHiddenSize
        )
        let manager = AsrManager(config: asrConfig)
        try await manager.loadModels(models)

        asrModels = models
        asrManager = manager
        loadedModelVersion = modelVersion
    }

    // MARK: - Vocabulary rescoring

    /// Mirrors the pipeline path in `Services.swift`: run CTC keyword spotting
    /// over the same audio, then ask `VocabularyRescorer` to rewrite
    /// low-confidence words against the user's vocabulary. Skipped silently
    /// when no terms are set or the CTC 110M model isn't downloaded.
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
                    ctcTokenIds: ids.isEmpty ? nil : ids
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

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let applied = AudioInputDevices.apply(uid: inputDeviceUID, to: engine)
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        NSLog(
            "Heard: Dictation mic format — sampleRate=%.0f channels=%u device=%@",
            hwFormat.sampleRate,
            hwFormat.channelCount,
            applied ? (inputDeviceUID ?? "default") : "default"
        )

        // Buffers from the tap callback are only valid for the duration of the
        // callback (AVAudioEngine reuses the underlying memory), so we
        // deep-copy synchronously before yielding to a consumer task.
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        micBufferContinuation = continuation
        bufferCount = 0

        let converter = audioConverter
        micForwardTask = Task { [weak self] in
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                do {
                    let samples = try converter.resampleBuffer(buffer)
                    if let self {
                        self.appendSamples(samples)
                    }
                } catch {
                    NSLog("Heard: Dictation resample failed: %@", error.localizedDescription)
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            guard let copy = buffer.heardDeepCopy() else { return }
            continuation.yield(copy)
        }

        engine.prepare()
        try engine.start()
        micEngine = engine
    }

    private func appendSamples(_ samples: [Float]) {
        audioBuffer.append(contentsOf: samples)
        bufferCount += 1
        if bufferCount == 1 {
            NSLog("Heard: Dictation received first mic buffer")
        } else if bufferCount % 60 == 0 {
            NSLog("Heard: Dictation buffers streamed=%d totalSamples=%d", bufferCount, audioBuffer.count)
        }
    }

    /// Graceful shutdown that lets buffered mic audio finish reaching the
    /// in-memory sample buffer before returning. Without this drain, anything
    /// still in the AsyncStream when stop is pressed gets dropped and the
    /// tail of the dictation is never transcribed.
    private func drainAndStopMicCapture() async {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micBufferContinuation?.finish()
        micBufferContinuation = nil
        await micForwardTask?.value
        micForwardTask = nil
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
        asrManager = nil
        asrModels = nil
        loadedModelVersion = nil
        NSLog("Heard: Dictation models unloaded")
    }
}

// MARK: - Buffer copy

private extension AVAudioPCMBuffer {
    /// Allocates a standalone copy of the buffer. The buffer handed to an
    /// AVAudioEngine tap callback only owns its sample memory for the duration
    /// of the callback; copying lets us hand it off to a consumer task safely.
    func heardDeepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)

        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
            return copy
        }
        if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
            return copy
        }
        if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size)
            }
            return copy
        }
        return nil
    }
}
