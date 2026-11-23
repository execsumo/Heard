import Foundation
import HeardCore

// MARK: - Dictation readiness: single authority, single-flight download, identity-gated outcomes
// Uses an injected loader and cache check only. Never touches the real model cache or the network.

private enum FakeLoadError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "fake load failure" }
}

/// Controllable stand-in for the dictation engine loader and its cache. Runs on the main actor, like the manager.
@MainActor
private final class FakeDictationEngines {
    private(set) var cached: Set<TranscriptionModel> = []
    private(set) var calls: [TranscriptionModel] = []
    private var pending: [(engine: TranscriptionModel, continuation: CheckedContinuation<Void, Error>)] = []

    var pendingCount: Int { pending.count }

    func isCached(_ engine: TranscriptionModel) -> Bool { cached.contains(engine) }

    func setCached(_ engine: TranscriptionModel) { cached.insert(engine) }

    func load(_ engine: TranscriptionModel) async throws {
        calls.append(engine)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.append((engine: engine, continuation: continuation))
        }
    }

    /// Completes the oldest pending load without marking the engine cached: the load returns, but the files are incomplete.
    func completeWithoutCache() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume()
    }

    /// Completes the oldest pending load. Success marks the engine cached, as a real download would.
    func complete(success: Bool) {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        if success {
            cached.insert(next.engine)
            next.continuation.resume()
        } else {
            next.continuation.resume(throwing: FakeLoadError.failed)
        }
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private func makeManager(_ fake: FakeDictationEngines, onReady: @escaping @MainActor () -> Void = {}) -> ModelDownloadManager {
    let manager = ModelDownloadManager(
        catalog: ModelCatalog(),
        dictationLoader: { engine in try await fake.load(engine) },
        dictationCached: { engine in fake.isCached(engine) }
    )
    manager.onDictationEngineReady = onReady
    return manager
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
func runDictationReadinessTests() async {
    print("\n📥 Dictation Readiness Tests")

    await testAsync("dictation off: readiness is notRequired and no download starts") {
        let fake = FakeDictationEngines()
        let manager = makeManager(fake)
        manager.transcriptionModel = .unified
        manager.downloadDictationEngineIfNeeded()
        try expectEqual(manager.dictationReadiness, .notRequired)
        try expectEqual(fake.calls.count, 0)
    }

    await testAsync("enabling does not download; explicit trigger does; completion publishes ready once") {
        let fake = FakeDictationEngines()
        let ready = Counter()
        let manager = makeManager(fake) { ready.value += 1 }
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        try expectEqual(manager.dictationReadiness, .notDownloaded)
        try expectEqual(fake.calls.count, 0)

        manager.downloadDictationEngineIfNeeded()
        try expect(await waitUntil { fake.pendingCount == 1 }, "the v2 load should start")
        try expectEqual(manager.dictationReadiness, .downloading)

        fake.complete(success: true)
        try expect(await waitUntil { manager.dictationReadiness == .ready }, "readiness should become ready")
        try expectEqual(ready.value, 1)
        try expectEqual(fake.calls, [.v2])
    }

    await testAsync("single flight: concurrent triggers share one load") {
        let fake = FakeDictationEngines()
        let manager = makeManager(fake)
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        let first = Task { try await manager.prepareDictationEngine() }
        manager.downloadDictationEngineIfNeeded()
        let second = Task { try await manager.prepareDictationEngine() }
        try expect(await waitUntil { fake.pendingCount == 1 }, "one load should start")
        fake.complete(success: true)
        try await first.value
        try await second.value
        try expectEqual(fake.calls.count, 1)
    }

    await testAsync("failure is reported as failed, not downloading; explicit retry starts a new load") {
        let fake = FakeDictationEngines()
        let manager = makeManager(fake)
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        let attempt = Task { try await manager.prepareDictationEngine() }
        try expect(await waitUntil { fake.pendingCount == 1 }, "the load should start")
        fake.complete(success: false)
        var threw = false
        do { try await attempt.value } catch { threw = true }
        try expect(threw, "prepare must throw when the load fails")
        try expectEqual(manager.dictationReadiness, .failed("fake load failure"))

        let retry = Task { try await manager.prepareDictationEngine() }
        try expect(await waitUntil { fake.pendingCount == 1 }, "retry should start a new load")
        try expectEqual(manager.dictationReadiness, .downloading)
        fake.complete(success: true)
        try await retry.value
        try expectEqual(manager.dictationReadiness, .ready)
        try expectEqual(fake.calls, [.v2, .v2])
    }

    await testAsync("disabling mid-download discards the late completion") {
        let fake = FakeDictationEngines()
        let ready = Counter()
        let manager = makeManager(fake) { ready.value += 1 }
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        manager.downloadDictationEngineIfNeeded()
        try expect(await waitUntil { fake.pendingCount == 1 }, "the load should start")

        manager.dictationEnabled = false
        try expectEqual(manager.dictationReadiness, .notRequired)
        fake.complete(success: true)
        try await Task.sleep(for: .milliseconds(20))
        try expectEqual(manager.dictationReadiness, .notRequired)
        try expectEqual(ready.value, 0)

        manager.dictationEnabled = true
        try expectEqual(manager.dictationReadiness, .ready)
        try expectEqual(fake.calls.count, 1)
    }

    await testAsync("changing engine mid-download ignores the old engine's completion") {
        let fake = FakeDictationEngines()
        let ready = Counter()
        let manager = makeManager(fake) { ready.value += 1 }
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        manager.downloadDictationEngineIfNeeded()
        try expect(await waitUntil { fake.pendingCount == 1 }, "the v2 load should start")

        manager.transcriptionModel = .v3
        try expectEqual(manager.dictationReadiness, .notDownloaded)
        fake.complete(success: true)
        try await Task.sleep(for: .milliseconds(20))
        try expectEqual(manager.dictationReadiness, .notDownloaded)
        try expectEqual(ready.value, 0)
        try expect(!fake.isCached(.v3), "v3 must not count as cached after the v2 completion")
    }

    await testAsync("prepare never reports a superseded engine as prepared") {
        let fake = FakeDictationEngines()
        let manager = makeManager(fake)
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        let prepare = Task { try await manager.prepareDictationEngine() }
        try expect(await waitUntil { fake.pendingCount == 1 }, "the v2 load should start")

        manager.transcriptionModel = .v3
        fake.complete(success: true)
        var threw = false
        do { try await prepare.value } catch { threw = true }
        try expect(threw, "a superseded prepare must not report success")
        try expectEqual(manager.dictationReadiness, .notDownloaded)
    }

    await testAsync("cached engine is ready with no load, and prepare returns at once") {
        let fake = FakeDictationEngines()
        fake.setCached(.v2)
        let manager = makeManager(fake)
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        try expectEqual(manager.dictationReadiness, .ready)
        manager.downloadDictationEngineIfNeeded()
        try await manager.prepareDictationEngine()
        try expectEqual(fake.calls.count, 0)
    }

    await testAsync("v3 selection checks and loads v3 only") {
        let fake = FakeDictationEngines()
        fake.setCached(.v2)
        let manager = makeManager(fake)
        manager.transcriptionModel = .v3
        manager.dictationEnabled = true
        try expectEqual(manager.dictationReadiness, .notDownloaded)

        manager.downloadDictationEngineIfNeeded()
        try expect(await waitUntil { fake.pendingCount == 1 }, "the v3 load should start")
        fake.complete(success: true)
        try expect(await waitUntil { manager.dictationReadiness == .ready }, "v3 should become ready")
        try expectEqual(fake.calls, [.v3])
    }

    await testAsync("load returns but cache stays incomplete: failed(notReady), prepare throws, no ready callback") {
        let fake = FakeDictationEngines()
        let ready = Counter()
        let manager = makeManager(fake) { ready.value += 1 }
        manager.transcriptionModel = .unified
        manager.dictationEnabled = true
        let prepare = Task { try await manager.prepareDictationEngine() }
        try expect(await waitUntil { fake.pendingCount == 1 }, "the v2 load should start")
        fake.completeWithoutCache()
        var thrown: Error?
        do { try await prepare.value } catch { thrown = error }
        guard let readiness = thrown as? DictationReadinessError, readiness == .notReady else {
            throw TestFailure("prepare must throw DictationReadinessError.notReady, got \(String(describing: thrown))")
        }
        try expectEqual(manager.dictationReadiness, .failed(DictationReadinessError.notReady.localizedDescription))
        try expectEqual(ready.value, 0)
    }
}
