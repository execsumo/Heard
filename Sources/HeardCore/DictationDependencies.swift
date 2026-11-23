import AVFoundation
import FluidAudio
import Foundation

/// Production speech engine: FluidAudio batch Parakeet TDT, loaded from the local cache.
@MainActor
final class FluidDictationEngine: DictationEngine {
    private let manager: AsrManager
    /// Held for the engine's lifetime, as before this split.
    private let models: AsrModels

    init(manager: AsrManager, models: AsrModels) {
        self.manager = manager
        self.models = models
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        var decoderState = TdtDecoderState.make()
        return try await manager.transcribe(samples, decoderState: &decoderState, language: .english)
    }
}

/// Production provider: runs the injected `prepare` (download or readiness wait), then loads the
/// model from FluidAudio's cache. Downloads live behind `prepare`, so this file never touches ModelDownloadManager.
@MainActor
final class FluidDictationEngineProvider: DictationEngineProvider {
    private let prepare: @MainActor (TranscriptionModel) async throws -> Void

    init(prepare: @escaping @MainActor (TranscriptionModel) async throws -> Void) {
        self.prepare = prepare
    }

    func loadEngine(for selection: TranscriptionModel) async throws -> DictationEngine {
        do {
            try await prepare(selection)
        } catch is CancellationError {
            throw DictationError.cancelled
        }
        let engine = selection.dictationEngine
        // Still guard the cache here: a successful prepare must leave English (Optimized) cache-complete.
        if selection.usesUnifiedEngine, !DictationManager.englishOptimizedCached() {
            throw DictationError.englishOptimizedNotDownloaded
        }
        let fluidVersion: AsrModelVersion = engine == .v3 ? .v3 : .v2
        let models = try await AsrModels.loadFromCache(version: fluidVersion)
        let asrConfig = ASRConfig(
            tdtConfig: TdtConfig(blankId: engine.blankId),
            encoderHiddenSize: fluidVersion.encoderHiddenSize
        )
        let manager = AsrManager(config: asrConfig)
        try await manager.loadModels(models)
        return FluidDictationEngine(manager: manager, models: models)
    }
}

/// Production microphone: AVAudioEngine input tap, resampled to 16 kHz mono by FluidAudio's converter.
@MainActor
final class AVDictationMicSource: DictationMicSource {
    private let audioConverter = AudioConverter()
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var forwardTask: Task<Void, Never>?

    var isMicrophoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    func start(deviceUID: String?, deliver: @escaping @MainActor ([Float]) -> Void) throws {
        cancel()
        let engine = AVAudioEngine()
        let applied = AudioInputDevices.apply(uid: deviceUID, to: engine)
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        NSLog(
            "Heard: Dictation mic format — sampleRate=%.0f channels=%u device=%@",
            hwFormat.sampleRate,
            hwFormat.channelCount,
            applied ? (deviceUID ?? "default") : "default"
        )
        DebugFileLog.log("startMicCapture mic format — sr=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount) deviceApplied=\(applied)")

        // Tap buffers are only valid during the callback, so they are deep-copied before the consumer task.
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let converter = audioConverter
        forwardTask = Task {
            for await buffer in stream {
                guard !Task.isCancelled else { break }
                do {
                    let samples = try converter.resampleBuffer(buffer)
                    deliver(samples)
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
        do {
            try engine.start()
            DebugFileLog.log("startMicCapture engine.start ok — running=\(engine.isRunning)")
        } catch {
            // Undo everything acquired above so a failed start leaves nothing running.
            DebugFileLog.log("startMicCapture engine.start threw: \(error)")
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            forwardTask?.cancel()
            forwardTask = nil
            throw error
        }
        self.engine = engine
        self.continuation = continuation
    }

    func stop() async {
        let task = forwardTask
        forwardTask = nil
        detachEngine()
        // Deliver audio already in the stream before the caller snapshots the buffer.
        await task?.value
    }

    func cancel() {
        forwardTask?.cancel()
        forwardTask = nil
        detachEngine()
    }

    private func detachEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}

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
