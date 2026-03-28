import AVFoundation
import FluidAudio
import Foundation

/// Simple file logger for dictation debugging.
private let dictationLogFile: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("heard_dictation.log")
    try? "".write(to: url, atomically: true, encoding: .utf8)
    return url
}()

func dictLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    NSLog("Heard: \(msg)")
    if let data = line.data(using: .utf8),
       let fh = try? FileHandle(forWritingTo: dictationLogFile) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    }
}

public enum DictationState: String {
    case idle
    case loading
    case listening
}

/// Manages real-time dictation using FluidAudio's batch AsrManager with a polling loop.
/// This approach (used by FluidVoice) is proven reliable — it re-transcribes accumulated
/// audio every 0.6s and diffs the output for new words.
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

    /// How long to keep the model loaded after dictation stops (seconds).
    private let modelKeepAliveSeconds: TimeInterval = 120

    /// How often to re-transcribe accumulated audio (seconds).
    private let chunkInterval: TimeInterval = 0.6

    /// Minimum samples before attempting transcription (1s at 16kHz).
    private let minSamples: Int = 16000

    /// Previous transcription result for diffing.
    private var lastTranscript: String = ""

    public init() {}

    // MARK: - Public API

    public func start() async throws {
        guard state == .idle else { return }
        dictLog("start() called")

        unloadTask?.cancel()
        unloadTask = nil

        state = .loading

        // Load batch ASR models if needed
        if asrModels == nil {
            dictLog("Loading ASR models...")
            let models = try await AsrModels.loadFromCache(version: .v2)
            asrModels = models
            dictLog("ASR models loaded")
        }

        if asrManager == nil {
            let manager = AsrManager(config: ASRConfig.default)
            try await manager.initialize(models: asrModels!)
            asrManager = manager
            dictLog("AsrManager initialized")
        }

        // Reset state
        audioBuffer.clear()
        lastTranscript = ""
        partialTranscript = ""

        // Start mic capture
        try startMicCapture()
        state = .listening

        // Start streaming transcription loop
        startStreamingLoop()
        dictLog("Dictation started")
    }

    public func stop() async {
        guard state == .listening else { return }
        dictLog("stop() called")

        stopMicCapture()
        streamingTask?.cancel()
        streamingTask = nil

        // Do one final transcription of all accumulated audio
        await transcribeAccumulated(isFinal: true)

        audioBuffer.clear()
        lastTranscript = ""
        partialTranscript = ""
        state = .idle

        // Schedule model unload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.modelKeepAliveSeconds ?? 120))
            guard let self, !Task.isCancelled else { return }
            self.unloadModels()
        }
        dictLog("Dictation stopped")
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

            if !trimmed.isEmpty {
                dictLog("Transcript (\(isFinal ? "final" : "partial")): '\(trimmed)'")

                if isFinal {
                    // On final, inject any new text beyond what was already injected
                    let newText = diffTranscript(old: lastTranscript, new: trimmed)
                    if !newText.isEmpty {
                        onUtterance?(newText)
                    }
                } else {
                    // Show partial in UI, inject new words
                    let newText = diffTranscript(old: lastTranscript, new: trimmed)
                    partialTranscript = trimmed
                    if !newText.isEmpty {
                        dictLog("New text to inject: '\(newText)'")
                        onUtterance?(newText)
                        lastTranscript = trimmed
                    }
                }
            }
        } catch {
            dictLog("Transcription error: \(error)")
        }
    }

    /// Diff two transcripts to find new text appended at the end.
    private func diffTranscript(old: String, new: String) -> String {
        if old.isEmpty { return new }
        // If new starts with old, return the suffix
        if new.hasPrefix(old) {
            let suffix = String(new.dropFirst(old.count))
            return suffix.trimmingCharacters(in: .whitespaces)
        }
        // If old is a prefix match up to word boundary, find divergence
        let oldWords = old.split(separator: " ")
        let newWords = new.split(separator: " ")
        var commonCount = 0
        for (a, b) in zip(oldWords, newWords) {
            if a == b { commonCount += 1 } else { break }
        }
        if commonCount > 0 && newWords.count > commonCount {
            return newWords[commonCount...].joined(separator: " ")
        }
        // Fallback: return entire new transcript
        return new
    }

    // MARK: - Mic Capture

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        dictLog("Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

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
        dictLog("Engine started, mic tap installed")
    }

    private func stopMicCapture() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }

    private func unloadModels() {
        asrManager = nil
        asrModels = nil
        dictLog("Models unloaded")
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
