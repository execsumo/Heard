import AppKit
import Foundation
import HeardCore

private func snapshot(_ text: String) -> PasteboardItemSnapshot {
    PasteboardItemSnapshot(representations: [
        .init(type: "com.heard.tests.text", data: Data(text.utf8)),
    ])
}

/// Text of the first representation of the first item, or nil when the pasteboard is empty.
private func text(of items: [PasteboardItemSnapshot]) -> String? {
    guard let data = items.first?.representations.first?.data else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Items as type-to-data dictionaries, so comparisons ignore representation order.
private func contents(_ items: [PasteboardItemSnapshot]) -> [[String: Data]] {
    items.map { item in
        Dictionary(item.representations.map { ($0.type, $0.data) }, uniquingKeysWith: { first, _ in first })
    }
}

/// In-memory pasteboard. Every write changes the change count, as NSPasteboard does.
private final class FakePasteboard: PasteboardBackend {
    private(set) var changeCount = 0
    private var items: [PasteboardItemSnapshot] = []

    func readItems() -> [PasteboardItemSnapshot] {
        items
    }

    @discardableResult
    func writeItems(_ newItems: [PasteboardItemSnapshot]) -> Int {
        items = newItems
        changeCount += 1
        return changeCount
    }

    /// Stands in for the user or another app copying something.
    func simulateUserCopy(_ text: String) {
        writeItems([snapshot(text)])
    }
}

/// Holds restores instead of running them, so tests choose the order.
private final class ManualScheduler {
    private(set) var pending: [(delay: TimeInterval, work: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((delay: delay, work: work))
    }

    /// Runs and removes the pending restore at `index`.
    func run(at index: Int) {
        let entry = pending.remove(at: index)
        entry.work()
    }
}

@MainActor func runDictationDeliveryTests() {
    print("\n📋 Dictation Delivery Tests")

    test("Clipboard restore returns every item and representation on a private pasteboard") {
        // Private named pasteboard, never the general clipboard. Custom types only, so the
        // pasteboard server does not add synthesized types that would differ after the round trip.
        let privateBoard = NSPasteboard(name: NSPasteboard.Name("com.heard.tests.\(UUID().uuidString)"))
        defer { privateBoard.releaseGlobally() }
        let backend = SystemPasteboard(privateBoard)
        let original = [
            PasteboardItemSnapshot(representations: [
                .init(type: "com.heard.tests.text", data: Data("hello".utf8)),
                .init(type: "com.heard.tests.rich", data: Data("<b>hello</b>".utf8)),
                .init(type: "com.heard.tests.binary", data: Data([0x00, 0xFF, 0x7F])),
            ]),
            PasteboardItemSnapshot(representations: [
                .init(type: "com.heard.tests.binary", data: Data([0x49, 0x49])),
            ]),
        ]
        backend.writeItems(original)
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: backend, schedule: scheduler.schedule)

        let lease = controller.place("transcript")
        controller.scheduleRestore(lease, after: 0.5)
        try expectEqual(text(of: backend.readItems()), "transcript")
        scheduler.run(at: 0)
        try expectEqual(contents(backend.readItems()), contents(original), "every item and type must come back")
    }

    test("An empty clipboard is restored as empty") {
        let board = FakePasteboard()
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        let lease = controller.place("transcript")
        controller.scheduleRestore(lease, after: 0.5)
        scheduler.run(at: 0)
        try expect(board.readItems().isEmpty, "a transcript must not stay on an empty clipboard")
    }

    test("A copy made during the pending restore is kept") {
        let board = FakePasteboard()
        board.simulateUserCopy("original")
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        let lease = controller.place("transcript")
        controller.scheduleRestore(lease, after: 0.5)
        board.simulateUserCopy("user copy")
        scheduler.run(at: 0)
        try expectEqual(text(of: board.readItems()), "user copy")
    }

    test("Overlapping pastes restore the original clipboard, never an earlier transcript") {
        let board = FakePasteboard()
        board.simulateUserCopy("original")
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        let first = controller.place("first")
        controller.scheduleRestore(first, after: 0.5)
        let second = controller.place("second")
        controller.scheduleRestore(second, after: 0.5)
        try expectEqual(text(of: board.readItems()), "second")

        scheduler.run(at: 0)  // first's restore is superseded: it must write neither "first" nor "original"
        try expectEqual(text(of: board.readItems()), "second")

        scheduler.run(at: 0)  // second's restore puts the user's original back
        try expectEqual(text(of: board.readItems()), "original")
    }

    test("A stale restore cannot clobber a newer lease, even when the newer restore runs first") {
        let board = FakePasteboard()
        board.simulateUserCopy("original")
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        let first = controller.place("first")
        controller.scheduleRestore(first, after: 0.5)
        let second = controller.place("second")
        controller.scheduleRestore(second, after: 0.5)

        scheduler.run(at: 1)  // newer restore first
        try expectEqual(text(of: board.readItems()), "original")
        scheduler.run(at: 0)  // stale restore is a no-op
        try expectEqual(text(of: board.readItems()), "original")
    }

    test("A user copy between overlapping pastes becomes the baseline for the newer paste") {
        let board = FakePasteboard()
        board.simulateUserCopy("original")
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        let first = controller.place("first")
        controller.scheduleRestore(first, after: 0.5)
        board.simulateUserCopy("user copy")
        let second = controller.place("second")
        controller.scheduleRestore(second, after: 0.5)

        scheduler.run(at: 0)  // superseded
        try expectEqual(text(of: board.readItems()), "second")
        scheduler.run(at: 0)  // newer restore keeps the user's copy, not "original" or "first"
        try expectEqual(text(of: board.readItems()), "user copy")
    }

    test("Repeated pastes each restore the original clipboard") {
        let board = FakePasteboard()
        board.simulateUserCopy("original")
        let scheduler = ManualScheduler()
        let controller = PasteboardLeaseController(backend: board, schedule: scheduler.schedule)

        for round in 1...2 {
            let lease = controller.place("transcript \(round)")
            controller.scheduleRestore(lease, after: 0.5)
            scheduler.run(at: 0)
            try expectEqual(text(of: board.readItems()), "original", "round \(round)")
        }
    }

    test("Hotkey registration status maps each attempt outcome") {
        // -9878 is eventHotKeyExistsErr. Only a later registration or deactivation changes a failed status.
        try expectEqual(HotkeyRegistrationStatus.after(.failed(-9878)), .failed(-9878))
        try expectEqual(HotkeyRegistrationStatus.after(.registered), .registered)
        try expectEqual(HotkeyRegistrationStatus.after(.deactivated), .inactive)
    }
}
