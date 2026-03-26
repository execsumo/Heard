import AVFAudio
import FluidAudio
import Foundation

// MARK: - VAD Segment Map

/// Maps trimmed-audio timestamps back to original-audio timestamps after VAD silence removal.
/// Uses binary search for O(log n) lookups.
public struct VadSegmentMap {
    public struct Mapping {
        public let trimmedStart: TimeInterval
        public let trimmedEnd: TimeInterval
        public let originalStart: TimeInterval
        public let originalEnd: TimeInterval

        public init(trimmedStart: TimeInterval, trimmedEnd: TimeInterval, originalStart: TimeInterval, originalEnd: TimeInterval) {
            self.trimmedStart = trimmedStart
            self.trimmedEnd = trimmedEnd
            self.originalStart = originalStart
            self.originalEnd = originalEnd
        }
    }

    public let mappings: [Mapping]

    public init(mappings: [Mapping]) {
        self.mappings = mappings
    }

    public var trimmedDuration: TimeInterval {
        mappings.last?.trimmedEnd ?? 0
    }

    /// Convert a timestamp in trimmed-audio space to original-audio space.
    public func toOriginalTime(_ trimmedTime: TimeInterval) -> TimeInterval {
        guard !mappings.isEmpty else { return trimmedTime }

        var lo = 0, hi = mappings.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let m = mappings[mid]
            if trimmedTime < m.trimmedStart {
                hi = mid - 1
            } else if trimmedTime > m.trimmedEnd {
                lo = mid + 1
            } else {
                let offset = trimmedTime - m.trimmedStart
                return m.originalStart + offset
            }
        }

        if let last = mappings.last {
            return last.originalEnd
        }
        return trimmedTime
    }
}

// MARK: - Preprocessed Track

/// The result of preprocessing one audio track: 16 kHz mono float samples + VAD map.
public struct PreprocessedTrack {
    public let samples: [Float]
    public let sampleRate: Double // always 16000
    public let vadMap: VadSegmentMap

    public init(samples: [Float], sampleRate: Double, vadMap: VadSegmentMap) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.vadMap = vadMap
    }

    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

// MARK: - Audio Preprocessor

/// Stage 1: Load WAV → resample to 16 kHz mono → run Silero VAD → trim silence.
/// Uses FluidAudio's AudioConverter for resampling and VadManager for voice activity detection.
public enum AudioPreprocessor {

    public static let targetSampleRate: Double = 16_000
    private static let vadChunkSize = 4096 // Silero VAD expects 4096-sample chunks (256ms at 16kHz)

    /// Preprocess a recorded WAV file into a 16 kHz mono float buffer with VAD trimming.
    public static func preprocess(wavURL: URL) async throws -> PreprocessedTrack {
        // Step 1: Load and resample to 16kHz mono using FluidAudio's AudioConverter
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)

        // Step 2: Run Silero VAD to detect speech segments
        let vadManager = try await VadManager()
        let speechSegments = try await runVad(on: samples, using: vadManager)

        // Step 3: Build trimmed audio and segment map
        let (trimmedSamples, vadMap) = buildTrimmedAudio(
            samples: samples,
            speechSegments: speechSegments,
            sampleRate: targetSampleRate
        )

        return PreprocessedTrack(
            samples: trimmedSamples,
            sampleRate: targetSampleRate,
            vadMap: vadMap
        )
    }

    /// Run Silero VAD chunk-by-chunk and aggregate into speech segments.
    private static func runVad(
        on samples: [Float],
        using vadManager: VadManager
    ) async throws -> [(start: Int, end: Int)] {
        let results = try await vadManager.process(samples)

        // Convert per-chunk VadResults into contiguous speech segments
        var segments: [(start: Int, end: Int)] = []
        var inSpeech = false
        var segStart = 0

        for (i, result) in results.enumerated() {
            let sampleOffset = i * vadChunkSize
            if result.isVoiceActive && !inSpeech {
                segStart = sampleOffset
                inSpeech = true
            } else if !result.isVoiceActive && inSpeech {
                segments.append((start: segStart, end: sampleOffset))
                inSpeech = false
            }
        }
        if inSpeech {
            segments.append((start: segStart, end: samples.count))
        }

        return segments
    }

    /// Test-accessible wrapper for buildTrimmedAudio.
    public static func buildTrimmedAudioPublic(
        samples: [Float],
        speechSegments: [(start: Int, end: Int)],
        sampleRate: Double
    ) -> ([Float], VadSegmentMap) {
        buildTrimmedAudio(samples: samples, speechSegments: speechSegments, sampleRate: sampleRate)
    }

    /// Build trimmed samples and VAD segment map from detected speech segments.
    private static func buildTrimmedAudio(
        samples: [Float],
        speechSegments: [(start: Int, end: Int)],
        sampleRate: Double
    ) -> ([Float], VadSegmentMap) {
        // If no speech detected, return all samples (don't discard everything)
        if speechSegments.isEmpty {
            let fullMap = VadSegmentMap(mappings: [
                VadSegmentMap.Mapping(
                    trimmedStart: 0,
                    trimmedEnd: Double(samples.count) / sampleRate,
                    originalStart: 0,
                    originalEnd: Double(samples.count) / sampleRate
                ),
            ])
            return (samples, fullMap)
        }

        var trimmedSamples: [Float] = []
        var mappings: [VadSegmentMap.Mapping] = []
        var trimmedOffset: TimeInterval = 0

        for seg in speechSegments {
            let originalStart = Double(seg.start) / sampleRate
            let originalEnd = Double(min(seg.end, samples.count)) / sampleRate
            let segDuration = originalEnd - originalStart

            mappings.append(VadSegmentMap.Mapping(
                trimmedStart: trimmedOffset,
                trimmedEnd: trimmedOffset + segDuration,
                originalStart: originalStart,
                originalEnd: originalEnd
            ))

            let clampedEnd = min(seg.end, samples.count)
            trimmedSamples.append(contentsOf: samples[seg.start..<clampedEnd])
            trimmedOffset += segDuration
        }

        return (trimmedSamples, VadSegmentMap(mappings: mappings))
    }
}
