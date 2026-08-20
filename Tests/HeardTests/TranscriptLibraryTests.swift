import Foundation
@testable import HeardCore

func runTranscriptLibraryTests() {
    print("\n📚 TranscriptLibrary Tests")

    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

    test("missing directory returns []") {
        let results = TranscriptLibrary.scan(directory: tempDir.appendingPathComponent("missing"))
        try expect(results.isEmpty)
    }

    test("happy-path header parse") {
        let url = tempDir.appendingPathComponent("2026-07-11_Happy Path.md")
        let header = """
        # My Awesome Meeting
        
        **Date:** 2026-07-11 14:30 – 15:30
        **Duration:** 1h 0m
        **Participants:** Alice, Bob, Charlie
        
        ---
        """
        let mtime = Date(timeIntervalSince1970: 0)
        let record = try unwrap(TranscriptLibrary.parseRecord(url: url, header: header, modificationDate: mtime))
        
        try expectEqual(record.title, "My Awesome Meeting")
        try expectEqual(Formatting.transcriptDateFormatter.string(from: record.date), "2026-07-11 14:30")
        try expectEqual(record.duration, 3600)
        try expectEqual(record.participants, ["Alice", "Bob", "Charlie"])
    }
    
    test("_2 dedup filename still parses and missing header fallbacks") {
        let url = tempDir.appendingPathComponent("2026-07-11_Standup_2.md")
        let header = "just some random text without header"
        let mtime = Date(timeIntervalSince1970: 1000)
        
        let record = try unwrap(TranscriptLibrary.parseRecord(url: url, header: header, modificationDate: mtime))
        try expectEqual(record.title, "Standup")
        try expectEqual(record.date, mtime)
        try expectEqual(record.duration, nil)
        try expectEqual(record.participants, [])
    }
    
    test("malformed Duration/Date lines tolerated") {
        let url = tempDir.appendingPathComponent("test.md")
        let header = """
        # Title
        **Date:** malformed date
        **Duration:** Xh Ym
        """
        let mtime = Date(timeIntervalSince1970: 2000)
        let record = try unwrap(TranscriptLibrary.parseRecord(url: url, header: header, modificationDate: mtime))
        
        try expectEqual(record.title, "Title")
        try expectEqual(record.date, mtime)
        try expectEqual(record.duration, nil)
    }
    
    test("*_note.md excluded; non-.md ignored") {
        let note = tempDir.appendingPathComponent("2026-07-11_14-30-00_note.md")
        try expect(TranscriptLibrary.parseRecord(url: note, header: "", modificationDate: Date()) == nil)
        
        let txt = tempDir.appendingPathComponent("test.txt")
        try expect(TranscriptLibrary.parseRecord(url: txt, header: "", modificationDate: Date()) == nil)
    }
    
    test("directory scan filters and sorts newest-first") {
        let scanDir = tempDir.appendingPathComponent("scan_test")
        try? fm.createDirectory(at: scanDir, withIntermediateDirectories: true)
        
        // Create files
        let f1 = scanDir.appendingPathComponent("2026-07-11_A.md")
        let f2 = scanDir.appendingPathComponent("2026-07-11_B.md")
        let f3 = scanDir.appendingPathComponent("2026-07-10_C.md")
        let note = scanDir.appendingPathComponent("2026-07-11_note.md")
        let txt = scanDir.appendingPathComponent("log.txt")
        let hidden = scanDir.appendingPathComponent(".hidden.md")
        
        try? "header A".write(to: f1, atomically: true, encoding: .utf8)
        try? "header B".write(to: f2, atomically: true, encoding: .utf8)
        try? "header C".write(to: f3, atomically: true, encoding: .utf8)
        try? "note".write(to: note, atomically: true, encoding: .utf8)
        try? "txt".write(to: txt, atomically: true, encoding: .utf8)
        try? "hidden".write(to: hidden, atomically: true, encoding: .utf8)
        
        // Give them predictable modification dates in case of fallback
        let base = Date(timeIntervalSince1970: 10000)
        try? fm.setAttributes([.modificationDate: base.addingTimeInterval(10)], ofItemAtPath: f1.path)
        try? fm.setAttributes([.modificationDate: base.addingTimeInterval(20)], ofItemAtPath: f2.path)
        try? fm.setAttributes([.modificationDate: base.addingTimeInterval(5)], ofItemAtPath: f3.path)
        
        let results = TranscriptLibrary.scan(directory: scanDir)
        
        // Expected: f2, f1, f3 (newest first based on mtime)
        try expectEqual(results.count, 3)
        try expectEqual(results[0].url.lastPathComponent, "2026-07-11_B.md")
        try expectEqual(results[1].url.lastPathComponent, "2026-07-11_A.md")
        try expectEqual(results[2].url.lastPathComponent, "2026-07-10_C.md")
    }

    test("sort stability on same date") {
        let scanDir = tempDir.appendingPathComponent("sort_test")
        try? fm.createDirectory(at: scanDir, withIntermediateDirectories: true)
        
        let f1 = scanDir.appendingPathComponent("2026-07-11_Meet A.md")
        let f2 = scanDir.appendingPathComponent("2026-07-11_Meet B.md")
        
        let header = """
        **Date:** 2026-07-11 14:30 – 15:30
        """
        try? header.write(to: f1, atomically: true, encoding: .utf8)
        try? header.write(to: f2, atomically: true, encoding: .utf8)
        
        let results = TranscriptLibrary.scan(directory: scanDir)
        try expectEqual(results.count, 2)
        // same date -> fallback to filename descending
        try expectEqual(results[0].url.lastPathComponent, "2026-07-11_Meet B.md")
        try expectEqual(results[1].url.lastPathComponent, "2026-07-11_Meet A.md")
    }

    test("Meetings tab omits the current user from participants") {
        let visible = TranscriptLibrary.participantsExcludingCurrentUser(
            ["Alice", " Jane ", "Me", "jane", "Bob"],
            userName: "Jane"
        )
        try expectEqual(visible, ["Alice", "Bob"])
    }

    test("Meetings tab omits the legacy Me label when no name is configured") {
        let visible = TranscriptLibrary.participantsExcludingCurrentUser(
            ["Me", "Alice"],
            userName: ""
        )
        try expectEqual(visible, ["Alice"])
    }
}
