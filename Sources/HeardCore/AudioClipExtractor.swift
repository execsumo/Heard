import AVFoundation
import Foundation

/// Extracts short audio clips from WAV files for speaker identification playback.
public enum AudioClipExtractor {

    /// Maximum clip duration in seconds.
    private static let maxClipDuration: TimeInterval = 10.0

    /// Move a clip from the temporary `recordings/` directory into the persistent
    /// `speaker_clips/` directory so it survives the 48-hour stale-recording cleanup.
    /// Returns the new URL on success, or the original on failure.
    public static func persistClip(_ source: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }
        let destDir = fm.heardSpeakerClipsDirectory
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destination = destDir.appendingPathComponent(source.lastPathComponent)
        // If a file with the same name already lives in the destination, reuse it
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: source)
            return destination
        }
        do {
            try fm.moveItem(at: source, to: destination)
            return destination
        } catch {
            // Fall back to copy if move fails (e.g. cross-volume)
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
                return destination
            } catch {
                return source
            }
        }
    }

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
        bestClipRegions(speakerID: speakerID, diarizationSegments: diarizationSegments, maxCount: 1).first
    }

    /// Find up to `maxCount` distinct clip regions for a speaker, ordered best-first.
    /// Each region is up to ~10 s of audio drawn from a different point in the meeting so
    /// the user has multiple voice samples to disambiguate when one clip is silent or has
    /// crosstalk. Falls back to combining short fragments if no individual segment is long
    /// enough.
    public static func bestClipRegions(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        maxCount: Int = 3
    ) -> [(startTime: TimeInterval, endTime: TimeInterval)] {
        guard maxCount > 0 else { return [] }
        let speakerSegs = diarizationSegments.filter { $0.speakerID == speakerID }
        guard !speakerSegs.isEmpty else { return [] }

        // Sort by duration descending — longest segments tend to be the cleanest samples.
        let byDuration = speakerSegs.sorted {
            ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime)
        }

        var regions: [(startTime: TimeInterval, endTime: TimeInterval)] = []

        for seg in byDuration {
            if regions.count >= maxCount { break }
            let duration = seg.endTime - seg.startTime
            // Skip very short fragments — they make for unintelligible samples.
            guard duration >= 1.5 else { continue }

            if duration >= maxClipDuration {
                let mid = (seg.startTime + seg.endTime) / 2
                let half = maxClipDuration / 2
                regions.append((max(0, mid - half), mid + half))
            } else {
                regions.append((seg.startTime, seg.endTime))
            }
        }

        // Fallback for highly fragmented audio: combine consecutive short segments to
        // produce at least one usable clip.
        if regions.isEmpty {
            let chronological = speakerSegs.sorted { $0.startTime < $1.startTime }
            var totalDuration: TimeInterval = 0
            let startTime = chronological[0].startTime
            var endTime = chronological[0].endTime
            for seg in chronological {
                let segDuration = seg.endTime - seg.startTime
                if totalDuration + segDuration > maxClipDuration { break }
                endTime = seg.endTime
                totalDuration += segDuration
            }
            if totalDuration > 0 {
                regions.append((startTime, endTime))
            }
        }

        return regions
    }

    /// Extract clips for all unmatched speakers and return candidate info.
    /// Each speaker gets up to `clipsPerSpeaker` distinct samples saved to the recordings
    /// directory, ordered best-first.
    public static func extractSpeakerClips(
        unmatchedSpeakers: [(speakerID: String, temporaryName: String, embedding: [Float])],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        sourceAudioURL: URL,
        outputDirectory: URL,
        clipsPerSpeaker: Int = 3
    ) -> [(temporaryName: String, clipURLs: [URL], embedding: [Float])] {
        var results: [(temporaryName: String, clipURLs: [URL], embedding: [Float])] = []

        for speaker in unmatchedSpeakers {
            let regions = bestClipRegions(
                speakerID: speaker.speakerID,
                diarizationSegments: diarizationSegments,
                maxCount: clipsPerSpeaker
            )

            var savedURLs: [URL] = []
            for region in regions {
                let clipFilename = "clip_\(UUID().uuidString.prefix(8)).wav"
                let clipURL = outputDirectory.appendingPathComponent(clipFilename)

                if let savedURL = extractClip(
                    from: sourceAudioURL,
                    startTime: region.startTime,
                    endTime: region.endTime,
                    outputURL: clipURL
                ) {
                    savedURLs.append(savedURL)
                }
            }

            results.append((speaker.temporaryName, savedURLs, speaker.embedding))
        }

        return results
    }
}
