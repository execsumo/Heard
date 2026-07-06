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
    ///
    /// When `vadSpeechSegments` is provided, only frames that overlap with a voiced segment
    /// are written — silence gaps between segments are skipped, producing a compact clip of
    /// continuous speech. Falls back to the full range when the list is empty.
    ///
    /// Returns the URL of the saved clip file, or nil on failure.
    public static func extractClip(
        from sourceURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        outputURL: URL,
        vadSpeechSegments: [(startTime: TimeInterval, endTime: TimeInterval)] = []
    ) -> URL? {
        do {
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let sampleRate = sourceFile.processingFormat.sampleRate
            let totalFrames = sourceFile.length

            // Build the list of sub-ranges to write: voiced portions only, or full range.
            // Slivers shorter than 20 ms are dropped to avoid near-empty buffers.
            let subRanges: [(start: TimeInterval, end: TimeInterval)]
            if vadSpeechSegments.isEmpty {
                subRanges = [(startTime, min(endTime, Double(totalFrames) / sampleRate))]
            } else {
                subRanges = vadSpeechSegments.compactMap { seg in
                    let lo = max(seg.startTime, startTime)
                    let hi = min(seg.endTime, endTime)
                    return hi - lo > 0.02 ? (lo, hi) : nil
                }
            }

            guard !subRanges.isEmpty else { return nil }

            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: sourceFile.processingFormat.settings,
                commonFormat: sourceFile.processingFormat.commonFormat,
                interleaved: sourceFile.processingFormat.isInterleaved
            )

            var totalWritten: AVAudioFrameCount = 0
            for range in subRanges {
                let startFrame = AVAudioFramePosition(max(0, range.start * sampleRate))
                let endFrame = min(AVAudioFramePosition(range.end * sampleRate), totalFrames)
                let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
                guard frameCount > 0 else { continue }

                sourceFile.framePosition = startFrame
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFile.processingFormat,
                    frameCapacity: frameCount
                ) else { continue }

                try sourceFile.read(into: buffer, frameCount: frameCount)
                try outputFile.write(from: buffer)
                totalWritten += frameCount
            }

            return totalWritten > 0 ? outputURL : nil
        } catch {
            NSLog("Heard: AudioClipExtractor failed: \(error)")
            return nil
        }
    }

    /// Given diarization segments for a speaker, find the best clip region (~10s of clearest speech).
    /// Picks the longest contiguous segment, or combines multiple segments up to maxClipDuration.
    public static func bestClipRegion(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        speechSegments: [(startTime: TimeInterval, endTime: TimeInterval)]? = nil
    ) -> (startTime: TimeInterval, endTime: TimeInterval)? {
        bestClipRegions(
            speakerID: speakerID,
            diarizationSegments: diarizationSegments,
            speechSegments: speechSegments,
            maxCount: 1
        ).first
    }

    /// Find up to `maxCount` distinct clip regions for a speaker, ordered best-first.
    /// Each region is up to ~10 s of audio drawn from a different speech island in the
    /// meeting. When VAD speech segments are provided, diarization spans are intersected
    /// with those speech-only ranges so extracted clips do not include silence gaps.
    public static func bestClipRegions(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        speechSegments: [(startTime: TimeInterval, endTime: TimeInterval)]? = nil,
        maxCount: Int = 3
    ) -> [(startTime: TimeInterval, endTime: TimeInterval)] {
        guard maxCount > 0 else { return [] }
        let speakerSegs = speechOnlySpeakerSegments(
            speakerID: speakerID,
            diarizationSegments: diarizationSegments,
            speechSegments: speechSegments
        )
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
        // produce at least one usable clip. Only do this without VAD speech islands;
        // when VAD is available, combining would re-introduce silence gaps.
        if regions.isEmpty, speechSegments == nil {
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

    private static func speechOnlySpeakerSegments(
        speakerID: String,
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        speechSegments: [(startTime: TimeInterval, endTime: TimeInterval)]?
    ) -> [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] {
        let speakerSegs = diarizationSegments
            .filter { $0.speakerID == speakerID && $0.endTime > $0.startTime }

        guard let speechSegments else { return speakerSegs }

        let validSpeechSegments = speechSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard !validSpeechSegments.isEmpty else { return [] }

        var clipped: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)] = []
        for diarSeg in speakerSegs {
            for speechSeg in validSpeechSegments {
                if speechSeg.startTime >= diarSeg.endTime { break }
                if speechSeg.endTime <= diarSeg.startTime { continue }

                let start = max(diarSeg.startTime, speechSeg.startTime)
                let end = min(diarSeg.endTime, speechSeg.endTime)
                if end > start {
                    clipped.append((speakerID: diarSeg.speakerID, startTime: start, endTime: end))
                }
            }
        }
        return clipped
    }

    /// One extracted voice sample: the saved WAV plus the original-audio time region it
    /// was cut from, so callers can correlate the clip back to diarizer chunk data.
    public struct ExtractedClip {
        public let url: URL
        public let startTime: TimeInterval
        public let endTime: TimeInterval
    }

    /// Extract clips for all unmatched speakers and return candidate info.
    /// Each speaker gets up to `clipsPerSpeaker` distinct samples saved to the recordings
    /// directory, ordered best-first.
    ///
    /// `vadSpeechSegments` are the original-audio voiced ranges from the app track's VAD map.
    /// When provided, silence gaps within each extracted clip are skipped so every playback
    /// is continuous speech rather than a raw time slice that may include long pauses.
    public static func extractSpeakerClips(
        unmatchedSpeakers: [UnmatchedSpeaker],
        diarizationSegments: [(speakerID: String, startTime: TimeInterval, endTime: TimeInterval)],
        speechSegments: [(startTime: TimeInterval, endTime: TimeInterval)]? = nil,
        sourceAudioURL: URL,
        outputDirectory: URL,
        clipsPerSpeaker: Int = 3,
        vadSpeechSegments: [(startTime: TimeInterval, endTime: TimeInterval)] = []
    ) -> [(speaker: UnmatchedSpeaker, clips: [ExtractedClip])] {
        var results: [(speaker: UnmatchedSpeaker, clips: [ExtractedClip])] = []

        for speaker in unmatchedSpeakers {
            let regions = bestClipRegions(
                speakerID: speaker.speakerID,
                diarizationSegments: diarizationSegments,
                speechSegments: speechSegments,
                maxCount: clipsPerSpeaker
            )

            var saved: [ExtractedClip] = []
            for region in regions {
                let clipFilename = "clip_\(UUID().uuidString.prefix(8)).wav"
                let clipURL = outputDirectory.appendingPathComponent(clipFilename)

                if let savedURL = extractClip(
                    from: sourceAudioURL,
                    startTime: region.startTime,
                    endTime: region.endTime,
                    outputURL: clipURL,
                    vadSpeechSegments: vadSpeechSegments
                ) {
                    saved.append(ExtractedClip(url: savedURL, startTime: region.startTime, endTime: region.endTime))
                }
            }

            results.append((speaker, saved))
        }

        return results
    }
}
