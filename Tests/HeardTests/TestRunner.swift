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

func unwrap<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) throws -> T {
    guard let value else {
        throw TestFailure(message.isEmpty ? "Expected non-nil value at \(file):\(line)" : message)
    }
    return value
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
        try expect(results[0].assignedName.hasPrefix("Speaker_"))
        try expect(results[1].assignedName.hasPrefix("Speaker_"))
        try expect(results[0].isNewSpeaker)
    }

    test("startingSpeakerNumber offsets unknown labels") {
        let embeddings = [
            SpeakerEmbedding(speakerID: "R_0", vector: [1, 0, 0]),
            SpeakerEmbedding(speakerID: "R_1", vector: [0, 1, 0]),
        ]
        let results = SpeakerMatcher.matchSpeakers(
            embeddings: embeddings,
            database: [],
            localUserName: "Me"
        )
        try expectEqual(results.count, 2)
        try expect(results[0].assignedName.hasPrefix("Speaker_"))
        try expect(results[1].assignedName.hasPrefix("Speaker_"))
    }

    test("Unknown speakers get unique UUID labels") {
        let embeddings = [SpeakerEmbedding(speakerID: "R_0", vector: [1, 0, 0])]
        let results = SpeakerMatcher.matchSpeakers(
            embeddings: embeddings,
            database: [],
            localUserName: "Me"
        )
        try expect(results[0].assignedName.hasPrefix("Speaker_"))
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
        try expect(results[0].assignedName.hasPrefix("Speaker_"))
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

// MARK: - AudioClipExtractor Tests

func runAudioClipExtractorTests() {
    print("\n🔊 AudioClipExtractor Tests")

    test("Clip regions are constrained to VAD speech islands") {
        let regions = AudioClipExtractor.bestClipRegions(
            speakerID: "S1",
            diarizationSegments: [
                (speakerID: "S1", startTime: 0, endTime: 12),
            ],
            speechSegments: [
                (startTime: 0, endTime: 4),
                (startTime: 9, endTime: 12),
            ],
            maxCount: 3
        )

        try expectEqual(regions.count, 2)
        try expectClose(regions[0].startTime, 0)
        try expectClose(regions[0].endTime, 4)
        try expectClose(regions[1].startTime, 9)
        try expectClose(regions[1].endTime, 12)
    }

    test("Long speech island is centered and capped at max duration") {
        let regions = AudioClipExtractor.bestClipRegions(
            speakerID: "S1",
            diarizationSegments: [
                (speakerID: "S1", startTime: 0, endTime: 30),
            ],
            speechSegments: [
                (startTime: 3, endTime: 23),
            ],
            maxCount: 1
        )

        try expectEqual(regions.count, 1)
        try expectClose(regions[0].startTime, 8)
        try expectClose(regions[0].endTime, 18)
    }

    test("VAD mode does not combine short fragments across silence") {
        let regions = AudioClipExtractor.bestClipRegions(
            speakerID: "S1",
            diarizationSegments: [
                (speakerID: "S1", startTime: 0, endTime: 8),
            ],
            speechSegments: [
                (startTime: 0, endTime: 0.7),
                (startTime: 5, endTime: 5.8),
            ],
            maxCount: 1
        )

        try expect(regions.isEmpty)
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

    test("renameSpeakerInDirectory rewrites every matching transcript") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let date = Date()
        let docA = TranscriptDocument(
            title: "Standup", startTime: date, endTime: date.addingTimeInterval(60),
            participants: ["Speaker 7", "Me"],
            segments: [
                TranscriptSegment(speaker: "Speaker 7", startTime: 0, endTime: 30, text: "Morning."),
                TranscriptSegment(speaker: "Me", startTime: 30, endTime: 60, text: "Hi."),
            ]
        )
        let docB = TranscriptDocument(
            title: "Retro", startTime: date, endTime: date.addingTimeInterval(60),
            participants: ["Speaker 7", "Alice"],
            segments: [
                TranscriptSegment(speaker: "Speaker 7", startTime: 0, endTime: 30, text: "Hey."),
            ]
        )
        let docC = TranscriptDocument(
            title: "Other", startTime: date, endTime: date.addingTimeInterval(60),
            participants: ["Speaker 8"],
            segments: [TranscriptSegment(speaker: "Speaker 8", startTime: 0, endTime: 30, text: "Unrelated.")]
        )
        let urlA = try TranscriptWriter.write(document: docA, outputDirectory: tmpDir)
        let urlB = try TranscriptWriter.write(document: docB, outputDirectory: tmpDir)
        let urlC = try TranscriptWriter.write(document: docC, outputDirectory: tmpDir)

        TranscriptWriter.renameSpeakerInDirectory(tmpDir, from: "Speaker 7", to: "Bob")

        let a = try String(contentsOf: urlA, encoding: .utf8)
        let b = try String(contentsOf: urlB, encoding: .utf8)
        let c = try String(contentsOf: urlC, encoding: .utf8)
        try expect(a.contains("**Bob:**"), "A should reference Bob")
        try expect(!a.contains("**Speaker 7:**"), "A should not reference Speaker 7")
        try expect(b.contains("**Bob:**"), "B should reference Bob")
        try expect(!b.contains("**Speaker 7:**"), "B should not reference Speaker 7")
        try expect(c.contains("**Speaker 8:**"), "C should be untouched")
    }

    test("renameSpeakerInDirectory rewrites the production Speaker_<hex> placeholder") {
        // Production places `Speaker_<6 hex chars>` in transcripts when a new speaker
        // is detected and the user hasn't named them yet. The legacy "Speaker 7" test
        // covers the basic logic; this one pins down the underscore-based format the
        // pipeline actually emits so any regression there is caught immediately.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let date = Date()
        let doc = TranscriptDocument(
            title: "Roadmap",
            startTime: date,
            endTime: date.addingTimeInterval(120),
            participants: ["Speaker_ABC123", "Speaker_DEF456", "Me"],
            segments: [
                TranscriptSegment(speaker: "Speaker_ABC123", startTime: 0, endTime: 30,
                                  text: "Welcome to the meeting."),
                TranscriptSegment(speaker: "Speaker_DEF456", startTime: 30, endTime: 60,
                                  text: "Glad to be here."),
                TranscriptSegment(speaker: "Me", startTime: 60, endTime: 90, text: "Hi."),
            ]
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)

        TranscriptWriter.renameSpeakerInDirectory(tmpDir, from: "Speaker_ABC123", to: "Alice")

        let content = try String(contentsOf: url, encoding: .utf8)
        try expect(content.contains("**Alice:** Welcome to the meeting."),
                   "Body line should be rewritten to Alice")
        try expect(!content.contains("Speaker_ABC123"),
                   "Placeholder must be fully gone from body and participants header")
        try expect(content.contains("**Speaker_DEF456:** Glad to be here."),
                   "Other placeholders must be left untouched")
        try expect(content.contains("Alice"), "Participants header should include Alice")
    }

    test("renameSpeaker rewrites a transcript outside the configured output directory") {
        // Simulates the popup-after-meeting case where `candidate.transcriptPath`
        // points at a file the directory scan would miss — e.g. because the user
        // moved their output folder between meetings. The unconditional path-based
        // pass in `saveSpeakerName` should still rewrite the file.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let date = Date()
        let doc = TranscriptDocument(
            title: "Standup",
            startTime: date,
            endTime: date.addingTimeInterval(60),
            participants: ["Speaker_ABC123", "Me"],
            segments: [
                TranscriptSegment(speaker: "Speaker_ABC123", startTime: 0, endTime: 30,
                                  text: "Morning."),
            ]
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)

        TranscriptWriter.renameSpeaker(in: url, from: "Speaker_ABC123", to: "Bob")

        let content = try String(contentsOf: url, encoding: .utf8)
        try expect(content.contains("**Bob:** Morning."), "Body line should now reference Bob")
        try expect(!content.contains("Speaker_ABC123"),
                   "Placeholder should be gone from body and participants header")
    }

    test("renameSpeaker is idempotent — second pass is a no-op") {
        // We deliberately invoke `renameSpeaker` multiple times from `saveSpeakerName`
        // (directory scan + queue scan + explicit path) to make sure the rename actually
        // lands. This relies on the function being safe to run again after a successful
        // rename, since after the first pass the placeholder is gone.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "Standup", startTime: Date(), endTime: Date().addingTimeInterval(60),
            participants: ["Speaker_1AB23C", "Me"],
            segments: [TranscriptSegment(speaker: "Speaker_1AB23C", startTime: 0, endTime: 30,
                                         text: "Hello.")]
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)

        TranscriptWriter.renameSpeaker(in: url, from: "Speaker_1AB23C", to: "Carol")
        let afterFirst = try String(contentsOf: url, encoding: .utf8)
        TranscriptWriter.renameSpeaker(in: url, from: "Speaker_1AB23C", to: "Carol")
        let afterSecond = try String(contentsOf: url, encoding: .utf8)

        try expect(afterFirst.contains("**Carol:** Hello."), "First pass rewrites Carol")
        try expectEqual(afterFirst, afterSecond)
    }

    test("renameSpeakerInDirectory ignores non-md files and missing dirs") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let txt = tmpDir.appendingPathComponent("notes.txt")
        try "**Speaker 7:** hello".write(to: txt, atomically: true, encoding: .utf8)

        TranscriptWriter.renameSpeakerInDirectory(tmpDir, from: "Speaker 7", to: "Bob")
        let after = try String(contentsOf: txt, encoding: .utf8)
        try expect(after.contains("**Speaker 7:**"), "Non-md files must not be rewritten")

        // Missing directory must not crash.
        let missing = tmpDir.appendingPathComponent("does-not-exist")
        TranscriptWriter.renameSpeakerInDirectory(missing, from: "Speaker 7", to: "Bob")
    }

    test("Timestamp formatting") {
        let t1: TimeInterval = 3661
        try expectEqual(t1.timestampString, "1:01:01")
        let t2: TimeInterval = 65
        try expectEqual(t2.timestampString, "01:05")
        let t3: TimeInterval = 0
        try expectEqual(t3.timestampString, "00:00")
    }

    test("Notes are interleaved chronologically with segments") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "Q1 Review",
            startTime: Date(),
            endTime: Date().addingTimeInterval(120),
            participants: ["Alice", "Me"],
            segments: [
                TranscriptSegment(speaker: "Alice", startTime: 0, endTime: 20, text: "We saw FCR jump."),
                TranscriptSegment(speaker: "Me", startTime: 30, endTime: 60, text: "Nice work."),
            ],
            notes: [
                MeetingNote(offsetSeconds: 22, text: "FCR = First Call Resolution"),
            ],
            noteAuthor: "John"
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        let content = try String(contentsOf: url, encoding: .utf8)

        try expect(content.contains("**Note from John:** FCR = First Call Resolution"),
                   "Should render note line with attribution")
        try expect(content.contains("[00:22] _**Note from John:**"),
                   "Note timestamp uses offsetSeconds")

        // Note must appear between Alice's segment (00:00) and Me's segment (00:30)
        let aliceRange = content.range(of: "Alice:")!
        let noteRange = content.range(of: "Note from John:")!
        let meRange = content.range(of: "Me:** Nice work")!
        try expect(aliceRange.lowerBound < noteRange.lowerBound, "Note must come after Alice")
        try expect(noteRange.lowerBound < meRange.lowerBound, "Note must come before Me")
    }

    test("Notes use userName fallback when empty") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "X", startTime: Date(), endTime: Date().addingTimeInterval(60),
            participants: [],
            segments: [],
            notes: [MeetingNote(offsetSeconds: 5, text: "context")],
            noteAuthor: ""
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        let content = try String(contentsOf: url, encoding: .utf8)
        try expect(content.contains("**Note from Me:** context"), "Empty author falls back to Me")
    }

    test("Note at same timestamp as segment sorts after the segment") {
        let body = TranscriptWriter.renderBody(
            segments: [TranscriptSegment(speaker: "Alice", startTime: 10, endTime: 15, text: "Hi.")],
            notes: [MeetingNote(offsetSeconds: 10, text: "tied")],
            noteAuthor: "John"
        )
        let aliceIdx = body.range(of: "Alice:")!.lowerBound
        let noteIdx = body.range(of: "Note from John:")!.lowerBound
        try expect(aliceIdx < noteIdx, "Segment must precede same-timestamp note")
    }

    test("Empty notes array renders identical to pre-notes output") {
        let segs = [
            TranscriptSegment(speaker: "Alice", startTime: 0, endTime: 5, text: "Hello."),
            TranscriptSegment(speaker: "Bob", startTime: 5, endTime: 10, text: "Hi."),
        ]
        let body = TranscriptWriter.renderBody(segments: segs, notes: [], noteAuthor: "John")
        try expect(body.contains("**Alice:** Hello."), "Alice present")
        try expect(body.contains("**Bob:** Hi."), "Bob present")
        try expect(!body.contains("Note from"), "No note marker without notes")
    }

    test("renameSpeakerInDirectory does not mangle Note lines") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let doc = TranscriptDocument(
            title: "Standup", startTime: Date(), endTime: Date().addingTimeInterval(60),
            participants: ["Speaker 7"],
            segments: [TranscriptSegment(speaker: "Speaker 7", startTime: 0, endTime: 30, text: "Hey.")],
            notes: [MeetingNote(offsetSeconds: 10, text: "side comment")],
            noteAuthor: "John"
        )
        let url = try TranscriptWriter.write(document: doc, outputDirectory: tmpDir)
        TranscriptWriter.renameSpeakerInDirectory(tmpDir, from: "Speaker 7", to: "Bob")
        let content = try String(contentsOf: url, encoding: .utf8)
        try expect(content.contains("**Bob:** Hey."), "Speaker rename applied")
        try expect(content.contains("**Note from John:** side comment"),
                   "Note line untouched by rename")
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

    test("SpeakerStore migrates legacy bare-array file") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("speakers.json")
        let legacy = [
            SpeakerProfile(id: UUID(), name: "Alice", embeddings: [], firstSeen: Date(), lastSeen: Date(), meetingCount: 1),
            SpeakerProfile(id: UUID(), name: "Speaker 3", embeddings: [], firstSeen: Date(), lastSeen: Date(), meetingCount: 1),
            SpeakerProfile(id: UUID(), name: "Speaker 5", embeddings: [], firstSeen: Date(), lastSeen: Date(), meetingCount: 1),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: url)

        let store = SpeakerStore(url: url)
        try expectEqual(store.speakers.count, 3)
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

    test("PipelineJob persists notes across reload") {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("queue.json")
        let store = PipelineQueueStore(url: url)
        let jobID = UUID()
        store.enqueue(PipelineJob(
            id: jobID, meetingTitle: "Standup",
            startTime: Date(), endTime: Date().addingTimeInterval(60),
            appAudioPath: URL(fileURLWithPath: "/tmp/a.wav"),
            micAudioPath: URL(fileURLWithPath: "/tmp/b.wav"),
            transcriptPath: nil, stage: .queued,
            stageStartTime: nil, error: nil, retryCount: 0,
            rosterNames: [],
            notes: [
                MeetingNote(offsetSeconds: 12, text: "context A"),
                MeetingNote(offsetSeconds: 45, text: "context B"),
            ]
        ))
        let reloaded = PipelineQueueStore(url: url)
        try expectEqual(reloaded.jobs.count, 1)
        try expectEqual(reloaded.jobs.first?.notes.count, 2)
        try expectEqual(reloaded.jobs.first?.notes[0].text, "context A")
        try expectEqual(reloaded.jobs.first?.notes[1].offsetSeconds, 45)

        // Backwards compat: a queue file written without a `notes` field still decodes.
        let legacyJSON = """
        [{
          "id": "\(UUID().uuidString)",
          "meetingTitle": "Old",
          "startTime": "2026-01-01T00:00:00Z",
          "endTime": "2026-01-01T00:01:00Z",
          "appAudioPath": "file:///tmp/x.wav",
          "micAudioPath": "file:///tmp/y.wav",
          "stage": "complete",
          "retryCount": 0
        }]
        """
        let legacyURL = tmpDir.appendingPathComponent("legacy.json")
        try legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)
        let legacyStore = PipelineQueueStore(url: legacyURL)
        try expectEqual(legacyStore.jobs.count, 1)
        try expectEqual(legacyStore.jobs.first?.notes.count, 0)
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

    test("processingJob skips both complete and failed jobs") {
        let (store, _) = try makeQueueStore()
        // An old failed job ahead of an in-progress one must not block the
        // status display from showing the active job.
        store.enqueue(makeJob(stage: .failed))
        let inProgress = makeJob(stage: .diarizing)
        store.enqueue(inProgress)
        try expectEqual(store.processingJob?.id, inProgress.id)
    }

    test("processingJob is nil when only complete and failed jobs remain") {
        let (store, _) = try makeQueueStore()
        store.enqueue(makeJob(stage: .complete))
        store.enqueue(makeJob(stage: .failed))
        try expect(store.processingJob == nil)
    }

    test("processingJob includes a queued job") {
        let (store, _) = try makeQueueStore()
        let queued = makeJob(stage: .queued)
        store.enqueue(queued)
        try expectEqual(store.processingJob?.id, queued.id)
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

// MARK: - Teams Identification Tests

func runTeamsIdentificationTests() {
    print("\n🟣 Teams Identification Tests")

    test("Matches new Teams by bundle ID even with non-English name") {
        try expect(MeetingDetector.isTeamsMainApp(
            bundleID: "com.microsoft.teams2", localizedName: "Microsoft Teams 团队"))
    }

    test("Matches classic Teams by bundle ID with localized name") {
        try expect(MeetingDetector.isTeamsMainApp(
            bundleID: "com.microsoft.teams", localizedName: "Microsoft Teams (Arbeit oder Schule)"))
    }

    test("Matches by localized name when bundle ID is missing") {
        try expect(MeetingDetector.isTeamsMainApp(
            bundleID: nil, localizedName: "Microsoft Teams"))
    }

    test("Matches all three known English names") {
        try expect(MeetingDetector.isTeamsMainApp(bundleID: nil, localizedName: "Microsoft Teams"))
        try expect(MeetingDetector.isTeamsMainApp(bundleID: nil, localizedName: "Microsoft Teams classic"))
        try expect(MeetingDetector.isTeamsMainApp(
            bundleID: nil, localizedName: "Microsoft Teams (work or school)"))
    }

    test("Rejects Teams helper sub-processes") {
        try expect(!MeetingDetector.isTeamsMainApp(
            bundleID: "com.microsoft.teams2.helper", localizedName: "Microsoft Teams Helper"))
        try expect(!MeetingDetector.isTeamsMainApp(
            bundleID: "com.microsoft.teams2.helper.gpu", localizedName: "Microsoft Teams Helper (GPU)"))
    }

    test("Rejects unrelated apps") {
        try expect(!MeetingDetector.isTeamsMainApp(
            bundleID: "com.apple.Safari", localizedName: "Safari"))
        try expect(!MeetingDetector.isTeamsMainApp(bundleID: nil, localizedName: nil))
        try expect(!MeetingDetector.isTeamsMainApp(bundleID: "", localizedName: ""))
    }
}

// MARK: - Meeting App Identification Tests (Teams + Zoom + Webex)

func runMeetingAppIdentificationTests() {
    print("\n🟢 Meeting App Identification Tests")

    test("Identifies Teams from bundle ID") {
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "com.microsoft.teams2", localizedName: nil), .teams)
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "com.microsoft.teams", localizedName: nil), .teams)
    }

    test("Identifies Zoom from bundle ID") {
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "us.zoom.xos", localizedName: "zoom.us"), .zoom)
    }

    test("Identifies Webex from bundle ID") {
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "Cisco-Systems.Spark", localizedName: "Webex"), .webex)
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "com.cisco.webexmeetingsapp", localizedName: nil), .webex)
    }

    test("Rejects helper sub-processes for all sources") {
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "com.microsoft.teams2.helper", localizedName: "Microsoft Teams Helper"), nil)
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "us.zoom.xos.helper", localizedName: "Zoom Helper"), nil)
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "Cisco-Systems.Spark.helper", localizedName: nil), nil)
    }

    test("Rejects unrelated apps") {
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: "com.apple.Safari", localizedName: "Safari"), nil)
        try expectEqual(MeetingDetector.meetingAppFor(
            bundleID: nil, localizedName: nil), nil)
    }

    test("Strips Teams suffix from window title") {
        try expectEqual(MeetingDetector.cleanWindowTitle(
            "Sprint Planning | Microsoft Teams", source: .teams), "Sprint Planning")
        try expectEqual(MeetingDetector.cleanWindowTitle(
            "Alice, Bob | Microsoft Teams (Preview)", source: .teams), "Alice, Bob")
    }

    test("Strips Zoom suffix from window title") {
        try expectEqual(MeetingDetector.cleanWindowTitle(
            "Standup - Zoom Workplace", source: .zoom), "Standup")
        try expectEqual(MeetingDetector.cleanWindowTitle(
            "Q3 Review – Zoom", source: .zoom), "Q3 Review")
    }

    test("Strips Webex suffix from window title") {
        try expectEqual(MeetingDetector.cleanWindowTitle(
            "Design Sync - Webex", source: .webex), "Design Sync")
    }

    test("Rejects placeholder window titles for Zoom and Webex") {
        try expectEqual(MeetingDetector.cleanWindowTitle("Zoom Meeting", source: .zoom), nil)
        try expectEqual(MeetingDetector.cleanWindowTitle("Zoom", source: .zoom), nil)
        try expectEqual(MeetingDetector.cleanWindowTitle("Webex Meetings", source: .webex), nil)
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
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
            lifetimeRetryLimit: 100,
            retryDelays: [1, 2], // only 2 delays for 4 retries
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: { sleeps.append($0) },
            process: { _ in throw FakeFailure() }
        )
        try expectEqual(sleeps, [1, 2, 2, 2], "Last delay is reused after exhaustion")
    }

    // MARK: Lifetime retry cap

    await testAsync("retryCount increments cumulatively across simulated sessions") {
        // First session: 3 failures take retryCount 0 → 3
        var job = makeJob(stage: .queued)
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            lifetimeRetryLimit: 6,
            retryDelays: [0, 0, 0],
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: noSleep,
            process: { _ in throw FakeFailure() }
        )
        try expectEqual(job.retryCount, 3)
        try expectEqual(job.stage, .failed)

        // Second session: prepareForResume would flip .failed → .queued; simulate
        // that here. retryCount stays at 3 going in, hits 6 after three more fails.
        job.stage = .queued
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            lifetimeRetryLimit: 6,
            retryDelays: [0, 0, 0],
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: noSleep,
            process: { _ in throw FakeFailure() }
        )
        try expectEqual(job.retryCount, 6, "Cumulative across sessions, not reset")
        try expectEqual(job.stage, .failed)
    }

    await testAsync("Lifetime cap hit mid-session short-circuits remaining attempts") {
        var job = makeJob(stage: .queued)
        job.retryCount = 5 // one failure away from the cap
        var attempts = 0
        var sleeps: [TimeInterval] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            lifetimeRetryLimit: 6,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { _ in },
            sleep: { sleeps.append($0) },
            process: { _ in
                attempts += 1
                throw FakeFailure()
            }
        )
        try expectEqual(attempts, 1, "Only one attempt — cap reached, no further retries")
        try expectEqual(job.retryCount, 6)
        try expectEqual(job.stage, .failed)
        try expect(sleeps.isEmpty, "No sleep after hitting lifetime cap")
    }

    await testAsync("Job already at lifetime cap fails immediately without attempting") {
        var job = makeJob(stage: .queued)
        job.retryCount = 6
        var attempts = 0
        var updates: [PipelineJob] = []
        await PipelineProcessor.executeWithRetry(
            job: &job,
            maxRetries: 3,
            lifetimeRetryLimit: 6,
            retryDelays: [1, 2, 3],
            isNonRetryable: { _ in false },
            onUpdate: { updates.append($0) },
            sleep: noSleep,
            process: { _ in
                attempts += 1
                return
            }
        )
        try expectEqual(attempts, 0, "Process never invoked when already capped")
        try expectEqual(job.stage, .failed)
        try expectEqual(job.retryCount, 6, "retryCount unchanged")
        try expectEqual(updates.count, 1, "One persist to flip stage to .failed")
    }
}

@MainActor func runLifetimeRetryCapTests() async {
    print("\n🛑 Lifetime Retry Cap Tests")

    func queueStore() -> PipelineQueueStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heard-tests-\(UUID().uuidString).json")
        return PipelineQueueStore(url: url)
    }

    await testAsync("prepareForResume leaves jobs at lifetime cap as .failed") {
        let store = queueStore()
        var jobA = makeJob(stage: .failed)
        jobA.retryCount = PipelineProcessor.lifetimeRetryLimit // at cap
        var jobB = makeJob(stage: .failed)
        jobB.retryCount = 2 // below cap
        store.enqueue(jobA)
        store.enqueue(jobB)

        let changed = store.prepareForResume()

        let reloadedA = store.jobs.first(where: { $0.id == jobA.id })!
        let reloadedB = store.jobs.first(where: { $0.id == jobB.id })!
        try expectEqual(reloadedA.stage, .failed, "Capped job stays failed")
        try expectEqual(reloadedA.retryCount, PipelineProcessor.lifetimeRetryLimit)
        try expectEqual(reloadedB.stage, .queued, "Sub-cap job gets re-queued")
        try expectEqual(reloadedB.retryCount, 2, "retryCount preserved across resume")
        try expect(!changed.contains(jobA.id), "No change persisted for already-failed capped job")
        try expect(changed.contains(jobB.id))
    }

    await testAsync("prepareForResume marks orphaned mid-stage job past cap as .failed") {
        // A job crashed mid-transcribing and somehow its retryCount is already
        // at the cap — prepareForResume should not quietly requeue it.
        let store = queueStore()
        var job = makeJob(stage: .transcribing)
        job.retryCount = PipelineProcessor.lifetimeRetryLimit
        store.enqueue(job)

        let changed = store.prepareForResume()

        let reloaded = store.jobs.first(where: { $0.id == job.id })!
        try expectEqual(reloaded.stage, .failed)
        try expect(changed.contains(job.id), "Stage flip persisted")
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

    test("Distance well above matchThreshold (0.30) → no match") {
        let bob = profile("Bob", [ref])
        let probe = vector(atDistance: 0.41, from: ref)
        let result = SpeakerMatcher.matchSpeakers(
            embeddings: [SpeakerEmbedding(speakerID: "R_0", vector: probe)],
            database: [bob],
            localUserName: "Me"
        )
        try expect(result[0].assignedName.hasPrefix("Speaker_"))
        try expect(result[0].isNewSpeaker)
    }

    test("Distance just below matchThreshold with clear margin → match") {
        let bob = profile("Bob", [ref])
        let probe = vector(atDistance: 0.20, from: ref) // well below 0.30
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
        try expect(result[0].assignedName.hasPrefix("Speaker_"))
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
        try expect(result[1].assignedName.hasPrefix("Speaker_"))
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

// MARK: - RosterReader AX Traversal Tests (golden-file)

func runRosterReaderAXTests() {
    print("\n👥 RosterReader AX Traversal Tests")

    test("Strategy 1: finds 2 names via roster-list identifier") {
        let tree = try loadFixture("roster_2person_open.json")
        let names = RosterReader.readRosterFromNode(tree)
        try expectEqual(names.sorted(), ["Alice Smith", "Bob Jones"])
    }

    test("Strategy 1: finds 10 names via people-pane description, filters control strings") {
        let tree = try loadFixture("roster_10person_open.json")
        let names = RosterReader.readRosterFromNode(tree)
        // "People" and "Search" are filtered out by filterNames
        try expectEqual(names.count, 10)
        try expect(names.contains("Alice Smith"), "missing Alice Smith")
        try expect(names.contains("Jack Davis"),  "missing Jack Davis")
        try expect(!names.contains("People"),     "'People' should be filtered")
        try expect(!names.contains("Search"),     "'Search' should be filtered")
    }

    test("Strategy 2: falls back to AXList when no identifier matches") {
        let tree = try loadFixture("roster_axlist_fallback.json")
        let names = RosterReader.readRosterFromNode(tree)
        try expectEqual(names.sorted(), ["Alice Smith", "Bob Jones", "Carol Liu"])
    }

    test("Row containers: extracts first text child per row, ignores button labels") {
        let tree = try loadFixture("roster_row_containers.json")
        let names = RosterReader.readRosterFromNode(tree)
        try expectEqual(names.sorted(), ["Alice Smith", "Bob Jones", "Carol Liu"])
        try expect(!names.contains("Mute"),             "button label leaked")
        try expect(!names.contains("Remove participant"), "button label leaked")
        try expect(!names.contains("More actions"),     "button label leaked")
    }

    test("Pre-join lobby: empty tree returns no names") {
        let tree = try loadFixture("roster_lobby.json")
        let names = RosterReader.readRosterFromNode(tree)
        try expectEqual(names, [])
    }

    test("Panel collapsed: roster-list identifier found but no text children — returns empty") {
        let tree = try loadFixture("roster_panel_collapsed.json")
        let names = RosterReader.readRosterFromNode(tree)
        try expectEqual(names, [])
    }
}

// MARK: - SegmentDeduplicator Tests

func runSegmentDeduplicatorTests() {
    print("\n🧹 SegmentDeduplicator Tests")

    let app = TranscriptSegment(
        speaker: "Remote",
        startTime: 10.0,
        endTime: 13.0,
        text: "Let's review the quarterly numbers please."
    )

    test("drops mic segment that mirrors app text in same time window") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 10.1,
            endTime: 13.1,
            text: "Let's review the quarterly numbers please."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 0)
    }

    test("drops mic fragment whose words are mostly contained in app segment") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 10.5,
            endTime: 12.5,
            text: "review quarterly numbers"
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 0)
    }

    test("keeps mic segment when text is unrelated") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 10.0,
            endTime: 13.0,
            text: "Yeah, totally agree with what you said."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 1)
    }

    test("keeps mic segment when timestamps don't overlap (after shift)") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 30.0,
            endTime: 33.0,
            text: "Let's review the quarterly numbers please."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 1)
    }

    test("applies micDelay to align mic-track time with app-track time") {
        // Mic started 5s after app. Mic-time 5.0 == app-time 10.0.
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 5.0,
            endTime: 8.0,
            text: "Let's review the quarterly numbers please."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 5.0
        )
        try expectEqual(result.count, 0)
    }

    test("tolerates small timing slop at segment edges") {
        // Mic ends 1.0s before app starts — within edgeTolerance (1.5s).
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 8.0,
            endTime: 9.0,
            text: "Let's review the quarterly numbers please."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 0)
    }

    test("returns mic unchanged when app segments are empty") {
        let mic = TranscriptSegment(speaker: "Me", startTime: 0, endTime: 1, text: "Hi.")
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 1)
    }

    test("keeps short user backchannels even when word appears in app segment") {
        // User says "yeah" while remote is talking. App segment contains "yeah"
        // but the user actually said it — must not be dropped as bleed.
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 11.0,
            endTime: 11.5,
            text: "Yeah."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [TranscriptSegment(
                speaker: "Remote",
                startTime: 10.0,
                endTime: 14.0,
                text: "Yeah, so the migration is rolling out next week."
            )],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 1)
    }

    test("keeps two-word backchannel like 'right exactly' overlapping app segment") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 11.0,
            endTime: 11.6,
            text: "Right, exactly."
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [TranscriptSegment(
                speaker: "Remote",
                startTime: 10.0,
                endTime: 14.0,
                text: "Right, so as I was saying — exactly that point matters."
            )],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 1)
    }

    test("normalizes case and punctuation when comparing tokens") {
        let mic = TranscriptSegment(
            speaker: "Me",
            startTime: 10.0,
            endTime: 13.0,
            text: "LET'S REVIEW THE QUARTERLY NUMBERS, PLEASE!"
        )
        let result = SegmentDeduplicator.dropMicBleed(
            appSegments: [app],
            micSegments: [mic],
            micDelaySeconds: 0
        )
        try expectEqual(result.count, 0)
    }
}

// MARK: - SpeakerEmbeddingAggregator Tests

func runSpeakerEmbeddingAggregatorTests() {
    print("\n🧮 Speaker Embedding Aggregator Tests")

    typealias Chunk = SpeakerEmbeddingAggregator.Chunk

    test("Single chunk returns its normalized direction") {
        // 3-4-0 has norm 5 → normalizes to 0.6, 0.8, 0.
        let c = SpeakerEmbeddingAggregator.centroid(of: [Chunk(vector: [3, 4, 0], weight: 1)])
        let centroid = try unwrap(c)
        try expectClose(Double(centroid[0]), 0.6)
        try expectClose(Double(centroid[1]), 0.8)
        try expectClose(Double(centroid[2]), 0.0)
    }

    test("Centroid result is L2-normalized") {
        let c = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [1, 1, 1, 1], weight: 1),
            Chunk(vector: [1, 0, 1, 0], weight: 1),
        ]))
        let norm = sqrt(c.reduce(Float(0)) { $0 + $1 * $1 })
        try expectClose(Double(norm), 1.0)
    }

    test("Duration weight pulls centroid toward the longer chunk") {
        // Heavy chunk points +x, light chunk points +y. Result should lean +x.
        let c = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [1, 0], weight: 9),
            Chunk(vector: [0, 1], weight: 1),
        ]))
        try expect(c[0] > c[1], "expected x-component (\(c[0])) > y-component (\(c[1]))")
        // 9:1 weighting → atan2(1,9); x ≈ 0.994, y ≈ 0.110.
        try expectClose(Double(c[0]), 0.9938, tolerance: 0.01)
    }

    test("Outlier chunk is trimmed from the centroid") {
        // Three tight +x chunks plus one opposing -x chunk. The opposing chunk sits
        // beyond the 0.50 distance threshold from the provisional mean and is dropped,
        // so the refined centroid stays essentially +x.
        let c = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [1, 0], weight: 1),
            Chunk(vector: [1, 0], weight: 1),
            Chunk(vector: [0.98, 0.2], weight: 1),
            Chunk(vector: [-1, 0], weight: 1), // outlier (cosine distance 2.0)
        ]))
        try expect(c[0] > 0.9, "expected centroid to stay near +x, got \(c)")
    }

    test("Two equal orthogonal chunks yield a symmetric centroid") {
        // Provisional mean is the 45° bisector; both chunks sit 0.29 from it (inside the
        // 0.50 keep threshold), so neither is trimmed and the result stays symmetric.
        let centroid = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [1, 0], weight: 1),
            Chunk(vector: [0, 1], weight: 1),
        ]))
        try expectClose(Double(centroid[0]), Double(centroid[1]))
    }

    test("Empty vectors and non-positive weights are ignored") {
        let c = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [], weight: 5),
            Chunk(vector: [1, 0], weight: 0),   // zero weight skipped
            Chunk(vector: [3, 4], weight: 2),
        ]))
        try expectClose(Double(c[0]), 0.6)
        try expectClose(Double(c[1]), 0.8)
    }

    test("Mismatched dimensionality chunks are dropped defensively") {
        let c = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [1, 0], weight: 1),
            Chunk(vector: [1, 0, 0], weight: 1), // wrong dim vs first usable → dropped
        ]))
        try expectEqual(c.count, 2)
    }

    test("No usable chunks yields nil") {
        try expect(SpeakerEmbeddingAggregator.centroid(of: []) == nil)
        try expect(SpeakerEmbeddingAggregator.centroid(of: [Chunk(vector: [], weight: 1)]) == nil)
    }

    test("centroids(perSpeaker:) builds one vector per speaker, omitting empties") {
        let out = SpeakerEmbeddingAggregator.centroids(perSpeaker: [
            "R_1": [Chunk(vector: [3, 4], weight: 1)],
            "R_2": [Chunk(vector: [1, 0], weight: 2), Chunk(vector: [1, 0], weight: 2)],
            "R_3": [Chunk(vector: [], weight: 1)], // no usable chunk → omitted
        ])
        try expectEqual(out.count, 2)
        try expect(out["R_1"] != nil && out["R_2"] != nil)
        try expect(out["R_3"] == nil)
    }

    test("l2Normalized leaves a zero vector unchanged") {
        try expectEqual(l2Normalized([0, 0, 0]), [0, 0, 0])
        try expectEqual(l2Normalized([]), [])
    }

    test("Centroid stays a confident match for the same speaker's stored profile") {
        // Simulate a stored profile embedding and noisy windows of the same speaker.
        let stored: [Float] = [1, 0, 0, 0]
        let centroid = try unwrap(SpeakerEmbeddingAggregator.centroid(of: [
            Chunk(vector: [0.9, 0.1, 0.1, 0], weight: 3),
            Chunk(vector: [0.95, 0.05, 0, 0.1], weight: 4),
            Chunk(vector: [0.88, 0, 0.15, 0.05], weight: 2),
        ]))
        // Distance well under SpeakerMatcher.matchThreshold (0.30).
        try expect(cosineDistance(centroid, stored) < 0.30,
                   "distance \(cosineDistance(centroid, stored)) should be < 0.30")
    }
}

func runSystemMemoryTests() {
    print("\n🧠 SystemMemory / MemoryMode Tests")

    let threshold = SystemMemory.lowMemoryThresholdBytes // 8 GB

    test("8 GB is treated as low-memory (boundary is inclusive)") {
        try expect(SystemMemory.isLowMemoryMachine(physicalMemoryBytes: threshold))
    }

    test("below 8 GB is low-memory") {
        try expect(SystemMemory.isLowMemoryMachine(physicalMemoryBytes: 4 * 1024 * 1024 * 1024))
    }

    test("just over 8 GB is not low-memory") {
        try expect(!SystemMemory.isLowMemoryMachine(physicalMemoryBytes: threshold + 1))
    }

    test("16 GB is not low-memory") {
        try expect(!SystemMemory.isLowMemoryMachine(physicalMemoryBytes: 16 * 1024 * 1024 * 1024))
    }

    test("threshold equals 8 GiB in bytes") {
        try expectEqual(threshold, 8_589_934_592)
    }

    test("effectiveLowMemory honors forced overrides regardless of RAM") {
        var low = AppSettings.default
        low.memoryMode = .low
        try expect(low.effectiveLowMemory)

        var normal = AppSettings.default
        normal.memoryMode = .normal
        try expect(!normal.effectiveLowMemory)
    }

    test("auto effectiveLowMemory matches the machine's RAM check") {
        var auto = AppSettings.default
        auto.memoryMode = .auto
        try expectEqual(auto.effectiveLowMemory, SystemMemory.isLowMemoryMachine)
    }
}

@main
struct TestRunner {
    @MainActor static func main() async {
        print("🧪 Heard Tests\n")

        runVadSegmentMapTests()
        runSpeakerMatcherTests()
        runSegmentMergerTests()
        runAudioPreprocessorTests()
        runAudioClipExtractorTests()
        runTranscriptWriterTests()
        runStoreTests()
        runPipelineResumeTests()
        runMeetingDetectionTests()
        runTeamsIdentificationTests()
        runMeetingAppIdentificationTests()
        runMeetingDetectorLifecycleTests()
        await runRetryExecutorTests()
        await runLifetimeRetryCapTests()
        runSpeakerMatcherEdgeTests()
        runSpeakerEmbeddingAggregatorTests()
        runRosterReaderTests()
        runRosterReaderAXTests()
        runSegmentDeduplicatorTests()
        runSystemMemoryTests()
        runPermissionCenterTests()

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
