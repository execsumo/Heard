import Foundation
import LurkCore

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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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
            .appendingPathComponent("LurkTests-\(UUID().uuidString)")
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

// MARK: - Main

@main
struct TestRunner {
    @MainActor static func main() {
        print("🧪 Lurk Tests\n")

        runVadSegmentMapTests()
        runSpeakerMatcherTests()
        runSegmentMergerTests()
        runAudioPreprocessorTests()
        runTranscriptWriterTests()
        runStoreTests()

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
