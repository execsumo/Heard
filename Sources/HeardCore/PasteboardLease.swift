import Foundation

/// One pasteboard item as (type, data) representations. A snapshot keeps every readable
/// representation of every item, so restoring it returns the user's clipboard unchanged.
public struct PasteboardItemSnapshot: Equatable {
    public struct Representation: Equatable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public var representations: [Representation]

    public init(representations: [Representation]) {
        self.representations = representations
    }
}

/// The pasteboard as the lease logic sees it. The production adapter wraps NSPasteboard;
/// tests use a private named pasteboard or an in-memory fake.
public protocol PasteboardBackend: AnyObject {
    var changeCount: Int { get }
    /// Every item with every readable representation. Items with nothing readable are omitted.
    func readItems() -> [PasteboardItemSnapshot]
    /// Replaces the contents. An empty array leaves the pasteboard empty. Returns the change count after the write.
    @discardableResult
    func writeItems(_ items: [PasteboardItemSnapshot]) -> Int
}

/// Owns the pasteboard while a transcript paste is pending.
///
/// `place` snapshots the user's clipboard once for a chain of overlapping pastes, writes the
/// transcript, and returns a lease token. `scheduleRestore` puts the baseline back only if the
/// lease is still the newest one and the pasteboard change count still matches the one the lease
/// recorded after its own write. Anything else (a newer paste, or a copy by the user or another
/// app) leaves the pasteboard alone. Main thread only.
public final class PasteboardLeaseController {
    public typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    /// Token for one transcript write. Only the newest token can restore the baseline.
    public struct Lease: Equatable {
        fileprivate let token: UInt64
    }

    private struct Active {
        let token: UInt64
        /// Change count the pasteboard had right after this lease wrote the transcript.
        let ownedChangeCount: Int
        /// The user's clipboard, captured before the first transcript of the chain.
        let baseline: [PasteboardItemSnapshot]
    }

    private static let plainTextType = "public.utf8-plain-text"

    private let backend: PasteboardBackend
    private let schedule: Scheduler
    private var lastToken: UInt64 = 0
    private var active: Active?

    public init(backend: PasteboardBackend, schedule: @escaping Scheduler) {
        self.backend = backend
        self.schedule = schedule
    }

    /// Writes `text` and returns the lease that owns the pasteboard until it is restored.
    public func place(_ text: String) -> Lease {
        let baseline: [PasteboardItemSnapshot]
        if let active, backend.changeCount == active.ownedChangeCount {
            // Our previous transcript still owns the pasteboard: keep the user's original clipboard.
            baseline = active.baseline
        } else {
            // First paste, or the pasteboard changed since our last write: capture it now.
            baseline = backend.readItems()
        }

        lastToken &+= 1
        let transcript = PasteboardItemSnapshot(representations: [
            .init(type: Self.plainTextType, data: Data(text.utf8)),
        ])
        let ownedChangeCount = backend.writeItems([transcript])
        active = Active(token: lastToken, ownedChangeCount: ownedChangeCount, baseline: baseline)
        return Lease(token: lastToken)
    }

    /// Restores the baseline after `delay`, unless the lease was superseded or the pasteboard changed since it wrote.
    public func scheduleRestore(_ lease: Lease, after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            self?.restore(lease)
        }
    }

    private func restore(_ lease: Lease) {
        // Superseded by a newer lease, or already restored: the newer lease owns the pasteboard.
        guard let current = active, current.token == lease.token else { return }
        active = nil
        // Someone copied after our write: keep their copy.
        guard backend.changeCount == current.ownedChangeCount else { return }
        // An empty baseline clears the pasteboard, so a transcript never stays behind.
        backend.writeItems(current.baseline)
    }
}
