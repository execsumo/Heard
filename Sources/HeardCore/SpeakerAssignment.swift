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
    /// Placeholders come from skipped naming prompts; they are
    /// excluded from matching so the user always gets another chance to name the
    /// speaker on a later meeting.
    public static func isPlaceholderName(_ name: String) -> Bool {
        guard name.hasPrefix("Speaker_") else { return false }
        let suffix = name.dropFirst("Speaker_".count)
        return suffix.count >= 4 // Basic validation that it has an ID part
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
        localUserName: String
    ) -> [MatchResult] {
        var results: [MatchResult] = []
        var usedProfileIDs = Set<UUID>()

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
                let idSuffix = UUID().uuidString.prefix(6).uppercased()
                let name = "Speaker_\(idSuffix)"
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
            addEmbedding(match.embedding, to: &profile.embeddings)
            speakerStore.upsert(profile)
        }
    }

    /// Insert a new embedding into a stored set, respecting the per-speaker cap and
    /// keeping the set diverse: append while there's room, otherwise replace the most
    /// similar (least diverse) existing embedding. Empty embeddings are ignored.
    public static func addEmbedding(_ embedding: [Float], to embeddings: inout [[Float]]) {
        guard !embedding.isEmpty else { return }
        if embeddings.count < maxEmbeddingsPerSpeaker {
            embeddings.append(embedding)
        } else if let replaceIndex = mostSimilarIndex(to: embedding, in: embeddings) {
            embeddings[replaceIndex] = embedding
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

// MARK: - Per-Chunk Embedding Aggregation

/// Builds one robust speaker embedding from many per-chunk embeddings.
///
/// FluidAudio's offline diarizer (0.14.8+) can surface a `ChunkEmbedding` for every
/// (speaker, chunk) pair via `DiarizationResult.chunkEmbeddings`. Each carries an
/// L2-normalized 256-d WeSpeaker vector covering a short window. Any single window is
/// noisy — short, possibly overlapped with another speaker — so deriving cross-meeting
/// identity from one arbitrary window (the old "first segment per speaker" behavior)
/// is fragile and produces both false "new speaker" prompts and occasional mismatches.
///
/// This aggregates all of a speaker's windows into a duration-weighted centroid with a
/// single outlier-rejection pass, which is substantially more stable for matching
/// against the persistent speaker database than any individual window.
public enum SpeakerEmbeddingAggregator {

    /// One per-chunk embedding for a single speaker.
    public struct Chunk {
        public let vector: [Float]
        /// Relative weight in the centroid — typically the chunk's duration in seconds,
        /// so longer (more reliable) windows dominate.
        public let weight: Float

        public init(vector: [Float], weight: Float) {
            self.vector = vector
            self.weight = weight
        }
    }

    /// Cosine distance beyond which a chunk is treated as an outlier — overlapped speech
    /// or a mis-clustered window — and dropped before the final centroid is computed.
    /// 0.50 (≈ 0.5 cosine similarity) is loose enough to keep genuine intra-speaker
    /// variation while rejecting clearly foreign windows. The trim never removes every
    /// chunk, so a speaker always yields a centroid.
    public static let outlierDistanceThreshold: Float = 0.50

    /// Build one L2-normalized centroid per speaker from grouped chunk embeddings.
    /// Keys are opaque speaker IDs; speakers with no usable chunk are omitted.
    public static func centroids(perSpeaker chunks: [String: [Chunk]]) -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for (speakerID, speakerChunks) in chunks {
            if let centroid = centroid(of: speakerChunks) {
                result[speakerID] = centroid
            }
        }
        return result
    }

    /// Duration-weighted centroid of one speaker's chunks, with a single outlier-trim
    /// pass. Returns `nil` only when there is no usable chunk at all.
    public static func centroid(of chunks: [Chunk]) -> [Float]? {
        // Keep only non-empty vectors with positive weight, sharing one dimensionality.
        let usable = chunks.filter { !$0.vector.isEmpty && $0.weight > 0 }
        guard let dim = usable.first?.vector.count, dim > 0 else { return nil }
        let clean = usable.filter { $0.vector.count == dim }
        guard !clean.isEmpty else { return nil }

        // First pass: weighted mean over every chunk.
        guard let provisional = weightedMean(clean, dim: dim) else { return nil }

        // Second pass: drop chunks too far from the provisional centroid, then recompute.
        // Never trim to empty — fall back to the full set if everything looks like an
        // outlier (which happens for a lone, internally-inconsistent speaker).
        let kept = clean.filter { cosineDistance($0.vector, provisional) <= outlierDistanceThreshold }
        let basis = kept.isEmpty ? clean : kept
        return weightedMean(basis, dim: dim) ?? provisional
    }

    /// Weighted mean of equal-length vectors, L2-normalized. Caller guarantees a shared
    /// `dim` and at least one element.
    private static func weightedMean(_ chunks: [Chunk], dim: Int) -> [Float]? {
        var acc = [Float](repeating: 0, count: dim)
        var totalWeight: Float = 0
        for chunk in chunks {
            let w = chunk.weight
            for i in 0..<dim {
                acc[i] += w * chunk.vector[i]
            }
            totalWeight += w
        }
        guard totalWeight > 0 else { return nil }
        return l2Normalized(acc)
    }
}

/// Returns the L2-normalized copy of `v`, or `v` unchanged when its norm is ~0.
/// Cosine distance is already scale-invariant, but normalizing keeps every embedding we
/// persist on a unit sphere so stored profiles stay uniform across versions.
public func l2Normalized(_ v: [Float]) -> [Float] {
    guard !v.isEmpty else { return v }
    var norm: Float = 0
    vDSP_dotpr(v, 1, v, 1, &norm, vDSP_Length(v.count))
    norm = sqrt(norm)
    guard norm > 0 else { return v }
    var out = [Float](repeating: 0, count: v.count)
    var inv = 1 / norm
    vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
    return out
}

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
