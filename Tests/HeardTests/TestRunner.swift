import Foundation
import HeardCore

// MARK: - Lightweight Test Harness (no Xcode required)

var totalTests = 0
var passedTests = 0
var failedTests: [(String, String)] = []

func test(_ name: String, _ body: () throws -> Void) {
    totalTests += 1
    do {
        try body()
        passedTests += 1
        print("  ✓ \(name)")
    } catch {
        failedTests.append((name, "\(error)"))
        print("  ✗ \(name) — \(error)")
    }
}

func testAsync(_ name: String, _ body: () async throws -> Void) async {
    totalTests += 1
    do {
        try await body()
        passedTests += 1
        print("  ✓ \(name)")
    } catch {
        failedTests.append((name, "\(error)"))
        print("  ✗ \(name) — \(error)")
    }
}

func expect(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) throws {
    guard condition else {
        throw TestFailure(message.isEmpty ? "Assertion failed at \(file):\(line)" : message)
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) throws {
    guard a == b else {
        throw TestFailure(message.isEmpty ? "Expected \(a) == \(b) at \(file):\(line)" : message)
    }
}

func expectClose(_ a: Double, _ b: Double, tolerance: Double = 0.001) throws {
    guard abs(a - b) < tolerance else {
        throw TestFailure("Expected \(a) ≈ \(b) (tolerance \(tolerance))")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - VadSegmentMap Tests

func runVadSegmentMapTests() {
    print("\n📐 VadSegmentMap Tests")

    test("Empty map returns input time") {
        let map = VadSegmentMap(mappings: [])
        try expectClose(map.toOriginalTime(5.0), 5.0)
    }

    test("Empty map has zero trimmed duration") {
        let map = VadSegmentMap(mappings: [])
        try expectClose(map.trimmedDuration, 0)
    }

    test("Identity mapping passes through") {
        let map = VadSegmentMap(mappings: [
            .init(trimmedStart: 0, trimmedEnd: 10, originalStart: 0, originalEnd: 10),
        ])
        try expectClose(map.toOriginalTime(0), 0)
        try expectClose(map.toOriginalTime(5), 5)
        try expectClose(map.toOriginalTime(10), 10)
    }

    test("Silence removal remaps timestamps") {
        // Original: [0-3s speech] [3-7s silence] [7-10s speech]
        // Trimmed:  [0-3s]                       [3-6s]
        let map = VadSegmentMap(mappings: [
            .init(trimmedStart: 0, trimmedEnd: 3, originalStart: 0, originalEnd: 3),
            .init(trimmedStart: 3, trimmedEnd: 6, originalStart: 7, originalEnd: 10),
        ])
        try expectClose(map.trimmedDuration, 6)
        try expectClose(map.toOriginalTime(0), 0)
        try expectClose(map.toOriginalTime(1.5), 1.5)
        try expectClose(map.toOriginalTime(3.5), 7.5)
        try expectClose(map.toOriginalTime(5), 9)
    }

    test("Time after last segment clamps to end") {
        let map = VadSegmentMap(mappings: [
            .init(trimmedStart: 0, trimmedEnd: 5, originalStart: 0, originalEnd: 5),
        ])
        try expectClose(map.toOriginalTime(10), 5)
    }

    test("Three segments map correctly") {
        let map = VadSegmentMap(mappings: [
            .init(trimmedStart: 0, trimmedEnd: 2, originalStart: 0, originalEnd: 2),
            .init(trimmedStart: 2, trimmedEnd: 5, originalStart: 5, originalEnd: 8),
            .init(trimmedStart: 5, trimmedEnd: 8, originalStart: 9, originalEnd: 12),
        ])
        try expectClose(map.trimmedDuration, 8)
        try expectClose(map.toOriginalTime(1), 1)
        try expectClose(map.toOriginalTime(3), 6)
        try expectClose(map.toOriginalTime(6), 10)
    }
}

// MARK: - Cosine Distance & Speaker Matcher Tests

func runSpeakerMatcherTests() {
    print("\n🔊 Cosine Distance & Speaker Matcher Tests")

    test("Identical vectors have zero distance") {
        let v = [Float](repeating: 1.0, count: 256)
        try expect(abs(cosineDistance(v, v)) < 0.001)
    }

    test("Orthogonal vectors have distance one") {
        var a = [Float](repeating: 0, count: 4)
        var b = [Float](repeating: 0, count: 4)
        a[0] = 1.0; b[1] = 1.0
        try expect(abs(cosineDistance(a, b) - 1.0) < 0.001)
    }

    test("Opposite vectors have distance two") {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        try expect(abs(cosineDistance(a, b) - 2.0) < 0.001)
    }

    test("Empty vectors return infinity") {
        try expect(cosineDistance([], []).isInfinite)
    }

    test("Mismatched lengths return infinity") {
        try expect(cosineDistance([1, 2], [1, 2, 3]).isInfinite)
    }

    test("Mic track speaker is always local user") {
        let embeddings = [SpeakerEmbedding(speakerID: "M_0", vector: [Float](repeating: 0.5, count: 256))]
        let results = SpeakerMatcher.matchSpeakers(embeddings: embeddings, database: [], localUserName: "Alice")
        try expectEqual(results.count, 1)
        try expectEqual(results[0].assignedName, "Alice")
        try expect(!results[0].isNewSpeaker)
    }

    test("Mic track defaults to Me when name empty") {
        let embeddings = [SpeakerEmbedding(speakerID: "M_0", vector: [Float](repeating: 0.5, count: 256))]
        let results = SpeakerMatcher.matchSpeakers(embeddings: embeddings, database: [], localUserName: "")
        try expectEqual(results[0].assignedName, "Me")
    }

    test("Unknown speakers get numbered names") {
        let embeddings = [
            SpeakerEmbedding(speakerID: "R_0", vector: [1, 0, 0]),
            SpeakerEmbedding(speakerID: "R_1", vector: [0, 1, 0]),
        ]
        let results = SpeakerMatcher.matchSpeakers(embeddings: embeddings, database: [], localUserName: "Me")
        try expectEqual(results[0].assignedName, "Speaker 1")
        try expectEqual(results[1].assignedName, "Speaker 2")
        try expect(results[0].isNewSpeaker)
    }

    test("Matches known speaker by embedding") {
        let profile = SpeakerProfile(
            id: UUID(), name: "Bob", embeddings: [[1, 0, 0, 0, 0]],
            firstSeen: Date(), lastSeen: Date(), meetingCount: 3
        )
        let embeddings = [SpeakerEmbedding(speakerID: "R_0", vector: [0.99, 0.01, 0, 0, 0])]
        let results = SpeakerMatcher.matchSpeakers(embeddings: embeddings, database: [profile], localUserName: "Me")
        try expectEqual(results[0].assignedName, "Bob")
        try expect(!results[0].isNewSpeaker)
    }

    test("Does not match distant embedding") {
        let profile = SpeakerProfile(
            id: UUID(), name: "Bob", embeddings: [[1, 0, 0, 0, 0]],
            firstSeen: Date(), lastSeen: Date(), meetingCount: 3
        )
        let embeddings = [SpeakerEmbedding(speakerID: "R_0", vector: [0, 0, 0, 0, 1])]
        let results = SpeakerMatcher.matchSpeakers(embeddings: embeddings, database: [profile], localUserName: "Me")
        try expectEqual(results[0].assignedName, "Speaker 1")
        try expect(results[0].isNewSpeaker)
    }
}

// MARK: - Segment Merger Tests

func runSegmentMergerTests() {
    print("\n✂️  Segment Merger Tests")

    test("Merges consecutive same-speaker segments") {
        let segments = [
            TranscriptSegment(speaker: "Alice", startTime: 0, endTime: 5, text: "Hello."),
            TranscriptSegment(speaker: "Alice", startTime: 5, endTime: 10, text: "How are you?"),
        ]
        let merged = SegmentMerger.mergeConsecutive(segments)
        try expectEqual(merged.count, 1)
        try expectEqual(merged[0].text, "Hello. How are you?")
        try expectClose(merged[0].endTime, 10)
    }

    test("Keeps different speakers separate") {
        let segments = [
            TranscriptSegment(speaker: "Alice", startTime: 0, endTime: 5, text: "Hello."),
            TranscriptSegment(speaker: "Bob", startTime: 5, endTime: 10, text: "Hi."),
            TranscriptSegment(speaker: "Alice", startTime: 10, endTime: 15, text: "Great."),
        ]
        let merged = SegmentMerger.mergeConsecutive(segments)
        try expectEqual(merged.count, 3)
    }

    test("Empty input returns empty") {
        try expect(SegmentMerger.mergeConsecutive([]).isEmpty)
    }

    test("Finds best overlap exact match") {
        let diar = [
            DiarizationSegment(speakerID: "S1", startTime: 0, endTime: 5),
            DiarizationSegment(speakerID: "S2", startTime: 5, endTime: 10),
        ]
        try expectEqual(SegmentMerger.findBestOverlapPublic(start: 5, end: 10, diarizationSegments: diar), "S2")
    }

    test("Returns nil for empty diarization segments") {
        let result = SegmentMerger.findBestOverlapPublic(start: 0, end: 5, diarizationSegments: [])
        try expect(result == nil)
    }

    test("Full merge applies diarization labels") {
        let trans = [
            TranscriptSegment(speaker: "Unknown", startTime: 0, endTime: 5, text: "Hello."),
            TranscriptSegment(speaker: "Unknown", startTime: 5, endTime: 10, text: "Hi."),
        ]
        let diar = [
            DiarizationSegment(speakerID: "S1", startTime: 0, endTime: 5),
            DiarizationSegment(speakerID: "S2", startTime: 5, endTime: 10),
        ]
        let result = SegmentMerger.merge(
            transcriptionSegments: trans, diarizationSegments: diar,
            speakerNameMap: ["S1": "Alice", "S2": "Bob"]
        )
        try expectEqual(result[0].speaker, "Alice")
        try expectEqual(result[1].speaker, "Bob")
    }
}

// MARK: - Audio Preprocessor Tests

func runAudioPreprocessorTests() {
    print("\n🎵 Audio Preprocessor Tests")

    test("No speech returns all samples") {
        let samples = [Float](repeating: 0.01, count: 16000)
        let (trimmed, map) = AudioPreprocessor.buildTrimmedAudioPublic(
            samples: samples, speechSegments: [], sampleRate: 16000
        )
        try expectEqual(trimmed.count, 16000)
        try expectEqual(map.mappings.count, 1)
        try expectClose(map.trimmedDuration, 1.0)
    }

    test("Silence removal trims correctly") {
        let samples = [Float](repeating: 0.5, count: 48000) // 3s
        let speechSegments: [(start: Int, end: Int)] = [
            (start: 0, end: 16000),      // 0-1s
            (start: 32000, end: 48000),   // 2-3s
        ]
        let (trimmed, map) = AudioPreprocessor.buildTrimmedAudioPublic(
            samples: samples, speechSegments: speechSegments, sampleRate: 16000
        )
        try expectEqual(trimmed.count, 32000)
        try expectEqual(map.mappings.count, 2)
        try expectClose(map.trimmedDuration, 2.0)
        try expectClose(map.toOriginalTime(1.5), 2.5) // second segment
    }

    test("End beyond sample count is clamped") {
        let samples = [Float](repeating: 0.5, count: 16000)
        let (trimmed, _) = AudioPreprocessor.buildTrimmedAudioPublic(
            samples: samples, speechSegments: [(start: 0, end: 20000)], sampleRate: 16000
        )
        try expectEqual(trimmed.count, 16000)
    }
}

// MARK: - Transcript Writer Tests

func runTranscriptWriterTests() {
    print("\n📝 Transcript Writer Tests")

    test("Write creates markdown with correct content") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "Sprint Planning",
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600),
            participants: ["Alice", "Bob"],
            segments: [
                TranscriptSegment(speaker: "Alice", startTime: 0, endTime: 30, text: "Hello everyone."),
                TranscriptSegment(speaker: "Bob", startTime: 30, endTime: 60, text: "Hi Alice."),
            ]
        )

        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        try expect(FileManager.default.fileExists(atPath: url.path), "File should exist")

        let content = try String(contentsOf: url, encoding: .utf8)
        try expect(content.contains("# Sprint Planning"), "Should contain title")
        try expect(content.contains("**Alice:**"), "Should contain Alice")
        try expect(content.contains("**Bob:**"), "Should contain Bob")
        try expect(content.contains("Hello everyone."), "Should contain text")
    }

    test("Write avoids duplicate filenames") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "Meeting", startTime: Date(),
            endTime: Date().addingTimeInterval(60),
            participants: ["Me"],
            segments: [TranscriptSegment(speaker: "Me", startTime: 0, endTime: 60, text: "Test.")]
        )

        let url1 = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        let url2 = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        try expect(url1 != url2, "Should have different filenames")
    }

    test("Timestamp formatting") {
        let t1: TimeInterval = 3661
        try expectEqual(t1.timestampString, "1:01:01")
        let t2: TimeInterval = 65
        try expectEqual(t2.timestampString, "01:05")
        let t3: TimeInterval = 0
        try expectEqual(t3.timestampString, "00:00")
    }
}

// MARK: - Store Tests

@MainActor func runStoreTests() {
    print("\n💾 Store Tests")

    test("SpeakerStore upsert and persist") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("speakers.json")
        let store = SpeakerStore(url: url)
        store.upsert(SpeakerProfile(
            id: UUID(), name: "Alice", embeddings: [],
            firstSeen: Date(), lastSeen: Date(), meetingCount: 1
        ))
        try expectEqual(store.speakers.count, 1)
        try expectEqual(store.speakers.first?.name, "Alice")

        // Reload
        let store2 = SpeakerStore(url: url)
        try expectEqual(store2.speakers.count, 1)
    }

    test("SpeakerStore rename") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SpeakerStore(url: tmpDir.appendingPathComponent("speakers.json"))
        let id = UUID()
        store.upsert(SpeakerProfile(
            id: id, name: "Speaker 1", embeddings: [],
            firstSeen: Date(), lastSeen: Date(), meetingCount: 1
        ))
        store.rename(id: id, to: "Bob")
        try expectEqual(store.speakers.first?.name, "Bob")
    }

    test("SpeakerStore merge") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SpeakerStore(url: tmpDir.appendingPathComponent("speakers.json"))
        let id1 = UUID(), id2 = UUID()
        store.upsert(SpeakerProfile(id: id1, name: "Alice", embeddings: [[1, 0]], firstSeen: Date(), lastSeen: Date(), meetingCount: 3))
        store.upsert(SpeakerProfile(id: id2, name: "Dup", embeddings: [[0, 1]], firstSeen: Date(), lastSeen: Date(), meetingCount: 2))
        store.merge(primaryID: id1, secondaryID: id2)
        try expectEqual(store.speakers.count, 1)
        try expectEqual(store.speakers.first?.meetingCount, 5)
        try expectEqual(store.speakers.first?.embeddings.count, 2)
    }

    test("SpeakerStore delete") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SpeakerStore(url: tmpDir.appendingPathComponent("speakers.json"))
        let id = UUID()
        store.upsert(SpeakerProfile(id: id, name: "Alice", embeddings: [], firstSeen: Date(), lastSeen: Date(), meetingCount: 1))
        store.delete(id: id)
        try expect(store.speakers.isEmpty)
    }

    test("PipelineQueueStore enqueue and retrieve") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = PipelineQueueStore(url: tmpDir.appendingPathComponent("queue.json"))
        store.enqueue(PipelineJob(
            id: UUID(), meetingTitle: "Sprint",
            startTime: Date(), endTime: Date(),
            appAudioPath: URL(fileURLWithPath: "/tmp/a.wav"),
            micAudioPath: URL(fileURLWithPath: "/tmp/b.wav"),
            transcriptPath: nil, stage: .queued,
            stageStartTime: nil, error: nil, retryCount: 0
        ))
        try expectEqual(store.jobs.count, 1)
        try expectEqual(store.activeJob?.meetingTitle, "Sprint")
    }

    test("PipelineQueueStore recent jobs limited to 3") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = PipelineQueueStore(url: tmpDir.appendingPathComponent("queue.json"))
        for i in 0..<5 {
            store.enqueue(PipelineJob(
                id: UUID(), meetingTitle: "M\(i)",
                startTime: Date().addingTimeInterval(TimeInterval(i)),
                endTime: Date().addingTimeInterval(TimeInterval(i + 1)),
                appAudioPath: URL(fileURLWithPath: "/tmp/\(i).wav"),
                micAudioPath: URL(fileURLWithPath: "/tmp/\(i)m.wav"),
                transcriptPath: nil, stage: .complete,
                stageStartTime: nil, error: nil, retryCount: 0
            ))
        }
        try expectEqual(store.recentJobs.count, 3)
    }
}

// MARK: - Pipeline Resume / Recovery Tests

@MainActor private func makeQueueStore() throws -> (PipelineQueueStore, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeardTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let url = tmpDir.appendingPathComponent("queue.json")
    return (PipelineQueueStore(url: url), url)
}

private func makeJob(
    stage: PipelineStage,
    error: String? = nil,
    retryCount: Int = 0,
    endOffset: TimeInterval = 0,
    title: String = "Meeting"
) -> PipelineJob {
    PipelineJob(
        id: UUID(),
        meetingTitle: title,
        startTime: Date(),
        endTime: Date().addingTimeInterval(endOffset),
        appAudioPath: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)_app.wav"),
        micAudioPath: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)_mic.wav"),
        transcriptPath: nil,
        stage: stage,
        stageStartTime: stage == .queued ? nil : Date(),
        error: error,
        retryCount: retryCount,
        rosterNames: []
    )
}

@MainActor func runPipelineResumeTests() {
    print("\n🔁 Pipeline Resume Tests")

    test("prepareForResume requeues failed jobs and clears error") {
        let (store, _) = try makeQueueStore()
        let job = makeJob(stage: .failed, error: "oops", retryCount: 2)
        store.enqueue(job)

        let changed = store.prepareForResume()

        try expectEqual(changed.count, 1)
        try expectEqual(changed.first, job.id)
        try expectEqual(store.jobs.first?.stage, .queued)
        try expect(store.jobs.first?.error == nil)
    }

    test("prepareForResume preserves retryCount so ceiling still applies") {
        let (store, _) = try makeQueueStore()
        store.enqueue(makeJob(stage: .failed, error: "oops", retryCount: 2))
        store.prepareForResume()
        try expectEqual(store.jobs.first?.retryCount, 2)
    }

    test("prepareForResume leaves complete and queued jobs untouched") {
        let (store, _) = try makeQueueStore()
        let done = makeJob(stage: .complete)
        let queued = makeJob(stage: .queued)
        store.enqueue(done)
        store.enqueue(queued)

        let changed = store.prepareForResume()

        try expect(changed.isEmpty)
        try expectEqual(store.jobs.first(where: { $0.id == done.id })?.stage, .complete)
        try expectEqual(store.jobs.first(where: { $0.id == queued.id })?.stage, .queued)
    }

    test("prepareForResume requeues mid-stage jobs orphaned by a crash") {
        let (store, _) = try makeQueueStore()
        let midStages: [PipelineStage] = [.preprocessing, .transcribing, .diarizing, .assigning]
        for stage in midStages {
            store.enqueue(makeJob(stage: stage))
        }

        let changed = store.prepareForResume()

        try expectEqual(changed.count, midStages.count)
        try expectEqual(store.jobs.filter { $0.stage == .queued }.count, midStages.count)
        try expect(store.jobs.allSatisfy { $0.stageStartTime == nil })
    }

    test("prepareForResume preserves retryCount when requeuing mid-stage jobs") {
        let (store, _) = try makeQueueStore()
        store.enqueue(makeJob(stage: .transcribing, retryCount: 2))
        store.prepareForResume()
        try expectEqual(store.jobs.first?.retryCount, 2)
    }

    test("prepareForResume persists across reload") {
        let (store, url) = try makeQueueStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.enqueue(makeJob(stage: .failed, error: "oops", retryCount: 1))
        store.prepareForResume()

        let reloaded = PipelineQueueStore(url: url)
        try expectEqual(reloaded.jobs.first?.stage, .queued)
        try expect(reloaded.jobs.first?.error == nil)
        try expectEqual(reloaded.jobs.first?.retryCount, 1)
    }

    test("prepareForResume with no failed jobs does not rewrite file") {
        let (store, url) = try makeQueueStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.enqueue(makeJob(stage: .complete))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)

        let changed = store.prepareForResume()

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try expect(changed.isEmpty)
        try expectEqual(before, after)
    }

    test("activeJob skips complete but returns failed and mid-stage jobs") {
        let (store, _) = try makeQueueStore()
        store.enqueue(makeJob(stage: .complete))
        let failed = makeJob(stage: .failed)
        store.enqueue(failed)
        try expectEqual(store.activeJob?.id, failed.id)
    }

    test("activeJob returns first non-complete in insertion order") {
        let (store, _) = try makeQueueStore()
        store.enqueue(makeJob(stage: .complete))
        let first = makeJob(stage: .queued)
        let second = makeJob(stage: .failed)
        store.enqueue(first)
        store.enqueue(second)
        try expectEqual(store.activeJob?.id, first.id)
    }

    test("Queue survives full round-trip with error and retryCount") {
        let (store, url) = try makeQueueStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var job = makeJob(stage: .transcribing, error: "network blip", retryCount: 1)
        job.meetingTitle = "Standup"
        store.enqueue(job)

        let reloaded = PipelineQueueStore(url: url)
        try expectEqual(reloaded.jobs.count, 1)
        let got = try XCTUnwrap(reloaded.jobs.first)
        try expectEqual(got.stage, .transcribing)
        try expectEqual(got.error, "network blip")
        try expectEqual(got.retryCount, 1)
        try expectEqual(got.meetingTitle, "Standup")
    }

    test("PipelineError.noAudioFiles is non-retryable") {
        try expect(PipelineError.noAudioFiles.isNonRetryable)
    }

    test("PipelineError.recordingTooShort is non-retryable") {
        try expect(PipelineError.recordingTooShort.isNonRetryable)
    }
}

private func XCTUnwrap<T>(_ value: T?, _ message: String = "Unexpectedly nil") throws -> T {
    guard let v = value else { throw TestFailure(message) }
    return v
}

// MARK: - Meeting Detection State Machine Tests

func runMeetingDetectionTests() {
    print("\n🕵️  Meeting Detection State Machine Tests")

    let t0 = Date(timeIntervalSince1970: 1_000_000)

    test("Single positive detection does not start a meeting (debounce)") {
        var state = MeetingDetectionState()
        let action = state.step(now: t0, detected: true)
        try expectEqual(action, .ignore)
        try expectEqual(state.consecutiveDetections, 1)
        try expect(!state.hasActiveSnapshot)
    }

    test("Two consecutive detections start a meeting") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        let action = state.step(now: t0.addingTimeInterval(3), detected: true)
        try expectEqual(action, .startMeeting)
        try expect(state.hasActiveSnapshot)
    }

    test("A negative poll between positives resets the debounce counter") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        _ = state.step(now: t0.addingTimeInterval(3), detected: false)
        let action = state.step(now: t0.addingTimeInterval(6), detected: true)
        try expectEqual(action, .ignore, "Second positive should be the new 'first' — not yet a start")
        try expectEqual(state.consecutiveDetections, 1)
    }

    test("While active, further positives do not re-fire start") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        _ = state.step(now: t0.addingTimeInterval(3), detected: true)  // start
        let action = state.step(now: t0.addingTimeInterval(6), detected: true)
        try expectEqual(action, .ignore)
        try expect(state.hasActiveSnapshot)
    }

    test("Negative poll while active fires endMeeting") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        _ = state.step(now: t0.addingTimeInterval(3), detected: true)
        let action = state.step(now: t0.addingTimeInterval(6), detected: false)
        try expectEqual(action, .endMeeting)
        try expect(!state.hasActiveSnapshot)
    }

    test("Negative poll while idle is ignored") {
        var state = MeetingDetectionState()
        let action = state.step(now: t0, detected: false)
        try expectEqual(action, .ignore)
    }

    test("Cooldown blocks re-detection immediately after endMeeting") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        _ = state.step(now: t0.addingTimeInterval(3), detected: true)  // start
        _ = state.step(now: t0.addingTimeInterval(6), detected: false) // end → cooldown

        // 3s after end — still inside 5s cooldown window. Two positives would
        // normally start a meeting, but both must be ignored.
        let inCooldown1 = state.step(now: t0.addingTimeInterval(9), detected: true)
        let inCooldown2 = state.step(now: t0.addingTimeInterval(9.5), detected: true)
        try expectEqual(inCooldown1, .ignore)
        try expectEqual(inCooldown2, .ignore)
        try expectEqual(state.consecutiveDetections, 0, "Counter should not advance while in cooldown")
    }

    test("After cooldown expires, detection can start a new meeting") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: true)
        _ = state.step(now: t0.addingTimeInterval(3), detected: true)
        _ = state.step(now: t0.addingTimeInterval(6), detected: false) // cooldown until t0+11

        // First poll past cooldown boundary — clears cooldown but still requires debounce.
        let past = state.step(now: t0.addingTimeInterval(12), detected: true)
        try expectEqual(past, .ignore)
        let second = state.step(now: t0.addingTimeInterval(15), detected: true)
        try expectEqual(second, .startMeeting)
    }

    test("Cooldown boundary is exclusive — exact equality is still in cooldown") {
        var state = MeetingDetectionState()
        state.hasActiveSnapshot = true
        state.consecutiveDetections = 2
        _ = state.step(now: t0, detected: false) // sets cooldownUntil = t0 + 5

        // At exactly t0+5, `now < cooldown` is false → cooldown cleared.
        let atBoundary = state.step(now: t0.addingTimeInterval(5), detected: true)
        try expectEqual(atBoundary, .ignore)
        try expectEqual(state.consecutiveDetections, 1, "Counter advances at boundary")
    }

    test("Flapping positives (miss, hit, hit) requires fresh debounce") {
        var state = MeetingDetectionState()
        _ = state.step(now: t0, detected: false)      // idle
        _ = state.step(now: t0.addingTimeInterval(3), detected: true)
        let action = state.step(now: t0.addingTimeInterval(6), detected: true)
        try expectEqual(action, .startMeeting, "Two in a row from idle is enough to start")
    }

    test("End without active snapshot does not fire endMeeting") {
        var state = MeetingDetectionState(consecutiveDetections: 1)
        let action = state.step(now: t0, detected: false)
        try expectEqual(action, .ignore)
        try expectEqual(state.consecutiveDetections, 0, "Counter still resets to 0")
        try expect(state.cooldownUntil == nil, "No cooldown set when no meeting was active")
    }

    test("Full meeting lifecycle start → end → new start") {
        var state = MeetingDetectionState()
        // Meeting 1
        try expectEqual(state.step(now: t0, detected: true), .ignore)
        try expectEqual(state.step(now: t0.addingTimeInterval(3), detected: true), .startMeeting)
        try expectEqual(state.step(now: t0.addingTimeInterval(60), detected: false), .endMeeting)

        // Cooldown expires
        try expectEqual(state.step(now: t0.addingTimeInterval(70), detected: true), .ignore)
        try expectEqual(state.step(now: t0.addingTimeInterval(73), detected: true), .startMeeting)
        try expect(state.hasActiveSnapshot)
    }
}

// MARK: - MeetingDetector (live) Tests

@MainActor func runMeetingDetectorLifecycleTests() {
    print("\n🛑 MeetingDetector Lifecycle Tests")

    test("stopWatching with active simulated meeting fires onMeetingEnded") {
        var startedTitles: [String] = []
        var endedTitles: [String] = []
        let detector = MeetingDetector(
            onMeetingStarted: { startedTitles.append($0.title) },
            onMeetingEnded: { endedTitles.append($0.title) }
        )

        detector.startWatching()
        detector.simulateMeetingStart(title: "Standup")
        try expectEqual(startedTitles, ["Standup"])
        try expectEqual(endedTitles, [])

        detector.stopWatching()
        try expectEqual(endedTitles, ["Standup"], "stopWatching must end the active meeting")
        try expect(!detector.isWatching)
    }

    test("stopWatching with no active meeting does not fire onMeetingEnded") {
        var endedTitles: [String] = []
        let detector = MeetingDetector(
            onMeetingStarted: { _ in },
            onMeetingEnded: { endedTitles.append($0.title) }
        )

        detector.startWatching()
        detector.stopWatching()
        try expectEqual(endedTitles, [])
    }

    test("Restarting after stopWatching mid-meeting does not double-end") {
        var endedTitles: [String] = []
        let detector = MeetingDetector(
            onMeetingStarted: { _ in },
            onMeetingEnded: { endedTitles.append($0.title) }
        )

        detector.startWatching()
        detector.simulateMeetingStart(title: "Sync")
        detector.stopWatching()
        try expectEqual(endedTitles, ["Sync"])

        // A subsequent stopWatching is a no-op.
        detector.stopWatching()
        try expectEqual(endedTitles, ["Sync"])
    }
}

// MARK: - Retry Executor Tests

/// Fake failures for testing the retry machinery.
private struct FakeFailure: Error {
    let message: String
    init(_ message: String = "boom") { self.message = message }
}

@MainActor func runRetryExecutorTests() async {
    print("\n🔂 Retry Executor Tests")

    let noSleep: (TimeInterval) async throws -> Void = { _ in }

    await testAsync("Success on first try preserves stage and touches nothing") {
        var job = makeJob(stage: .queued)
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { updates.append($0) },
            sleep: noSleep,
            process: { j in j.stage = .complete }
        )
        try expectEqual(job.stage, .complete)
        try expectEqual(job.retryCount, 0)
        try expect(job.error == nil)
        try expect(updates.isEmpty, "No updates should be persisted on clean success")
    }

    await testAsync("Retryable error then success resets error and increments retryCount") {
        var job = makeJob(stage: .queued)
        var attempts = 0
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { updates.append($0) },
            sleep: noSleep,
            process: { j in
                attempts += 1
                if attempts == 1 {
                    j.stage = .transcribing
                    throw FakeFailure("transient")
                }
                j.stage = .complete
            }
        )
        try expectEqual(attempts, 2)
        try expectEqual(job.stage, .complete)
        try expectEqual(updates.count, 1, "One persist for the intermediate failure")
        try expectEqual(updates[0].retryCount, 1)
        try expect(updates[0].error != nil)
    }

    await testAsync("Retryable error exhausts retries and lands in .failed") {
        var job = makeJob(stage: .queued)
        var sleeps: [TimeInterval] = []
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { updates.append($0) },
            sleep: { sleeps.append($0) },
            process: { _ in throw FakeFailure() }
        )
        try expectEqual(job.stage, .failed)
        try expectEqual(job.retryCount, 3)
        try expect(job.error != nil)
        try expectEqual(sleeps, [1, 2], "Sleeps between attempts, none after final")
        // Each of the 3 attempts persists once with incrementing retryCount; the
        // final attempt also persists a second time after flipping stage to .failed.
        try expectEqual(updates.count, 4)
        try expectEqual(updates.last?.stage, .failed)
        try expectEqual(updates.map(\.retryCount), [1, 2, 3, 3])
    }

    await testAsync("Non-retryable error fails immediately with retryCount=1") {
        var job = makeJob(stage: .queued)
        var attempts = 0
        var sleeps: [TimeInterval] = []
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in true },
            onUpdate: { updates.append($0) },
            sleep: { sleeps.append($0) },
            process: { _ in
                attempts += 1
                throw FakeFailure("permanent")
            }
        )
        try expectEqual(attempts, 1)
        try expectEqual(job.stage, .failed)
        try expectEqual(job.retryCount, 1)
        try expect(sleeps.isEmpty, "No retry sleep for non-retryable error")
        try expectEqual(updates.count, 1)
    }

    await testAsync("CancellationError returns silently, no stage change, no persist") {
        var job = makeJob(stage: .transcribing)
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { updates.append($0) },
            sleep: noSleep,
            process: { _ in throw CancellationError() }
        )
        try expectEqual(job.stage, .transcribing, "Stage not modified on cancellation")
        try expectEqual(job.retryCount, 0)
        try expect(updates.isEmpty)
    }

    await testAsync("Retry resumes from whatever stage process left the job at") {
        // Simulates a crash/failure partway through. process() advances the stage
        // before failing, and the retry re-enters with that stage.
        var job = makeJob(stage: .queued)
        var stagesSeen: [PipelineStage] = []
        var attempts = 0
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            retryDelays: [0, 0, 0],
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: noSleep,
            process: { j in
                attempts += 1
                stagesSeen.append(j.stage)
                if attempts == 1 {
                    j.stage = .transcribing
                    throw FakeFailure()
                }
                j.stage = .complete
            }
        )
        try expectEqual(stagesSeen, [.queued, .transcribing])
        try expectEqual(job.stage, .complete)
    }

    await testAsync("retryDelays clamps when more attempts than delay entries") {
        var job = makeJob(stage: .queued)
        var sleeps: [TimeInterval] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 5,
            retryDelays: [1, 2], // only 2 delays for 4 retries
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: { sleeps.append($0) },
            process: { _ in throw FakeFailure() }
        )
        try expectEqual(sleeps, [1, 2, 2, 2], "Last delay is reused after exhaustion")
    }
}

// MARK: - SpeakerMatcher Threshold Edge Cases

func runSpeakerMatcherEdgeTests() {
    print("\n🎯 SpeakerMatcher Threshold Edge Cases")

    func profile(_ name: String, _ vectors: [[Float]]) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(), name: name, embeddings: vectors,
            firstSeen: Date(), lastSeen: Date(), meetingCount: 1
        )
    }

    // Build a vector at a specified cosine distance from a reference unit vector.
    // For unit vectors, cosine distance = 1 - cos(theta). We rotate in a 2D subspace.
    func vector(atDistance d: Float, from reference: [Float]) -> [Float] {
        // reference is assumed unit-norm along axis 0: [1, 0, 0, ...].
        let cosTheta = 1 - d
        let sinTheta = (1 - cosTheta * cosTheta).squareRoot()
        var v = [Float](repeating: 0, count: reference.count)
        v[0] = cosTheta
        v[1] = sinTheta
        return v
    }

    let ref: [Float] = [1, 0, 0, 0, 0]

    test("Distance just above matchThreshold (0.40) → no match") {
        let bob = profile("Bob", [ref])
        let probe = vector(atDistance: 0.41, from: ref)
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: probe)],
            database: [bob],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Speaker 1")
        try expect(result[0].isNewSpeaker)
    }

    test("Distance just below matchThreshold with clear margin → match") {
        let bob = profile("Bob", [ref])
        let probe = vector(atDistance: 0.20, from: ref) // well below 0.40
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: probe)],
            database: [bob],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Bob")
        try expect(!result[0].isNewSpeaker)
    }

    test("Two close candidates (margin < 0.10) treated as ambiguous → no match") {
        // Two speakers whose stored embeddings sit on either side of the probe,
        // at distances 0.20 and 0.25. Margin = 0.05 < confidenceMargin (0.10).
        let bob = profile("Bob", [vector(atDistance: 0.20, from: ref)])
        let alice = profile("Alice", [vector(atDistance: 0.25, from: ref)])
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: ref)],
            database: [bob, alice],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Speaker 1")
        try expect(result[0].isNewSpeaker, "Ambiguous match must be treated as a new speaker")
    }

    test("Two candidates with clear margin → best wins") {
        let bob = profile("Bob", [vector(atDistance: 0.10, from: ref)])
        let alice = profile("Alice", [vector(atDistance: 0.35, from: ref)])
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: ref)],
            database: [bob, alice],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Bob")
    }

    test("Second detected speaker cannot claim an already-used profile") {
        // Both probes best-match Bob. First gets assigned; second must fall back.
        let bob = profile("Bob", [ref])
        let probe1 = vector(atDistance: 0.10, from: ref)
        let probe2 = vector(atDistance: 0.15, from: ref)
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [
                SpeakerEmbedding(speakerID: "R_0", vector: probe1),
                SpeakerEmbedding(speakerID: "R_1", vector: probe2),
            ],
            database: [bob],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Bob")
        try expectEqual(result[1].assignedName, "Speaker 1")
        try expect(result[1].isNewSpeaker)
    }

    test("Profile with multiple embeddings uses best (min distance)") {
        // Bob has one embedding far away and one nearby. Probe matches the nearby one.
        let far = vector(atDistance: 0.50, from: ref)
        let near = vector(atDistance: 0.15, from: ref)
        let bob = profile("Bob", [far, near])
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: ref)],
            database: [bob],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Bob")
    }

    test("Profile with empty embeddings is skipped") {
        let empty = profile("Ghost", [])
        let bob = profile("Bob", [vector(atDistance: 0.15, from: ref)])
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: ref)],
            database: [empty, bob],
            localUserName: "Me"
        )
        try expectEqual(result[0].assignedName, "Bob")
    }

    test("Single candidate above threshold → no match even without competitors") {
        // With only one candidate, secondBest is infinity so margin is infinite.
        // But the distance itself is > threshold, so still no match.
        let bob = profile("Bob", [vector(atDistance: 0.50, from: ref)])
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: ref)],
            database: [bob],
            localUserName: "Me"
        )
        try expect(result[0].isNewSpeaker)
    }
}

// MARK: - RosterReader Tests

func runRosterReaderTests() {
    print("\n👥 RosterReader Tests")

    test("Window title with two names parses to a list") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice, Bob | Microsoft Teams")
        try expectEqual(names, ["Alice", "Bob"])
    }

    test("Window title with three names parses all") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice Smith, Bob Jones, Carol Liu | Microsoft Teams")
        try expectEqual(names, ["Alice Smith", "Bob Jones", "Carol Liu"])
    }

    test("Window title with trailing modifier still parses") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice, Bob | Microsoft Teams (Preview)")
        try expectEqual(names, ["Alice", "Bob"])
    }

    test("Window title without comma has no participants") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Sprint Planning | Microsoft Teams")
        try expect(names.isEmpty)
    }

    test("Window title without Teams suffix yields nothing") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice, Bob | Zoom")
        try expect(names.isEmpty)
    }

    test("Window title with single name ignored (need ≥ 2)") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice | Microsoft Teams")
        try expect(names.isEmpty)
    }

    test("Window title collapses whitespace around commas") {
        let names = RosterReader.parseParticipantsFromWindowTitle("  Alice ,   Bob   | Microsoft Teams")
        try expectEqual(names, ["Alice", "Bob"])
    }

    test("Window title drops single-character fragments") {
        let names = RosterReader.parseParticipantsFromWindowTitle("Alice, B, Carol | Microsoft Teams")
        try expectEqual(names, ["Alice", "Carol"])
    }

    test("filterNames drops UI control strings") {
        let raw = ["Alice", "Mute", "Bob", "Raise hand", "People"]
        let filtered = RosterReader.filterNamesForTesting(raw)
        try expectEqual(filtered, ["Alice", "Bob"])
    }

    test("filterNames drops too-short and too-long entries") {
        let raw = ["A", "Bo", String(repeating: "x", count: 61), "Carol"]
        let filtered = RosterReader.filterNamesForTesting(raw)
        try expectEqual(filtered, ["Bo", "Carol"])
    }

    test("filterNames deduplicates case-insensitively") {
        let raw = ["Alice", "alice", "ALICE", "Bob"]
        let filtered = RosterReader.filterNamesForTesting(raw)
        try expectEqual(filtered, ["Alice", "Bob"])
    }

    test("filterNames drops 'Button ...' and 'Icon ...' prefixes") {
        let raw = ["Alice", "Button More", "Icon Teams", "Bob"]
        let filtered = RosterReader.filterNamesForTesting(raw)
        try expectEqual(filtered, ["Alice", "Bob"])
    }

    test("filterNames preserves order of first occurrence") {
        let raw = ["Zach", "Alice", "Zach", "Bob"]
        let filtered = RosterReader.filterNamesForTesting(raw)
        try expectEqual(filtered, ["Zach", "Alice", "Bob"])
    }
}

// MARK: - Main

@main
struct TestRunner {
    @MainActor static func main() async {
        print("🧪 Heard Tests\n")

        runVadSegmentMapTests()
        runSpeakerMatcherTests()
        runSegmentMergerTests()
        runAudioPreprocessorTests()
        runTranscriptWriterTests()
        runStoreTests()
        runPipelineResumeTests()
        runMeetingDetectionTests()
        runMeetingDetectorLifecycleTests()
        await runRetryExecutorTests()
        runSpeakerMatcherEdgeTests()
        runRosterReaderTests()

        print("\n" + String(repeating: "─", count: 50))
        print("Results: \(passedTests)/\(totalTests) passed")
        if !failedTests.isEmpty {
            print("\nFailed:")
            for (name, error) in failedTests {
                print("  ✗ \(name): \(error)")
            }
            exit(1)
        } else {
            print("✅ All tests passed!")
        }
    }
}
