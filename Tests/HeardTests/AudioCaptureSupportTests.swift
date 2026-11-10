import AVFoundation
import HeardCore

func runAudioCaptureSupportTests() async {
    test("App audio copies interleaved stereo") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var samples: [Float] = [1, 2, 3, 4]
        try samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            let copied = AudioCaptureSupport.copyInput(&list, format: format)
            try expectEqual(copied?.frameLength, 2)
            try expectEqual(copied?.floatChannelData?[0][1], 3)
            try expectEqual(copied?.floatChannelData?[1][1], 4)
        }
    }
    test("App audio copies planar stereo without dropping right channel") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        source.frameLength = 2
        source.floatChannelData![0][0] = 0
        source.floatChannelData![0][1] = 0
        source.floatChannelData![1][0] = 0.5
        source.floatChannelData![1][1] = 0.75
        let copied = AudioCaptureSupport.copyInput(source.audioBufferList, format: format)
        try expectEqual(copied?.frameLength, 2)
        try expectEqual(copied?.floatChannelData?[1][0], 0.5)
        try expectEqual(copied?.floatChannelData?[1][1], 0.75)
    }
    test("App audio rejects an unexpected physical-device channel layout") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 2)!
        mono.frameLength = 2
        try expect(AudioCaptureSupport.copyInput(mono.audioBufferList, format: format) == nil)
    }
    test("App audio rejects interleaved destination formats") {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil))
        try expect(AudioCaptureSupport.copyInput(&list, format: format) == nil)
    }
    test("App audio rejects empty input") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil))
        try expect(AudioCaptureSupport.copyInput(&list, format: format) == nil)
    }
    test("Short WAV header is extended to the PCM on disk and a finished header is left alone") {
        let broken = try wavFixture(frames: 4, declaredFrames: 0, sample: 0.25)
        let intact = try wavFixture(frames: 2, declaredFrames: 2, sample: 0.5)
        defer {
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.removeItem(at: intact)
        }
        let repair = try unwrap(try WAVHeaderFinalizer.finalize(at: broken))
        try expectEqual(repair.previousDataSize, 0)
        try expectEqual(repair.dataSize, 32) // 4 stereo float frames
        let file = try AVAudioFile(forReading: broken)
        try expectEqual(file.length, AVAudioFramePosition(4))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4)!
        try file.read(into: buffer)
        try expectClose(Double(buffer.floatChannelData![0][0]), 0.25)
        try expectClose(Double(buffer.floatChannelData![1][3]), 0.25)

        let before = try Data(contentsOf: intact)
        try expect(try WAVHeaderFinalizer.finalize(at: intact) == nil)
        try expectEqual(try Data(contentsOf: intact), before)
    }
    test("AVAudioFile-shaped preamble with a zero data chunk exposes the payload") {
        let url = try preambleFixture(frames: 2, sample: 0.75)
        defer { try? FileManager.default.removeItem(at: url) }
        let repair = try unwrap(try WAVHeaderFinalizer.finalize(at: url))
        try expectEqual(repair.previousDataSize, 0)
        try expectEqual(repair.dataSize, 16)
        let file = try AVAudioFile(forReading: url)
        try expectEqual(file.length, AVAudioFramePosition(2))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2)!
        try file.read(into: buffer)
        try expectClose(Double(buffer.floatChannelData![0][1]), 0.75)
    }
    test("Reading a short header uses a clone and does not modify the recording") {
        let original = try wavFixture(frames: 3, declaredFrames: 0, sample: -0.5)
        defer { try? FileManager.default.removeItem(at: original) }
        let before = try Data(contentsOf: original)
        let reading = try WAVHeaderFinalizer.readingURL(for: original)
        defer { reading.cleanup() }
        try expect(reading.ownsTemporary)
        try expect(reading.url != original)
        let file = try AVAudioFile(forReading: reading.url)
        try expectEqual(file.length, AVAudioFramePosition(3))
        try expectEqual(try Data(contentsOf: original), before)
    }
    test("Clone and partial-write failures preserve the source and are surfaced") {
        let original = try wavFixture(frames: 4, declaredFrames: 0, sample: 0.25)
        defer { try? FileManager.default.removeItem(at: original) }
        let before = try Data(contentsOf: original)
        var operations = WAVHeaderFinalizer.Operations.standard
        var temporary: URL?
        operations.clone = { source, destination in
            temporary = destination
            try FileManager.default.copyItem(at: source, to: destination)
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected clone failure"])
        }
        do {
            _ = try WAVHeaderFinalizer.readingURL(for: original, operations: operations)
            throw TestFailure("clone failure was ignored")
        } catch let error as WAVHeaderFinalizer.RecoveryError {
            try expect(error.localizedDescription.contains("clone failure"))
        }
        try expect(!FileManager.default.fileExists(atPath: try unwrap(temporary).path))
        operations = .standard
        let clone = operations.clone
        operations.clone = { source, destination in
            temporary = destination
            try clone(source, destination)
        }
        let write = operations.writeSize
        operations.writeSize = { handle, offset, bytes in
            try write(handle, offset, bytes)
            if offset == 4 {
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "injected partial write"])
            }
        }
        do {
            _ = try WAVHeaderFinalizer.finalize(at: original, operations: operations)
            throw TestFailure("partial write failure was ignored")
        } catch let error as WAVHeaderFinalizer.RecoveryError {
            try expect(error.localizedDescription.contains("partial write"))
        }
        try expect(!FileManager.default.fileExists(atPath: try unwrap(temporary).path))
        try expectEqual(try Data(contentsOf: original), before)
        let reading = try WAVHeaderFinalizer.readingURL(for: original)
        defer { reading.cleanup() }
        try expectEqual(try AVAudioFile(forReading: reading.url).length, 4)
    }
    test("Previously interrupted size updates recover either field order") {
        for firstField in [4, 40] {
            let url = try wavFixture(frames: 4, declaredFrames: 0, sample: 0.25)
            defer { try? FileManager.default.removeItem(at: url) }
            let handle = try FileHandle(forUpdating: url)
            try handle.seek(toOffset: UInt64(firstField))
            var value = UInt32(firstField == 4 ? 68 : 32).littleEndian
            try handle.write(contentsOf: Data(bytes: &value, count: 4))
            try handle.close()
            let before = try Data(contentsOf: url)
            let reading = try WAVHeaderFinalizer.readingURL(for: url)
            defer { reading.cleanup() }
            try expect(reading.ownsTemporary)
            try expectEqual(try AVAudioFile(forReading: reading.url).length, 4)
            try expectEqual(try Data(contentsOf: url), before)
        }
    }
    test("Complete RIFF with trailing chunks is not rewritten") {
        let url = try wavFixture(frames: 2, declaredFrames: 2, sample: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([76, 73, 83, 84, 4, 0, 0, 0, 1, 2, 3, 4]))
        try handle.seek(toOffset: 4)
        var size = UInt32(64).littleEndian
        try handle.write(contentsOf: Data(bytes: &size, count: 4))
        try handle.close()
        let before = try Data(contentsOf: url)
        let reading = try WAVHeaderFinalizer.readingURL(for: url)
        try expect(!reading.ownsTemporary)
        try expect(try WAVHeaderFinalizer.finalize(at: url) == nil)
        try expectEqual(try Data(contentsOf: url), before)
    }
    test("Oversized short RIFF fails without altering the sparse original") {
        let url = try wavFixture(frames: 1, declaredFrames: 0, sample: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 44 + UInt64(UInt32.max) + 1)
        try handle.close()
        let reader = try FileHandle(forReadingFrom: url)
        let before = try reader.read(upToCount: 44)
        try reader.close()
        do {
            _ = try WAVHeaderFinalizer.readingURL(for: url)
            throw TestFailure("oversized RIFF was accepted")
        } catch WAVHeaderFinalizer.RecoveryError.unsupportedSize { }
        do {
            _ = try WAVHeaderFinalizer.finalize(at: url)
            throw TestFailure("oversized RIFF was finalized")
        } catch WAVHeaderFinalizer.RecoveryError.unsupportedSize { }
        let check = try FileHandle(forReadingFrom: url)
        try expectEqual(try check.read(upToCount: 44), before)
        try expectEqual(try check.seekToEnd(), 44 + UInt64(UInt32.max) + 1)
        try check.close()
    }
    await testAsync("Preprocessing surfaces oversized WAV recovery failure") {
        let url = try wavFixture(frames: 1, declaredFrames: 0, sample: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 44 + UInt64(UInt32.max) + 1)
        try handle.close()
        do {
            _ = try await AudioPreprocessor.preprocess(wavURL: url)
            throw TestFailure("preprocessing accepted an unrecoverable RIFF")
        } catch WAVHeaderFinalizer.RecoveryError.unsupportedSize { }
    }
    test("Clip extraction reads the recovered payload") {
        let source = try wavFixture(frames: 4800, declaredFrames: 0, sample: 0.25)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("heard-clip-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let before = try Data(contentsOf: source)
        let clip = AudioClipExtractor.extractClip(from: source, startTime: 0, endTime: 0.1, outputURL: output)
        try expect(clip != nil)
        try expectEqual(try AVAudioFile(forReading: output).length, 4800)
        try expectEqual(try Data(contentsOf: source), before)
    }
    test("RIFF capture limits split early and cap writes even when delayed") {
        let seconds = WAVCaptureLimit.splitAfter(sampleRate: 48_000, bytesPerFrame: 8)
        try expect(seconds > 3 * 3600 && seconds < 3 * 3600 + 6 * 60)
        try expect(WAVCaptureLimit.splitAfter(sampleRate: 192_000, bytesPerFrame: 8) < 3600)
        var limit = WAVCaptureLimit(bytesPerFrame: 8, existingFrames: 2, maxPayloadBytes: 40)
        let first = limit.reserve(2)
        try expectEqual(first.frames, 2)
        try expectEqual(first.dropped, 0)
        try expect(!first.split)
        let second = limit.reserve(4)
        try expectEqual(second.frames, 1)
        try expectEqual(second.dropped, 3)
        try expect(second.split)
        let afterLimit = limit.reserve(1)
        try expectEqual(afterLimit.frames, 0)
        try expectEqual(afterLimit.dropped, 1)
    }
    test("Health snapshots do not retain a failed rebuild's writer context") {
        final class Writer {}
        final class Context { let writer = Writer() }
        var snapshot = AppAudioHealthSnapshot()
        weak var weakContext: Context?
        weak var weakWriter: Writer?
        do {
            let context = Context()
            weakContext = context
            weakWriter = context.writer
            let observed = snapshot.observe(context, nonZero: 3, cycles: 2)
            try expect(observed.receivedAudio && observed.callbacksFiring)
        }
        try expect(weakContext == nil && weakWriter == nil)
        snapshot.reset()
        try expect(snapshot.identity == nil)
    }
    test("App-track AVAudioFile close plus header finalize keeps the samples") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heard-app-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let frames: AVAudioFrameCount = 2400
        try autoreleasepool {
            let writing = try AVAudioFile(forWriting: url, settings: settings)
            try expectEqual(writing.fileFormat.streamDescription.pointee.mBytesPerFrame, 8)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                buffer.floatChannelData![0][index] = 0.125
                buffer.floatChannelData![1][index] = -0.25
            }
            try writing.write(from: buffer)
            try expectEqual(writing.length, AVAudioFramePosition(frames))
        }
        _ = try WAVHeaderFinalizer.finalize(at: url)
        let reading = try AVAudioFile(forReading: url)
        try expectEqual(reading.length, AVAudioFramePosition(frames))
        let buffer = AVAudioPCMBuffer(pcmFormat: reading.processingFormat, frameCapacity: frames)!
        try reading.read(into: buffer)
        try expectClose(Double(buffer.floatChannelData![0][0]), 0.125)
        try expectClose(Double(buffer.floatChannelData![1][100]), -0.25)
    }
}

/// Same JUNK / fmt / FLLR layout `AVAudioFile` writes, with `data` size left at 0.
private func preambleFixture(frames: Int, sample: Float) throws -> URL {
    var data = Data()
    func ascii(_ value: String) { data.append(Data(value.utf8)) }
    func u16(_ value: UInt16) { var little = value.littleEndian; data.append(Data(bytes: &little, count: 2)) }
    func u32(_ value: UInt32) { var little = value.littleEndian; data.append(Data(bytes: &little, count: 4)) }
    ascii("RIFF")
    u32(4088) // initial header: chunk payload ends where the PCM will be appended
    ascii("WAVE")
    ascii("JUNK")
    u32(28)
    data.append(Data(count: 28))
    ascii("fmt ")
    u32(16)
    u16(3)
    u16(2)
    u32(48_000)
    u32(48_000 * 8)
    u16(8)
    u16(32)
    ascii("FLLR")
    u32(4008)
    data.append(Data(count: 4008))
    ascii("data")
    u32(0)
    var bits = sample.bitPattern.littleEndian
    let bytes = Data(bytes: &bits, count: 4)
    for _ in 0..<(frames * 2) { data.append(bytes) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("heard-preamble-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

private func wavFixture(frames: Int, declaredFrames: Int, sample: Float) throws -> URL {
    var data = Data()
    func ascii(_ value: String) { data.append(Data(value.utf8)) }
    func u16(_ value: UInt16) { var little = value.littleEndian; data.append(Data(bytes: &little, count: 2)) }
    func u32(_ value: UInt32) { var little = value.littleEndian; data.append(Data(bytes: &little, count: 4)) }
    let declared = UInt32(declaredFrames * 8)
    ascii("RIFF")
    u32(36 + declared)
    ascii("WAVE")
    ascii("fmt ")
    u32(16)
    u16(3)
    u16(2)
    u32(48_000)
    u32(48_000 * 8)
    u16(8)
    u16(32)
    ascii("data")
    u32(declared)
    var bits = sample.bitPattern.littleEndian
    let bytes = Data(bytes: &bits, count: 4)
    for _ in 0..<(frames * 2) { data.append(bytes) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("heard-wav-\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}
