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

/// Manages real-time dictation using FluidAudio's StreamingEouAsrManager —
/// a cache-aware streaming ASR engine (parakeet-realtime-eou-120m) designed
/// for low-latency word-by-word transcription. Audio is appended as it
/// arrives and decoded in 320ms chunks; partial transcripts are injected
/// incrementally via the manager's partial-transcript callback.
///
/// Note: this is a different engine and model from the meeting-recording
/// pipeline (which still uses Parakeet TDT 0.6B v2/v3 for accuracy).
@MainActor
public final class DictationManager: ObservableObject {

    @Published public private(set) var state: DictationState = .idle
    @Published public var partialTranscript: String = ""

    private var streamingMgr: StreamingEouAsrManager?
    private var micEngine: AVAudioEngine?
    private var unloadTask: Task<Void, Never>?
    private var micBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var micForwardTask: Task<Void, Never>?
    private var bufferCount = 0

    /// Called when new transcribed text is ready for injection.
    public var onUtterance: ((String) -> Void)?

    /// Custom vocabulary terms for boosting. Set before calling start().
    /// Currently unused by the streaming-EOU engine — kept for API compatibility
    /// with the settings UI; will become functional if/when the engine exposes
    /// a vocabulary-boosting hook.
    public var customVocabulary: [String] = []

    /// Custom formatting commands for ITN. Set before calling start().
    public var formattingCommands: [FormattingCommand] = []

    /// Which Parakeet model version the rest of the app uses for the meeting
    /// pipeline. Dictation does not use this — the streaming-EOU engine has
    /// its own dedicated model — but the field is retained because callers
    /// (AppModel) still propagate it on settings changes.
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

        // Reuse the streaming engine across sessions — models stay loaded
        // for `modelKeepAliveSeconds` so the second-and-subsequent dictation
        // in a working session start instantly. First-ever start downloads
        // the model from HuggingFace (~120 MB) and may take a few seconds.
        let mgr: StreamingEouAsrManager
        if let existing = streamingMgr {
            mgr = existing
            await mgr.reset()
        } else {
            mgr = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
            try await mgr.loadModels(to: nil, configuration: nil, progressHandler: nil)
            streamingMgr = mgr
        }

        // Apply custom formatting commands
        TextNormalizer.shared.clearRules()
        for cmd in formattingCommands {
            TextNormalizer.shared.addRule(spoken: cmd.spoken, written: cmd.written)
        }

        injectedText = ""
        partialTranscript = ""

        // Hook up the partial-transcript callback BEFORE starting mic capture so
        // we don't miss the first chunk's output. The callback fires every time
        // new tokens are decoded (~every 320ms) with the cumulative transcript.
        await mgr.setPartialTranscriptCallback { [weak self] partial in
            Task { @MainActor [weak self] in
                self?.handlePartial(partial)
            }
        }

        try startMicCapture(mgr: mgr)
        state = .listening
    }

    public func stop() async {
        guard state == .listening else { return }

        // Drain all buffered mic audio into the ASR before finishing, otherwise
        // the last few hundred ms (whatever is still sitting in the AsyncStream
        // buffer) get dropped and the tail of the dictation never makes it to
        // the encoder.
        await drainAndStopMicCapture()

        // Flush remaining audio and inject any trailing text. We keep the
        // manager itself (and its loaded models) so the next session can
        // reuse it via reset() without paying the load cost again. The
        // keep-alive timer below tears it down after a few idle minutes.
        if let mgr = streamingMgr {
            let finalText = (try? await mgr.finish()) ?? ""
            injectDelta(to: finalText)
        }

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

    // MARK: - Partial transcript handling

    /// Called every ~320ms from the streaming engine with the cumulative
    /// decoded transcript. Tokens are append-only inside the engine, so this
    /// string only ever grows — `injectDelta` relies on that.
    private func handlePartial(_ partial: String) {
        partialTranscript = TextNormalizer.shared.normalizeSentence(partial)
        injectDelta(to: partial)
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

    private func startMicCapture(mgr: StreamingEouAsrManager) throws {
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
        // can feed them to the ASR in arrival order. Spawning an unstructured
        // Task per callback doesn't preserve ordering, and the tap-provided
        // buffer is only valid for the duration of the callback (AVAudioEngine
        // reuses the underlying memory), so we deep-copy synchronously before
        // yielding.
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        micBufferContinuation = continuation
        bufferCount = 0

        micForwardTask = Task { [weak self, weak mgr] in
            for await buffer in stream {
                guard let mgr, !Task.isCancelled else { break }
                // Append to the engine's internal buffer, then drive any
                // complete chunks through the decoder. processBufferedAudio
                // is a no-op until enough samples for a full 320ms chunk
                // have accumulated, so this is cheap per-buffer.
                do {
                    try await mgr.appendAudio(buffer)
                    try await mgr.processBufferedAudio()
                } catch {
                    NSLog("Heard: Dictation chunk processing failed: %@", error.localizedDescription)
                }
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
        if let mgr = streamingMgr {
            Task { await mgr.cleanup() }
        }
        streamingMgr = nil
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
