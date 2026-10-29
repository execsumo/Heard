import AVFoundation
import HeardCore

func runAudioCaptureSupportTests() {
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
}
