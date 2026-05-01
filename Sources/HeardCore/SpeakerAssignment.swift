import Accelerate
import Foundation

// MARK: - Diarization Types

/// A speaker segment from LS-EEND diarization.
public struct DiarizationSegment {
    public let speakerID: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(speakerID: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A speaker embedding from WeSpeaker (256-dimensional float vector).
public struct SpeakerEmbedding {
    public let speakerID: String
    public let vector: [Float]

    public init(speakerID: String, vector: [Float]) {
        self.speakerID = speakerID
        self.vector = vector
    }
}

/// Combined diarization output for a single track.
public struct TrackDiarizationResult {
    public let segments: [DiarizationSegment]
    public let embeddings: [SpeakerEmbedding]

    public init(segments: [DiarizationSegment], embeddings: [SpeakerEmbedding]) {
        self.segments = segments
        self.embeddings = embeddings
    }
}

// MARK: - Speaker Matcher

/// Matches detected speaker embeddings against the persistent speaker database.
/// Uses cosine distance with configurable thresholds.
public enum SpeakerMatcher {

    /// Cosine distance threshold for matching (lower = more similar).
    /// 0.30 is on the strict side of typical WeSpeaker ranges — the previous 0.40
    /// caused false-positive matches against unrelated existing profiles, so newly
    /// detected speakers were silently classified as already-known and the naming
    /// prompt never fired.
    public static let matchThreshold: Float = 0.30

    /// Minimum gap between best and second-best match to accept a match.
    public static let confidenceMargin: Float = 0.10

    /// Strong confidence margin for auto-updating embeddings.
    public static let autoUpdateMargin: Float = 0.15

    /// Maximum stored embeddings per speaker.
    public static let maxEmbeddingsPerSpeaker = 5

    /// True when `name` matches the auto-generated `Speaker N` placeholder pattern.
    /// Placeholders come from skipped or auto-dismissed naming prompts; they are
    /// excluded from matching so the user always gets another chance to name the
    /// speaker on a later meeting.
    public static func isPlaceholderName(_ name: String) -> Bool {
        guard name.hasPrefix("Speaker ") else { return false }
        let suffix = name.dropFirst("Speaker ".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isWholeNumber)
    }

    public struct MatchResult {
        public let detectedSpeakerID: String
        public let assignedName: String
        public let matchedProfileID: UUID?
        public let isNewSpeaker: Bool
        public let embedding: [Float]
    }

    /// Match detected speaker embeddings against the speaker database.
    /// Returns a mapping from detected speaker IDs to display names.
    /// `startingSpeakerNumber` is the first "Speaker N" label to assign to an
    /// unmatched speaker. Callers persist a monotonic counter so numbers stay
    /// globally unique across meetings — naming "Speaker 7" later only rewrites
    /// the one transcript that actually used it.
    public static func matchSpeakers(
        embeddings: [SpeakerEmbedding],
        database: [SpeakerProfile],
        localUserName: String,
        startingSpeakerNumber: Int = 1
    ) -> [MatchResult] {
        var results: [MatchResult] = []
        var usedProfileIDs = Set<UUID>()
        var unnamedCounter = max(startingSpeakerNumber, 1)

        for detected in embeddings {
            // Mic-track speakers (M_ prefix) are always the local user
            if detected.speakerID.hasPrefix("M_") {
                results.append(MatchResult(
                    detectedSpeakerID: detected.speakerID,
                    assignedName: localUserName.isEmpty ? "Me" : localUserName,
                    matchedProfileID: nil,
                    isNewSpeaker: false,
                    embedding: detected.vector
                ))
                continue
            }

            // Try to match against database
            let match = findBestMatch(
                embedding: detected.vector,
                database: database,
                excludeIDs: usedProfileIDs
            )

            if let match {
                usedProfileIDs.insert(match.profileID)
                NSLog("Heard: matchSpeakers → '\(detected.speakerID)' matched profile '\(match.name)' (distance=\(String(format: "%.3f", match.distance)), margin=\(String(format: "%.3f", match.margin)))")
                results.append(MatchResult(
                    detectedSpeakerID: detected.speakerID,
                    assignedName: match.name,
                    matchedProfileID: match.profileID,
                    isNewSpeaker: false,
                    embedding: detected.vector
                ))
            } else {
                let name = "Speaker \(unnamedCounter)"
                unnamedCounter += 1
                NSLog("Heard: matchSpeakers → '\(detected.speakerID)' has no confident match → '\(name)' (will trigger naming prompt)")
                results.append(MatchResult(
                    detectedSpeakerID: detected.speakerID,
                    assignedName: name,
                    matchedProfileID: nil,
                    isNewSpeaker: true,
                    embedding: detected.vector
                ))
            }
        }

        return results
    }

    private struct DatabaseMatch {
        let profileID: UUID
        let name: String
        let distance: Float
        let margin: Float
    }

    private static func findBestMatch(
        embedding: [Float],
        database: [SpeakerProfile],
        excludeIDs: Set<UUID>
    ) -> DatabaseMatch? {
        guard !embedding.isEmpty else { return nil }

        var candidates: [(id: UUID, name: String, distance: Float)] = []

        for profile in database where !excludeIDs.contains(profile.id) {
            guard !profile.embeddings.isEmpty else { continue }
            // Placeholder profiles ("Speaker 1", "Speaker 2", ...) are skipped/timed-out
            // entries that the user never actually named. They must not poison matching —
            // otherwise a new speaker on a later meeting silently matches an old phantom
            // profile and the naming prompt never fires. The user can still see and rename
            // these in the Speakers settings tab, which converts them into real matches.
            if isPlaceholderName(profile.name) { continue }

            // Use minimum distance across all stored embeddings for this speaker
            let minDistance = profile.embeddings
                .map { cosineDistance(embedding, $0) }
                .min() ?? Float.infinity

            candidates.append((id: profile.id, name: profile.name, distance: minDistance))
        }

        candidates.sort { $0.distance < $1.distance }

        guard let best = candidates.first, best.distance < matchThreshold else {
            return nil
        }

        let secondBest = candidates.dropFirst().first?.distance ?? Float.infinity
        let margin = secondBest - best.distance

        guard margin >= confidenceMargin else {
            return nil // Too ambiguous
        }

        return DatabaseMatch(
            profileID: best.id,
            name: best.name,
            distance: best.distance,
            margin: margin
        )
    }

    /// Update speaker database with new embeddings from a processed meeting.
    /// Only refreshes existing matched profiles. New (unmatched) speakers are not
    /// created here — they're created later when the user names them through the
    /// naming prompt (or when the prompt is skipped/timed out).
    @MainActor public static func updateDatabase(
        matches: [MatchResult],
        speakerStore: SpeakerStore
    ) {
        for match in matches {
            guard !match.embedding.isEmpty else { continue }
            guard let profileID = match.matchedProfileID else { continue }

            guard var profile = speakerStore.speakers.first(where: { $0.id == profileID }) else { continue }
            profile.lastSeen = Date()
            profile.meetingCount += 1

            // Add embedding if we have room, keeping diverse set
            if profile.embeddings.count < maxEmbeddingsPerSpeaker {
                profile.embeddings.append(match.embedding)
            } else {
                // Replace the most similar existing embedding (least diverse)
                if let replaceIndex = mostSimilarIndex(to: match.embedding, in: profile.embeddings) {
                    profile.embeddings[replaceIndex] = match.embedding
                }
            }
            speakerStore.upsert(profile)
        }
    }

    /// Find the index of the stored embedding most similar to the new one.
    private static func mostSimilarIndex(to new: [Float], in stored: [[Float]]) -> Int? {
        guard !stored.isEmpty else { return nil }
        var minDistance: Float = .infinity
        var minIndex = 0
        for (i, existing) in stored.enumerated() {
            let d = cosineDistance(new, existing)
            if d < minDistance {
                minDistance = d
                minIndex = i
            }
        }
        return minIndex
    }
}

// MARK: - Segment Merger

/// Merges transcription segments with diarization results into a final transcript.
public enum SegmentMerger {

    /// Merge transcription segments with diarization segments.
    /// Assigns speaker labels via temporal overlap matching.
    public static func merge(
        transcriptionSegments: [TranscriptSegment],
        diarizationSegments: [DiarizationSegment],
        speakerNameMap: [String: String], // diarization speakerID → display name
        micDelaySeconds: TimeInterval = 0
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []

        for var segment in transcriptionSegments {
            // Find diarization segment with maximum temporal overlap
            let speaker = findBestOverlap(
                start: segment.startTime,
                end: segment.endTime,
                diarizationSegments: diarizationSegments
            )

            if let speaker, let name = speakerNameMap[speaker] {
                segment.speaker = name
            }
            // else keep existing speaker label

            result.append(segment)
        }

        // Merge consecutive segments from the same speaker
        return mergeConsecutive(result)
    }

    /// Public entry point for overlap matching from pipeline processor.
    public static func findBestOverlapPublic(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> String? {
        findBestOverlap(start: start, end: end, diarizationSegments: diarizationSegments)
    }

    /// Find the diarization speaker with maximum temporal overlap for a given time range.
    private static func findBestOverlap(
        start: TimeInterval,
        end: TimeInterval,
        diarizationSegments: [DiarizationSegment]
    ) -> String? {
        var bestSpeaker: String?
        var bestOverlap: TimeInterval = 0

        for seg in diarizationSegments {
            let overlapStart = max(start, seg.startTime)
            let overlapEnd = min(end, seg.endTime)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = seg.speakerID
            }
        }

        // If no overlap, find nearest segment by time gap
        if bestSpeaker == nil, !diarizationSegments.isEmpty {
            var minGap: TimeInterval = .infinity
            for seg in diarizationSegments {
                let gap = min(abs(start - seg.endTime), abs(end - seg.startTime))
                if gap < minGap {
                    minGap = gap
                    bestSpeaker = seg.speakerID
                }
            }
        }

        return bestSpeaker
    }

    /// Merge consecutive segments from the same speaker into single blocks.
    public static func mergeConsecutive(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        var current = segments[0]

        for segment in segments.dropFirst() {
            if segment.speaker == current.speaker {
                // Same speaker — extend the block
                current.endTime = segment.endTime
                current.text += " " + segment.text
            } else {
                merged.append(current)
                current = segment
            }
        }
        merged.append(current)

        return merged
    }
}

// MARK: - Cosine Distance

/// Cosine distance between two vectors: 1 - cosine_similarity.
/// Returns 0 for identical vectors, 2 for opposite vectors.
public func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return Float.infinity }

    let n = vDSP_Length(a.count)
    var dotProduct: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    vDSP_dotpr(a, 1, b, 1, &dotProduct, n)
    vDSP_dotpr(a, 1, a, 1, &normA, n)
    vDSP_dotpr(b, 1, b, 1, &normB, n)

    let denom = sqrt(normA) * sqrt(normB)
    guard denom > 0 else { return Float.infinity }

    let similarity = dotProduct / denom
    return 1.0 - similarity
}
