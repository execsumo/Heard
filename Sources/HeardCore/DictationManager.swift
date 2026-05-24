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
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var micForwardTask: Task<Void, Never>?
    private var bufferCount = 0

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

    /// CoreAudio UID of the input device to capture from. nil = follow the
    /// system default input device.
    public var inputDeviceUID: String?

    /// Full text injected so far in the current session (confirmed deltas only).
    private var injectedText: String = ""

    public init() {}

    // MARK: - Public API

    public func start() async throws {
        guard state == .idle else { throw DictationError.notIdle(current: state) }

        // Surface mic-permission denial up front rather than letting the user
        // stare at a silently-failing HUD — without mic access, AVAudioEngine
        // starts but no tap callbacks fire. Accessibility access is checked
        // mid-session by AppModel.startAXPolling() rather than here, because
        // AXIsProcessTrusted() can lag behind a freshly-granted permission
        // (especially with ad-hoc signed builds) and we'd rather attempt
        // dictation than reject on a stale check.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            throw DictationError.microphoneDenied
        }

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
        //
        // The library's `.streaming` preset uses chunkSeconds=11 and
        // minContextForConfirmation=10, which means the user sees nothing for
        // ~10s and then text arrives in 11s batches — feels broken for live
        // dictation. Lower both so confirmed text lands every few seconds.
        // Accuracy trade-off is acceptable here: dictation users want
        // responsiveness, and they can edit afterwards.
        let tdtConfig = TdtConfig(blankId: modelVersion.blankId)
        let dictationConfig = SlidingWindowAsrConfig(
            chunkSeconds: 3.0,
            hypothesisChunkSeconds: 0.5,
            leftContextSeconds: 8.0,
            rightContextSeconds: 2.0,
            minContextForConfirmation: 2.0,
            confirmationThreshold: 0.75,
            tdtConfig: tdtConfig
        )
        let mgr = SlidingWindowAsrManager(config: dictationConfig)
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

        // Drain all buffered mic audio into the ASR before finishing, otherwise
        // the last few hundred ms (whatever is still sitting in the AsyncStream
        // buffer) get dropped and finish() produces no text for that tail.
        await drainAndStopMicCapture()
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
        // Apply the user-selected input device BEFORE querying the input
        // format — changing the device changes sample rate / channel count.
        let applied = AudioInputDevices.apply(uid: inputDeviceUID, to: engine)
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        NSLog(
            "Heard: Dictation mic format — sampleRate=%.0f channels=%u device=%@",
            hwFormat.sampleRate,
            hwFormat.channelCount,
            applied ? (inputDeviceUID ?? "default") : "default"
        )

        // Forward tap buffers through an AsyncStream so a single consumer task
        // can feed them to streamAudio() in arrival order. Spawning an
        // unstructured Task per callback doesn't preserve ordering, and the
        // tap-provided buffer is only valid for the duration of the callback
        // (AVAudioEngine reuses the underlying memory), so we deep-copy
        // synchronously before yielding.
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        micBufferContinuation = continuation
        bufferCount = 0

        micForwardTask = Task { [weak self, weak mgr] in
            for await buffer in stream {
                guard let mgr, !Task.isCancelled else { break }
                await mgr.streamAudio(buffer)
                if let self {
                    self.tickBufferCount()
                }
            }
        }

        // continuation is a struct; capture by value. Once the teardown path
        // calls finish() on it, subsequent yields are no-ops, so we don't need
        // to null it out from the tap.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            guard let copy = buffer.heardDeepCopy() else { return }
            continuation.yield(copy)
        }

        engine.prepare()
        try engine.start()
        micEngine = engine
    }

    /// Logs progress on the first buffer and every ~5s thereafter (at 48 kHz × 4096
    /// frames ≈ 11.7 Hz) so silent-mic regressions surface in logs.
    private func tickBufferCount() {
        bufferCount += 1
        if bufferCount == 1 {
            NSLog("Heard: Dictation received first mic buffer")
        } else if bufferCount % 60 == 0 {
            NSLog("Heard: Dictation buffers streamed=%d", bufferCount)
        }
    }

    /// Graceful shutdown that lets buffered mic audio finish reaching the ASR
    /// before returning. Stops the engine, closes the stream, then awaits the
    /// forwarder so its `for await` loop drains every queued buffer — without
    /// this drain, the AsyncStream's buffer (~5s at hardware rate) is lost on
    /// stop and the tail of the dictation never gets transcribed.
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
