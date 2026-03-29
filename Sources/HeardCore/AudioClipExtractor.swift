import AVFoundation
import Foundation

/// Extracts short audio clips from WAV files for speaker identification playback.
public enum AudioClipExtractor {

    /// Maximum clip duration in seconds.
    private static let maxClipDuration: TimeInterval = 10.0

    /// Extract a clip from a WAV file at the given time range.
    /// Returns the URL of the saved clip file, or nil on failure.
    public static func extractClip(
        from sourceURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        outputURL: URL
    ) -> URL? {
        do {
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let sampleRate = sourceFile.processingFormat.sampleRate
            let totalFrames = sourceFile.length

            // Clamp to file bounds
            let startFrame = AVAudioFramePosition(max(0, startTime * sampleRate))
            let endFrame = min(AVAudioFramePosition(endTime * sampleRate), totalFrames)
            let frameCount = AVAudioFrameCount(endFrame - startFrame)

            guard frameCount > 0 else { return nil }

            // Seek to start position
            sourceFile.framePosition = startFrame

            // Read the segment
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFile.processingFormat,
                frameCapacity: frameCount
            ) else { return nil }

            try sourceFile.read(into: buffer, frameCount: frameCount)

            // Write to output file
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: sourceFile.processingFormat.settings,
                commonFormat: sourceFile.processingFormat.commonFormat,
                interleaved: sourceFile.processingFormat.isInterleaved
            )
            try outputFile.write(from: buffer)

            return outputURL
        } catch {
            NSLog("Heard: AudioClipExtractor failed: \(error)")
            return nil
        }
    }

    /// Given diarization segments for a speaker, find the best clip region (~10s of clearest speech).
    /// Picks the longest contiguous segment, or combines multiple segments up to maxClipDuration.
    public static func bestClipRegion(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)]
    ) -> (startTime: TimeInterval, endTime: TimeInterval)? {
        let speakerSegs = diarizationSegments
            .filter { $0.speakerID == speakerID }
            .sorted { $0.startTime < $1.startTime }

        guard !speakerSegs.isEmpty else { return nil }

        // Find the longest single segment first
        let longest = speakerSegs.max(by: {
            ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime)
        })!

        let longestDuration = longest.endTime - longest.startTime

        if longestDuration >= maxClipDuration {
            // Trim to maxClipDuration from the middle of the segment for best quality
            let mid = (longest.startTime + longest.endTime) / 2
            let halfClip = maxClipDuration / 2
            return (max(0, mid - halfClip), mid + halfClip)
        }

        if longestDuration >= 3.0 {
            // Good enough single segment
            return (longest.startTime, longest.endTime)
        }

        // Combine consecutive segments to reach ~10s
        var totalDuration: TimeInterval = 0
        let startTime = speakerSegs[0].startTime
        var endTime = speakerSegs[0].endTime

        for seg in speakerSegs {
            let segDuration = seg.endTime - seg.startTime
            if totalDuration + segDuration > maxClipDuration { break }
            endTime = seg.endTime
            totalDuration += segDuration
        }

        return totalDuration > 0 ? (startTime, endTime) : nil
    }

    /// Extract clips for all unmatched speakers and return candidate info.
    /// Saves clips to the recordings directory.
    public static func extractSpeakerClips(
        unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float])],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        sourceAudioURL: URL,
        outputDirectory: URL
    ) -> [(temporaryName: String, clipURL: URL?, embedding: [Float])] {
        var results: [(temporaryName: String, clipURL: URL?, embedding: [Float])] = []

        for speaker in unmatchedSpeakers {
            guard let region = bestClipRegion(
                speakerID: speaker.speakerID,
                diarizationSegments: diarizationSegments
            ) else {
                results.append((speaker.temporaryName, nil, speaker.embedding))
                continue
            }

            let clipFilename = "clip_\(UUID().uuidString.prefix(8)).wav"
            let clipURL = outputDirectory.appendingPathComponent(clipFilename)

            let savedURL = extractClip(
                from: sourceAudioURL,
                startTime: region.startTime,
                endTime: region.endTime,
                outputURL: clipURL
            )

            results.append((speaker.temporaryName, savedURL, speaker.embedding))
        }

        return results
    }
}
