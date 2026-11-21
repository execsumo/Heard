import Foundation
import HeardCore

// Journal and orphan recovery: audio stays on disk until its job is durably queued, and
// a failed write never deletes it.

private func makeScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HeardTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeAudio(_ url: URL, bytes: Int) throws {
    try Data(count: bytes).write(to: url)
}

private func le16(_ value: UInt16) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: 2)
}

private func le32(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: 4)
}

/// 16-bit mono PCM. `finalized: false` writes the zero size fields an unclosed file leaves behind.
private func writeWAV(
    _ url: URL, seconds: Int, sampleRate: UInt32 = 1_000, finalized: Bool = true, trailingBytes: Int = 0
) throws {
    let payload = seconds * Int(sampleRate) * 2
    let riffSize: UInt32 = finalized ? UInt32(36 + payload) : 0
    let dataSize: UInt32 = finalized ? UInt32(payload) : 0
    var bytes = Data("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Data("WAVE".utf8)
    bytes += Data("fmt ".utf8)
    bytes += le32(16)
    bytes += le16(1)
    bytes += le16(1)
    bytes += le32(sampleRate)
    bytes += le32(sampleRate * 2)
    bytes += le16(2)
    bytes += le16(16)
    bytes += Data("data".utf8)
    bytes += le32(dataSize)
    bytes += Data(count: payload + trailingBytes)
    try bytes.write(to: url)
}

/// 44-byte PCM header with explicit size fields, for the pure duration helper.
private func pcmHeader(
    riffSize: UInt32, dataSize: UInt32, sampleRate: UInt32 = 1_000, channels: UInt16 = 1, blockAlign: UInt16 = 2
) -> Data {
    var bytes = Data("RIFF".utf8)
    bytes += le32(riffSize)
    bytes += Data("WAVE".utf8)
    bytes += Data("fmt ".utf8)
    bytes += le32(16)
    bytes += le16(1)
    bytes += le16(channels)
    bytes += le32(sampleRate)
    bytes += le32(sampleRate * UInt32(blockAlign))
    bytes += le16(blockAlign)
    bytes += le16(16)
    bytes += Data("data".utf8)
    bytes += le32(dataSize)
    return bytes
}

private func age(_ url: URL, days: Double) throws {
    let old = Date().addingTimeInterval(-days * 86_400)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
}

private func makeEntry(
    id: UUID = UUID(), app: URL, mic: URL, updatedAt: Date = Date(timeIntervalSince1970: 2_000)
) -> ActiveRecordingEntry {
    ActiveRecordingEntry(
        id: id, title: "Sprint", startTime: Date(timeIntervalSince1970: 1_000), updatedAt: updatedAt,
        appAudioPath: app, micAudioPath: mic, micDelaySeconds: 0.25,
        rosterNames: ["Alice Smith"],
        notes: [MeetingNote(offsetSeconds: 3, text: "Follow up", createdAt: Date(timeIntervalSince1970: 1_003))],
        chatMessages: [ChatMessage(offsetSeconds: 4, sender: "Bob", text: "link?")]
    )
}

@MainActor func runActiveRecordingTests() {
    print("\n📓 Active Recording Journal Tests")

    test("journal writes one entry per recording and round-trips its metadata") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journalDir = dir.appendingPathComponent("active_recordings")
        let journal = ActiveRecordingStore(directory: journalDir)
        let entry = makeEntry(app: dir.appendingPathComponent("a.wav"), mic: dir.appendingPathComponent("m.wav"))

        try journal.save(entry)

        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: journalDir.path), ["\(entry.id.uuidString).json"])
        try expectEqual(journal.pendingEntries(), [entry])
    }

    test("journal dates keep fractional seconds") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let start = Date(timeIntervalSince1970: 1_000.25)
        let updated = Date(timeIntervalSince1970: 2_000.75)
        let entry = ActiveRecordingEntry(
            id: UUID(), title: "Fractional", startTime: start, updatedAt: updated,
            appAudioPath: dir.appendingPathComponent("a.wav"), micAudioPath: dir.appendingPathComponent("m.wav"),
            micDelaySeconds: 0, rosterNames: [], notes: [], chatMessages: []
        )
        try journal.save(entry)

        let loaded = try unwrap(journal.pendingEntries().first)
        try expectClose(loaded.startTime.timeIntervalSince1970, 1_000.25, tolerance: 0.000_001)
        try expectClose(loaded.updatedAt.timeIntervalSince1970, 2_000.75, tolerance: 0.000_001)
    }

    test("journal entry removal is idempotent") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let entry = makeEntry(app: dir.appendingPathComponent("a.wav"), mic: dir.appendingPathComponent("m.wav"))
        try journal.save(entry)

        journal.remove(entry.id)
        journal.remove(entry.id)

        try expect(journal.pendingEntries().isEmpty)
    }

    test("stop handoff queues the session under its id and drops the journal entry") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        let session = RecordingSession(
            title: "Sprint", startTime: Date(timeIntervalSince1970: 1_000),
            appAudioPath: app, micAudioPath: mic, micDelaySeconds: 0.25, rosterNames: ["Alice Smith"]
        )
        try journal.save(ActiveRecordingEntry(session: session, updatedAt: Date(timeIntervalSince1970: 2_000)))

        try expect(journal.enqueue(PipelineJob(finishing: session, endedAt: Date(timeIntervalSince1970: 2_000)), into: queue))

        try expectEqual(queue.jobs.map(\.id), [session.id])
        try expectEqual(queue.jobs.first?.micDelaySeconds, 0.25)
        try expect(journal.pendingEntries().isEmpty)
    }

    test("a repeated handoff of one session queues it once") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        let session = RecordingSession(
            title: "Sprint", startTime: Date(timeIntervalSince1970: 1_000),
            appAudioPath: app, micAudioPath: mic, micDelaySeconds: 0
        )
        let job = PipelineJob(finishing: session, endedAt: Date(timeIntervalSince1970: 2_000))

        try expect(journal.enqueue(job, into: queue))
        try journal.save(ActiveRecordingEntry(session: session, updatedAt: Date(timeIntervalSince1970: 2_000)))
        try expect(journal.enqueue(job, into: queue), "a repeated handoff should be accepted as a duplicate")

        try expectEqual(queue.jobs.map(\.id), [session.id])
        try expect(journal.pendingEntries().isEmpty)
    }

    test("relaunch after a crash queues the journaled recording with its metadata") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journalDir = dir.appendingPathComponent("active_recordings")
        let entry = makeEntry(app: app, mic: mic)
        try ActiveRecordingStore(directory: journalDir).save(entry)

        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        let outcomes = ActiveRecordingStore(directory: journalDir).recover(into: queue)

        try expectEqual(outcomes, [.recovered(entry.id)])
        let job = try unwrap(queue.jobs.first)
        try expectEqual(job.id, entry.id)
        try expectEqual(job.meetingTitle, "Sprint")
        try expectEqual(job.startTime, entry.startTime)
        try expectEqual(job.endTime, entry.updatedAt)
        try expectEqual(job.rosterNames, ["Alice Smith"])
        try expectEqual(job.notes.map(\.text), ["Follow up"])
        try expectEqual(job.chatMessages.map(\.text), ["link?"])
        try expectEqual(job.micDelaySeconds, 0.25)
        try expect(ActiveRecordingStore(directory: journalDir).pendingEntries().isEmpty)
    }

    test("recovery ends the job where the audio ends, not at the stale journal time") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeWAV(app, seconds: 5)
        try writeWAV(mic, seconds: 6)
        let start = Date(timeIntervalSince1970: 1_000)
        // The mic starts 1s after the app track, so the mic ends at 7s.
        let entry = ActiveRecordingEntry(
            id: UUID(), title: "Sprint", startTime: start, updatedAt: start.addingTimeInterval(1),
            appAudioPath: app, micAudioPath: mic, micDelaySeconds: 1,
            rosterNames: [], notes: [], chatMessages: []
        )
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        try journal.save(entry)
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        try expectEqual(journal.recover(into: queue), [.recovered(entry.id)])
        let job = try unwrap(queue.jobs.first)
        try expectClose(job.endTime.timeIntervalSince(start), 7)
    }

    test("an unclosed WAV header still yields its audio length") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        try writeWAV(app, seconds: 4, finalized: false)
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = ActiveRecordingEntry(
            id: UUID(), title: "Sprint", startTime: start, updatedAt: start,
            appAudioPath: app, micAudioPath: dir.appendingPathComponent("missing.wav"), micDelaySeconds: 0,
            rosterNames: [], notes: [], chatMessages: []
        )
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        try journal.save(entry)
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        try expectEqual(journal.recover(into: queue), [.recovered(entry.id)])
        let job = try unwrap(queue.jobs.first)
        try expectClose(job.endTime.timeIntervalSince(start), 4)
    }

    test("a recovered recording without a title gets a readable name") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        try writeAudio(app, bytes: 4096)
        var entry = makeEntry(app: app, mic: dir.appendingPathComponent("m.wav"))
        entry.title = ""
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        try journal.save(entry)
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        _ = journal.recover(into: queue)

        try expectEqual(queue.jobs.first?.meetingTitle, "Recovered recording")
    }

    test("a mic delay recalibrated mid-recording reaches the journal and the recovered job") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeWAV(app, seconds: 2)
        try writeWAV(mic, seconds: 2)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        var session = RecordingSession(
            title: "Sprint", startTime: Date(timeIntervalSince1970: 1_000),
            appAudioPath: app, micAudioPath: mic, micDelaySeconds: 0
        )
        try journal.save(ActiveRecordingEntry(session: session, updatedAt: Date(timeIntervalSince1970: 1_000)))

        // The app track restarted; the recalibrated delay is persisted right away.
        session.micDelaySeconds = 0.8
        try journal.save(ActiveRecordingEntry(session: session, updatedAt: Date(timeIntervalSince1970: 1_001)))
        try expectEqual(journal.pendingEntries().first?.micDelaySeconds, 0.8)

        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        _ = journal.recover(into: queue)
        try expectEqual(queue.jobs.first?.micDelaySeconds, 0.8)
    }

    test("recovery is idempotent across repeated launches and already-queued jobs") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journalDir = dir.appendingPathComponent("active_recordings")
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        let first = makeEntry(app: app, mic: mic)
        try ActiveRecordingStore(directory: journalDir).save(first)

        try expectEqual(ActiveRecordingStore(directory: journalDir).recover(into: queue), [.recovered(first.id)])
        try expectEqual(ActiveRecordingStore(directory: journalDir).recover(into: queue), [])
        try expectEqual(queue.jobs.count, 1)

        // Crash after the queue write but before the journal removal: the job is already queued.
        let second = makeEntry(id: UUID(), app: app, mic: mic)
        try ActiveRecordingStore(directory: journalDir).save(second)
        queue.enqueue(PipelineJob(recovering: second, endedAt: second.updatedAt))
        try expectEqual(ActiveRecordingStore(directory: journalDir).recover(into: queue), [.alreadyQueued(second.id)])
        try expectEqual(queue.jobs.count, 2)
        try expect(ActiveRecordingStore(directory: journalDir).pendingEntries().isEmpty)
    }

    test("recovery queues a recording with one usable track and drops one with no usable audio") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        try writeAudio(app, bytes: 4096)
        let missing = dir.appendingPathComponent("missing_mic.wav")
        let tiny = dir.appendingPathComponent("tiny_app.wav")
        try writeAudio(tiny, bytes: 100)
        let journalDir = dir.appendingPathComponent("active_recordings")
        let oneTrack = makeEntry(app: app, mic: missing)
        let empty = makeEntry(app: tiny, mic: missing)
        let journal = ActiveRecordingStore(directory: journalDir)
        try journal.save(oneTrack)
        try journal.save(empty)
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        let outcomes = journal.recover(into: queue)

        try expectEqual(outcomes.count, 2)
        try expect(outcomes.contains(.recovered(oneTrack.id)), "one-track recording should be queued")
        try expect(outcomes.contains(.noUsableAudio(empty.id)), "recording without usable audio should be dropped")
        try expectEqual(queue.jobs.map(\.id), [oneTrack.id])
        try expectEqual(queue.jobs.first?.micAudioPath, missing)
        try expect(journal.pendingEntries().isEmpty)
    }

    test("a corrupt journal entry is quarantined without blocking other recordings") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journalDir = dir.appendingPathComponent("active_recordings")
        let journal = ActiveRecordingStore(directory: journalDir)
        let good = makeEntry(app: app, mic: mic)
        try journal.save(good)
        let badID = UUID()
        try Data("not json".utf8).write(to: journalDir.appendingPathComponent("\(badID.uuidString).json"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        try expectEqual(journal.recover(into: queue), [.recovered(good.id)])
        try expect(FileManager.default.fileExists(atPath: journalDir.appendingPathComponent("\(badID.uuidString).json.corrupt").path))
        try expect(journal.pendingEntries().isEmpty)
    }

    test("a failed queue write keeps the journal entry and audio for the next launch") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let entry = makeEntry(app: app, mic: mic)
        try journal.save(entry)

        let brokenQueue = PipelineQueueStore(url: dir.appendingPathComponent("missing/queue.json"))
        try expectEqual(journal.recover(into: brokenQueue), [.queueWriteFailed(entry.id)])
        try expect(brokenQueue.jobs.isEmpty)
        try expectEqual(journal.pendingEntries().map(\.id), [entry.id])

        let healthyQueue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        try expectEqual(journal.recover(into: healthyQueue), [.recovered(entry.id)])
        try expectEqual(healthyQueue.jobs.map(\.id), [entry.id])
        try expect(journal.pendingEntries().isEmpty)
    }

    test("recovery excludes the active recording's entry") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("a.wav")
        let mic = dir.appendingPathComponent("m.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let live = makeEntry(app: app, mic: mic)
        try journal.save(live)
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        try expectEqual(journal.recover(into: queue, excluding: live.id), [])
        try expect(queue.jobs.isEmpty)
        try expectEqual(journal.pendingEntries().map(\.id), [live.id])
    }

    test("cleanup keeps old audio that only an unqueued journal entry references") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let kept = recordings.appendingPathComponent("kept_app.wav")
        let dropped = recordings.appendingPathComponent("stale_app.wav")
        try writeAudio(kept, bytes: 4096)
        try writeAudio(dropped, bytes: 4096)
        let old = Date().addingTimeInterval(-49 * 3600)
        for url in [kept, dropped] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        try journal.save(makeEntry(app: kept, mic: recordings.appendingPathComponent("absent_mic.wav")))
        let brokenQueue = PipelineQueueStore(url: dir.appendingPathComponent("missing/queue.json"))
        _ = journal.recover(into: brokenQueue)

        TempFileCleanup.cleanStaleRecordings(activeJobPaths: journal.retainedAudioPaths, recordingsDir: recordings)

        try expect(FileManager.default.fileExists(atPath: kept.path), "journal-referenced audio must survive cleanup")
        try expect(!FileManager.default.fileExists(atPath: dropped.path), "unreferenced stale audio should be removed")
    }

    test("cleanup keeps old audio that a recovered queued job references") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let app = recordings.appendingPathComponent("queued_app.wav")
        let mic = recordings.appendingPathComponent("queued_mic.wav")
        try writeAudio(app, bytes: 4096)
        try writeAudio(mic, bytes: 4096)
        let old = Date().addingTimeInterval(-49 * 3600)
        for url in [app, mic] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        try journal.save(makeEntry(app: app, mic: mic))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        _ = journal.recover(into: queue)
        let queuedPaths = Set(queue.jobs.filter { $0.stage != .complete }.flatMap { [$0.appAudioPath, $0.micAudioPath] })

        TempFileCleanup.cleanStaleRecordings(activeJobPaths: queuedPaths, recordingsDir: recordings)

        try expect(FileManager.default.fileExists(atPath: app.path))
        try expect(FileManager.default.fileExists(atPath: mic.path))
    }

    test("an orphaned recording from days ago is queued and survives cleanup") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let app = recordings.appendingPathComponent("20240101_120000_app.wav")
        try writeWAV(app, seconds: 2)
        try age(app, days: 3)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        let scan = journal.adoptOrphans(in: recordings, referenced: [], into: queue)

        try expectEqual(scan.adopted.count, 1)
        try expect(scan.unjournaled.isEmpty)
        let job = try unwrap(queue.jobs.first)
        try expectEqual(job.appAudioPath, app)
        try expectEqual(job.startTime, try unwrap(Formatting.recordingFileFormatter.date(from: "20240101_120000")))
        try expectEqual(job.meetingTitle, "Recovered recording")
        try expect(job.rosterNames.isEmpty)

        TempFileCleanup.cleanStaleRecordings(activeJobPaths: Set(queue.jobs.flatMap { [$0.appAudioPath, $0.micAudioPath] }), recordingsDir: recordings)
        try expect(FileManager.default.fileExists(atPath: app.path), "a queued orphan must survive the 48-hour cleanup")
    }

    test("a relaunch does not queue an orphan twice or re-queue audio a complete job holds") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let orphanApp = recordings.appendingPathComponent("20240101_120000_app.wav")
        let finishedApp = recordings.appendingPathComponent("20240102_120000_app.wav")
        let finishedMic = recordings.appendingPathComponent("20240102_120000_mic.wav")
        try writeWAV(orphanApp, seconds: 2)
        try writeWAV(finishedApp, seconds: 2)
        try writeWAV(finishedMic, seconds: 2)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))
        var finished = PipelineJob(finishing: RecordingSession(
            title: "Done", startTime: Date(timeIntervalSince1970: 1_000),
            appAudioPath: finishedApp, micAudioPath: finishedMic, micDelaySeconds: 0
        ), endedAt: Date(timeIntervalSince1970: 2_000))
        finished.stage = .complete
        queue.enqueue(finished)

        try expectEqual(journal.adoptOrphans(in: recordings, referenced: [], into: queue).adopted.count, 1)
        let inUse = Set(queue.jobs.flatMap { [$0.appAudioPath, $0.micAudioPath] })
        try expectEqual(journal.adoptOrphans(in: recordings, referenced: inUse, into: queue).adopted, [])

        try expectEqual(queue.jobs.count, 2)
        try expectEqual(queue.jobs.filter { $0.appAudioPath == finishedApp }.count, 1)
    }

    test("orphan groups match only generated app and mic names") {
        let dir = URL(fileURLWithPath: "/tmp/recordings")
        let names = [
            "20250101_120000_app.wav", "20250101_120000_mic.wav", "20250101_120000_app.wav.bak",
            "notes.wav", "2025_app.wav", ".heard-wav-x.wav", "20250101_120000_other.wav",
            "20250101_1200000_app.wav", "20250102_090000_app.wav",
        ]

        let groups = OrphanRecordingScanner.groups(fileNames: names, directory: dir)

        try expectEqual(groups.count, 2)
        try expectEqual(groups[0].appAudioPath.lastPathComponent, "20250101_120000_app.wav")
        try expectEqual(groups[0].micAudioPath.lastPathComponent, "20250101_120000_mic.wav")
        try expectEqual(groups[1].startTime, try unwrap(Formatting.recordingFileFormatter.date(from: "20250102_090000")))
        try expectEqual(groups[1].micAudioPath.lastPathComponent, "20250102_090000_mic.wav")
    }

    test("an orphan with no usable track is left on disk") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let tiny = recordings.appendingPathComponent("20240101_120000_app.wav")
        try writeAudio(tiny, bytes: 100)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        let scan = journal.adoptOrphans(in: recordings, referenced: [], into: queue)

        try expect(scan.adopted.isEmpty)
        try expect(scan.unjournaled.isEmpty)
        try expect(queue.jobs.isEmpty)
        try expect(FileManager.default.fileExists(atPath: tiny.path))
    }

    test("a failed queue write during orphan adoption keeps the audio and its journal entry") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let app = recordings.appendingPathComponent("20240101_120000_app.wav")
        try writeWAV(app, seconds: 2)
        try age(app, days: 3)
        let journal = ActiveRecordingStore(directory: dir.appendingPathComponent("active_recordings"))
        let brokenQueue = PipelineQueueStore(url: dir.appendingPathComponent("missing/queue.json"))

        let scan = journal.adoptOrphans(in: recordings, referenced: [], into: brokenQueue)

        try expect(scan.adopted.isEmpty)
        try expect(scan.unjournaled.isEmpty, "the entry was written, so the group is not unjournaled")
        try expectEqual(journal.pendingEntries().count, 1)
        TempFileCleanup.cleanStaleRecordings(activeJobPaths: journal.retainedAudioPaths, recordingsDir: recordings)
        try expect(FileManager.default.fileExists(atPath: app.path), "audio must survive a failed queue write")
    }

    test("an orphan that cannot be journaled stays on disk and is reported") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let app = recordings.appendingPathComponent("20240101_120000_app.wav")
        try writeWAV(app, seconds: 2)
        try age(app, days: 3)
        // A regular file where the journal directory should go makes every save fail.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let journal = ActiveRecordingStore(directory: blocker.appendingPathComponent("active_recordings"))
        let queue = PipelineQueueStore(url: dir.appendingPathComponent("queue.json"))

        let scan = journal.adoptOrphans(in: recordings, referenced: [], into: queue)

        try expect(scan.adopted.isEmpty)
        try expectEqual(scan.unjournaled.map(\.appAudioPath), [app])
        try expect(queue.jobs.isEmpty)
        TempFileCleanup.cleanStaleRecordings(activeJobPaths: Set(scan.unjournaled.flatMap { $0.audioPaths }), recordingsDir: recordings)
        try expect(FileManager.default.fileExists(atPath: app.path), "an unjournaled orphan must not be deleted")
    }

    test("a failed initial journal write stays flagged through unrelated queue events") {
        var warning = RecoveryWarning()
        warning.recordActiveJournalWrite(succeeded: false)
        warning.recordQueueSave(succeeded: true)
        warning.setUnqueuedRecordings(0)

        try expect(warning.activeRecordingUnjournaled, "only a journal write clears the active-recording flag")
        try expectEqual(warning.messages.count, 1)

        warning.recordActiveJournalWrite(succeeded: true)
        try expect(warning.messages.isEmpty)
    }

    test("the journal warning ends with the recording and a queue save failure stays until a save succeeds") {
        var warning = RecoveryWarning()
        warning.recordActiveJournalWrite(succeeded: false)
        warning.recordQueueSave(succeeded: false)
        try expectEqual(warning.messages.count, 2)

        warning.activeRecordingEnded()
        try expectEqual(warning.messages.count, 1)
        try expect(warning.queueSaveFailing)

        warning.recordQueueSave(succeeded: true)
        try expect(warning.messages.isEmpty)
    }

    test("a moved-aside queue stays flagged until a successful queue save") {
        var warning = RecoveryWarning()
        warning.recordQueueMovedAside()
        warning.setUnqueuedRecordings(0)
        warning.recordActiveJournalWrite(succeeded: true)
        try expect(warning.queueMovedAside)
        try expectEqual(warning.messages.count, 1)

        warning.recordQueueSave(succeeded: false)
        try expect(warning.queueMovedAside, "a failed save does not clear it")

        warning.recordQueueSave(succeeded: true)
        try expect(warning.messages.isEmpty)
    }

    test("a partial trailing frame does not zero the recovered duration") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unclosed = dir.appendingPathComponent("unclosed.wav")
        let finalized = dir.appendingPathComponent("finalized.wav")
        try writeWAV(unclosed, seconds: 4, finalized: false, trailingBytes: 1)
        try writeWAV(finalized, seconds: 4, trailingBytes: 1)

        try expectClose(try unwrap(ActiveRecordingStore.audioSeconds(at: unclosed)), 4)
        try expectClose(try unwrap(ActiveRecordingStore.audioSeconds(at: finalized)), 4)
    }

    test("durationSeconds reads a finalized header against the file size") {
        // 4 s of 1 kHz mono 16-bit: 8000 payload bytes after the 44-byte header.
        let header = pcmHeader(riffSize: 8_036, dataSize: 8_000)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 8_044)), 4)
    }

    test("durationSeconds measures the file when the header size fields are stale") {
        let header = pcmHeader(riffSize: 0, dataSize: 0)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 8_044)), 4)
    }

    test("durationSeconds drops a trailing partial frame whether or not the header is final") {
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(
            header: pcmHeader(riffSize: 0, dataSize: 0), fileSize: 8_045)), 4)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(
            header: pcmHeader(riffSize: 8_036, dataSize: 8_000), fileSize: 8_045)), 4)
    }

    test("durationSeconds counts whole stereo frames and ignores stray bytes") {
        // 2 s of 1 kHz stereo 16-bit (4-byte frames) plus 3 stray bytes.
        let header = pcmHeader(riffSize: 0, dataSize: 0, channels: 2, blockAlign: 4)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 8_047)), 2)
    }

    test("durationSeconds is zero for a header with no payload") {
        let header = pcmHeader(riffSize: 0, dataSize: 0)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 44)), 0)
    }

    test("durationSeconds returns nil without a sample rate, block alignment or RIFF header") {
        try expect(WAVHeaderFinalizer.durationSeconds(
            header: pcmHeader(riffSize: 0, dataSize: 0, sampleRate: 0), fileSize: 8_044) == nil)
        try expect(WAVHeaderFinalizer.durationSeconds(
            header: pcmHeader(riffSize: 0, dataSize: 0, blockAlign: 0), fileSize: 8_044) == nil)
        try expect(WAVHeaderFinalizer.durationSeconds(
            header: Data("not a wav header, just text".utf8), fileSize: 8_044) == nil)
    }

    test("durationSeconds counts only the payload on disk when the header declares more") {
        // Header declares 4 s; 2 s plus a partial frame exist.
        let header = pcmHeader(riffSize: 8_036, dataSize: 8_000)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 4_045)), 2)
    }

    test("durationSeconds is zero when the header declares audio but no payload exists") {
        let header = pcmHeader(riffSize: 8_036, dataSize: 8_000)
        try expectClose(try unwrap(WAVHeaderFinalizer.durationSeconds(header: header, fileSize: 44)), 0)
    }

    test("a truncated WAV repairs from the bytes on disk and reports the same length") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("truncated.wav")
        try writeWAV(url, seconds: 4)
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: 44 + 4_000 + 1)
        try handle.close()

        try expectClose(try unwrap(ActiveRecordingStore.audioSeconds(at: url)), 2)

        let source = try WAVHeaderFinalizer.readingURL(for: url)
        defer { source.cleanup() }
        let repaired = try Data(contentsOf: source.url)
        try expectEqual(try unwrap(WAVHeaderFinalizer.layout(in: repaired)).dataSize, 4_000)
    }

    test("a queue file that cannot be decoded is reported as moved aside") {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("queue.json")
        try Data("not json".utf8).write(to: url)

        try expect(PipelineQueueStore(url: url).movedAsideOnLoad)
        try expect(!PipelineQueueStore(url: dir.appendingPathComponent("absent.json")).movedAsideOnLoad)
    }
}
