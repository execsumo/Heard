import Foundation
import HeardCore

func runMeetingMetadataTests() {
    test("Teams metadata includes WebView but detection excludes helper") {
        try expect(RosterReader.isTeamsMetadataApp(bundleID: "com.microsoft.teams2.helper", localizedName: nil), "WebView missing")
        try expect(!MeetingDetector.isTeamsMainApp(bundleID: "com.microsoft.teams2.helper", localizedName: "Microsoft Teams WebView"), "helper must not become detection main")
        try expect(!RosterReader.isTeamsMetadataApp(bundleID: "com.microsoft.teams2.notificationcenter", localizedName: nil), "notification host must be excluded")
    }
    test("Deep WebView roster traverses nested row wrappers and empty values") {
        let alice = MockAXNode(role: "AXStaticText", value: "", title: "Alice Smith")
        let bob = MockAXNode(role: "AXStaticText", value: "Bob Jones")
        func row(_ text: MockAXNode) -> MockAXNode {
            MockAXNode(role: "AXRow", children: [MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXGroup", children: [text])])])
        }
        var tree = MockAXNode(role: "AXList", identifier: "", description: "roster-list", children: [row(alice), row(bob)])
        for _ in 0..<18 { tree = MockAXNode(role: "AXGroup", children: [tree]) }
        tree = MockAXNode(role: "AXApplication", children: [tree])
        try expectEqual(RosterReader.readRosterFromNode(tree), ["Alice Smith", "Bob Jones"])
    }
    test("Participants toolbar button does not hide real roster") {
        let tree = MockAXNode(children: [MockAXNode(children: [
            MockAXNode(role: "AXButton", identifier: "participants", children: [MockAXNode(value: "Show participants")]),
            MockAXNode(role: "AXList", identifier: "roster-list", children: [MockAXNode(value: "Alice Smith"), MockAXNode(value: "Bob Jones")])
        ])])
        try expectEqual(RosterReader.readRosterFromNode(tree), ["Alice Smith", "Bob Jones"])
    }
    test("People pane wrapping a list retains every participant") {
        let tree = MockAXNode(children: [MockAXNode(identifier: "people-pane", children: [
            MockAXNode(role: "AXList", children: [MockAXNode(value: "Alice Smith"), MockAXNode(value: "Bob Jones")])
        ])])
        try expectEqual(RosterReader.readRosterFromNode(tree), ["Alice Smith", "Bob Jones"])
    }
    test("People pane wrapping list in generic groups retains every participant") {
        let list = MockAXNode(role: "AXList", children: [MockAXNode(value: "Alice Smith"), MockAXNode(value: "Bob Jones")])
        let tree = MockAXNode(children: [MockAXNode(identifier: "people-pane", children: [
            MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXGroup", children: [list])])
        ])])
        try expectEqual(RosterReader.readRosterFromNode(tree), ["Alice Smith", "Bob Jones"])
    }
    // Shape observed live on Teams 2026-10-29; names are synthetic.
    func liveParticipant(_ name: String, status: String = "Muted") -> MockAXNode {
        MockAXNode(role: "AXRow", title: "\(name), \(status)", children: [
            MockAXNode(role: "AXGroup", description: "\(name), \(status)", title: "\(name), \(status)", children: [
                MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: "  ")])]),
                MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: name)]),
                MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: "Organizer")]),
                MockAXNode(role: "AXImage", description: status, title: status)
            ])
        ])
    }
    func livePane(_ rows: [MockAXNode]) -> MockAXNode {
        let heading = MockAXNode(role: "AXGroup", children: [
            MockAXNode(role: "AXRow", title: "In this meeting, 3 items", children: [
                MockAXNode(role: "AXGroup", title: "In this meeting, 3 items", children: [MockAXNode(role: "AXStaticText", value: "In this meeting (3)")]),
                MockAXNode(role: "AXButton", title: "More options")
            ])
        ])
        var pane = MockAXNode(role: "AXGroup", description: "Participants", title: "Participants", children: [
            MockAXNode(role: "AXGroup", children: [
                MockAXNode(role: "AXHeading", title: "Participants", children: [MockAXNode(role: "AXStaticText", value: "Participants")]),
                MockAXNode(role: "AXTextField", title: "Invite someone or dial a number"),
                MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXOutline", description: "Attendees", title: "Attendees", children: [heading] + rows)])
            ])
        ])
        for _ in 0..<13 { pane = MockAXNode(role: "AXGroup", children: [pane]) }
        return MockAXNode(role: "AXApplication", children: [MockAXNode(role: "AXWindow", children: [pane])])
    }
    test("Live Teams outline extracts name leaves not decorated row titles or section heading") {
        let tree = livePane([liveParticipant("Alice Smith"), liveParticipant("Bob Jones", status: "Organizer, Muted"), liveParticipant("Carol Lee (You)", status: "Unmuted")])
        try expectEqual(RosterReader.readRosterFromNode(tree), ["Alice Smith", "Bob Jones", "Carol Lee"])
    }
    test("Live Teams outline supports a single participant") {
        try expectEqual(RosterReader.readRosterFromNode(livePane([liveParticipant("Alice Smith")])), ["Alice Smith"])
    }
    test("Live Teams empty outline does not extract headings or fall through to unrelated lists") {
        let tree = MockAXNode(role: "AXApplication", children: [livePane([]), MockAXNode(role: "AXList", children: [MockAXNode(value: "Random chat"), MockAXNode(value: "Random file")])])
        try expectEqual(RosterReader.readRosterFromNode(tree), [])
    }
    test("Live Teams outline ignores row title when no actual name leaf exists") {
        let row = MockAXNode(role: "AXRow", title: "Alice Smith, Muted", children: [MockAXNode(role: "AXStaticText", value: "Muted")])
        try expectEqual(RosterReader.readRosterFromNode(livePane([row])), [])
    }
    test("Matching AX title candidates are accepted") {
        try expectEqual(MeetingDetector.unambiguousMeetingTitle(["Sprint Planning", "Sprint Planning"]), "Sprint Planning")
        try expectEqual(MeetingDetector.unambiguousMeetingTitle([]), nil)
    }
    test("Different AX window titles are not silently assigned to a meeting") {
        try expectEqual(MeetingDetector.unambiguousMeetingTitle(["Sprint Planning", "Sales Chat"]), nil)
        try expectEqual(MeetingDetector.unambiguousMeetingTitle(["Sales Chat", "Sprint Planning"]), nil)
    }
    test("Teams app placeholders are not meeting titles") {
        try expectEqual(MeetingDetector.cleanWindowTitle("Microsoft Teams", source: .teams), nil)
        try expectEqual(MeetingDetector.cleanWindowTitle("Chat | Microsoft Teams", source: .teams), nil)
        try expectEqual(MeetingDetector.cleanWindowTitle("Sprint Planning | Microsoft Teams", source: .teams), "Sprint Planning")
    }
    test("Window-server census separates empty names from placeholder filtering") {
        let windows = [
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "", width: 1000, height: 800, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "Calendar | Microsoft Teams", width: 1200, height: 900, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "Sprint Planning | Microsoft Teams", width: 800, height: 600, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "Chat | Microsoft Teams", width: 400, height: 300, layer: 3),
            MeetingDetector.MeetingWindowInfo(ownerPID: 99, title: "Other Meeting | Microsoft Teams", width: 2000, height: 1000, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: " | Microsoft Teams", width: 100, height: 100, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "Standup | Microsoft Teams", width: 0, height: 100, layer: 0),
        ]
        let census = MeetingDetector.meetingTitleCandidateCensus(from: windows, ownerPIDs: [10], source: .teams)
        try expectEqual(
            census.diagnosticSummary,
            "cgListed=7 cgOwner=6 cgVisible=4 cgNonempty=3 cgUsable=1 cgReject otherOwner=1 wrongLayer=1 zeroArea=1 empty=1 suffixOnly=1 placeholder=1"
        )
        // The census is diagnostic only; it must not guess a title from the
        // size of a Teams chat or channel window.
        let redacted = [
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "", width: 1600, height: 1000, layer: 0),
            MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "", width: 900, height: 700, layer: 0),
        ]
        let emptyNames = MeetingDetector.meetingTitleCandidateCensus(from: redacted, ownerPIDs: [10], source: .teams)
        try expectEqual(emptyNames.nonempty, 0)
        try expectEqual(emptyNames.usable, 0)
        try expectEqual(emptyNames.rejectEmpty, 2)
        try expectEqual(emptyNames.rejectPlaceholder, 0)
        let filtered = [MeetingDetector.MeetingWindowInfo(ownerPID: 10, title: "Chat | Microsoft Teams", width: 900, height: 700, layer: 0)]
        let placeholders = MeetingDetector.meetingTitleCandidateCensus(from: filtered, ownerPIDs: [10], source: .teams)
        try expectEqual(placeholders.nonempty, 1)
        try expectEqual(placeholders.usable, 0)
        try expectEqual(placeholders.rejectPlaceholder, 1)
        try expect(placeholders.diagnosticSummary.contains("Sprint") == false, "census summary must not contain a title")
        try expect(census.diagnosticSummary.contains("Sprint") == false, "census summary must not contain a title")
    }
    test("Metadata refresh fills delayed title and accumulates roster without erasure") {
        var snapshot = MeetingSnapshot(title: "", startedAt: Date(), meetingPID: nil)
        snapshot.mergeMetadata(title: "Sprint Planning", rosterNames: ["Alice Smith"])
        snapshot.mergeMetadata(title: nil, rosterNames: [])
        snapshot.mergeMetadata(title: "Chat", rosterNames: ["alice smith", "Bob Jones"])
        try expectEqual(snapshot.title, "Sprint Planning")
        try expectEqual(snapshot.rosterNames, ["Alice Smith", "Bob Jones"])
    }
    test("Late metadata reaches finished session without losing timing, notes or chat") {
        let path = URL(fileURLWithPath: "/tmp/metadata-test.wav")
        let start = Date(timeIntervalSince1970: 100)
        let session = RecordingSession(title: "", startTime: start, appAudioPath: path, micAudioPath: path, micDelaySeconds: 0.25, rosterNames: ["Alice Smith"], notes: [MeetingNote(offsetSeconds: 2, text: "Keep this note", createdAt: start)], chatMessages: [ChatMessage(offsetSeconds: 3, sender: "Alice Smith", text: "Keep this chat")])
        let snapshot = MeetingSnapshot(title: "Sprint Planning", startedAt: start, meetingPID: nil, rosterNames: ["alice smith", "Bob Jones"])
        let result = snapshot.applyingMetadata(to: session)
        try expectEqual(result.title, "Sprint Planning")
        try expectEqual(result.rosterNames, ["Alice Smith", "Bob Jones"])
        try expectEqual(result.startTime, start)
        try expectEqual(result.appAudioPath, path)
        try expectEqual(result.micDelaySeconds, 0.25)
        try expectEqual(result.notes, session.notes)
        try expectEqual(result.chatMessages, session.chatMessages)
    }
}
