import AVFoundation
import CoreAudio

public enum AudioCaptureSupport {
    /// Copy either interleaved or planar float PCM without assuming buffer zero
    /// contains every channel. A tap-only aggregate keeps physical microphone
    /// inputs out of this buffer list.
    public static func copyInput(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channels = Int(format.channelCount)
        guard buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == channels,
              buffers.allSatisfy({ $0.mNumberChannels > 0 && $0.mData != nil }) else { return nil }
        let frames = buffers.map { Int($0.mDataByteSize) / (Int($0.mNumberChannels) * MemoryLayout<Float>.size) }.min() ?? 0
        guard frames > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = result.floatChannelData else { return nil }
        result.frameLength = AVAudioFrameCount(frames)
        var channelOffset = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            let source = buffer.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<count {
                    output[channelOffset + channel][frame] = source[frame * count + channel]
                }
            }
            channelOffset += count
        }
        return result
    }
}
