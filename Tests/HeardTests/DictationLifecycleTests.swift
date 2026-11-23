import Foundation
import HeardCore

// Lifecycle tests drive the real DictationManager through its public provider and microphone seams.
// No audio device, model file, clipboard, or key event is touched.

@MainActor
private final class LifecycleEngine: DictationEngine {
    let name: String

    init(name: String) {
        self.name = name
    }

    func transcribe(_ samples: [Float]) async throws -> DictationTranscription {
        throw TestFailure("transcribe failed in \(name)")
    }
}

@MainActor
private final class LifecycleProvider: DictationEngineProvider {
    private(set) var requests: [TranscriptionModel] = []
    var failNextWith: Error?
    var completeImmediately = true
    private var pending: [CheckedContinuation<DictationEngine, Error>] = []

    var pendingCount: Int { pending.count }

    func loadEngine(for selection: TranscriptionModel) async throws -> DictationEngine {
        requests.append(selection)
        if let failure = failNextWith {
            failNextWith = nil
            throw failure
        }
        if completeImmediately {
            return LifecycleEngine(name: String(describing: selection))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    /// Completes the oldest pending load.
    func completeOldest(_ result: Result<DictationEngine, Error>) {
        pending.removeFirst().resume(with: result)
    }
}

@MainActor
private final class LifecycleMic: DictationMicSource {
    var isMicrophoneDenied = false
    var startError: Error?
    /// Delivered synchronously on start, standing in for the first tap buffer. Empty means the tap stalls.
    var firstBuffer: [Float] = [Float](repeating: 0, count: 1_600)
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false
    private var deliver: (@MainActor ([Float]) -> Void)?

    func start(deviceUID: String?, deliver: @escaping @MainActor ([Float]) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        self.deliver = deliver
        if !firstBuffer.isEmpty { deliver(firstBuffer) }
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    func cancel() {
        cancelCount += 1
        isRunning = false
    }

    /// Delivers through the callback the manager handed over, as a tap callback that arrives late would.
    func deliverLate(_ samples: [Float]) {
        deliver?(samples)
    }
}

@MainActor
private func lifecycleWait(_ label: String, _ condition: () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TestFailure("timed out waiting for \(label)")
}

@MainActor
private func lifecycleExpectCancelled(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch DictationError.cancelled {
        return
    }
    throw TestFailure("expected DictationError.cancelled")
}

/// True when `body` throws.
@MainActor
private func lifecycleThrows(_ body: () async throws -> Void) async -> Bool {
    do {
        try await body()
        return false
    } catch {
        return true
    }
}

// MARK: - Decision tests (pure, synchronous)

@MainActor func runDictationDecisionTests() {
    print("\n🧭 Dictation Decision Tests")

    test("a press while a start is pending cancels it, with or without a meeting") {
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: true, stopInFlight: false, managerTranscribing: false, meetingActive: false),
            .cancelPendingStart
        )
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: true, stopInFlight: false, managerTranscribing: false, meetingActive: true),
            .cancelPendingStart
        )
    }

    test("a press while listening stops the session") {
        try expectEqual(
            dictationToggleAction(isDictating: true, startPending: false, stopInFlight: false, managerTranscribing: false, meetingActive: false),
            .stop
        )
    }

    test("a press while a stop is running is ignored") {
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: false, stopInFlight: true, managerTranscribing: false, meetingActive: false),
            .ignore
        )
    }

    test("a press during a meeting does not start dictation") {
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: false, stopInFlight: false, managerTranscribing: false, meetingActive: true),
            .ignore
        )
    }

    test("an idle press with nothing running starts dictation") {
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: false, stopInFlight: false, managerTranscribing: false, meetingActive: false),
            .start
        )
    }

    test("a press while the manager is transcribing is ignored, whatever stopped it") {
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: false, stopInFlight: false, managerTranscribing: true, meetingActive: false),
            .ignore
        )
        try expectEqual(
            dictationToggleAction(isDictating: false, startPending: false, stopInFlight: false, managerTranscribing: true, meetingActive: true),
            .ignore
        )
    }

    test("listening publishes only when no meeting is active, push-to-talk is held, and the start is current") {
        try expect(dictationMayPublishListening(
            managerState: .listening, meetingActive: false, pushToTalkReleased: false, superseded: false
        ))
        try expect(!dictationMayPublishListening(
            managerState: .listening, meetingActive: true, pushToTalkReleased: false, superseded: false
        ))
        try expect(!dictationMayPublishListening(
            managerState: .listening, meetingActive: false, pushToTalkReleased: true, superseded: false
        ))
        try expect(!dictationMayPublishListening(
            managerState: .listening, meetingActive: false, pushToTalkReleased: false, superseded: true
        ))
        try expect(!dictationMayPublishListening(
            managerState: .idle, meetingActive: false, pushToTalkReleased: false, superseded: false
        ))
    }
}

// MARK: - Lifecycle tests (real DictationManager, injected fakes)

@MainActor func runDictationLifecycleTests() async {
    print("\n🎙️ Dictation Lifecycle Tests")

    await testAsync("a failed first load returns to idle, and the next start succeeds without relaunch") {
        let provider = LifecycleProvider()
        provider.failNextWith = TestFailure("model not cached")
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        let failed = await lifecycleThrows { try await dm.start() }
        try expect(failed, "first start should throw")
        try expectEqual(dm.state, .idle)
        try expectEqual(mic.startCount, 0)
        try await dm.start()
        try expectEqual(dm.state, .listening)
        try expectEqual(provider.requests.count, 2)
    }

    await testAsync("an engine that fails to start releases the mic, and the retry keeps the loaded engine") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        mic.startError = TestFailure("engine did not start")
        let dm = DictationManager(provider: provider, mic: mic)
        let failed = await lifecycleThrows { try await dm.start() }
        try expect(failed, "start should throw when the engine does not start")
        try expectEqual(dm.state, .idle)
        try expect(!mic.isRunning, "no capture may be left running")
        try expect(mic.cancelCount >= 1, "the failed start must release the mic")
        mic.startError = nil
        try await dm.start()
        try expectEqual(dm.state, .listening)
        try expectEqual(provider.requests.count, 1)
    }

    await testAsync("cancel during a model load: the late completion starts no mic and reuses the engine") {
        let provider = LifecycleProvider()
        provider.completeImmediately = false
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        let starting = Task { try await dm.start() }
        try await lifecycleWait("load requested") { provider.requests.count == 1 }
        dm.cancelPendingStart()
        try expectEqual(dm.state, .idle)
        provider.completeOldest(.success(LifecycleEngine(name: "late")))
        try await lifecycleExpectCancelled { try await starting.value }
        try expectEqual(mic.startCount, 0, "no mic capture after cancel")
        try expectEqual(dm.state, .idle)
        // The late completion was for the same engine, so it stays loaded.
        provider.completeImmediately = true
        try await dm.start()
        try expectEqual(provider.requests.count, 1)
        try expectEqual(dm.state, .listening)
    }

    await testAsync("a meeting or manual recording during a model load cancels the start before any capture") {
        let provider = LifecycleProvider()
        provider.completeImmediately = false
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        let starting = Task { try await dm.start() }
        try await lifecycleWait("load requested") { provider.requests.count == 1 }
        await dm.requestStop()
        try expectEqual(dm.state, .idle)
        provider.completeOldest(.success(LifecycleEngine(name: "late")))
        try await lifecycleExpectCancelled { try await starting.value }
        try expectEqual(mic.startCount, 0)
    }

    await testAsync("cancel while waiting for the first buffer releases the mic and drops late callbacks") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        mic.firstBuffer = []
        let dm = DictationManager(provider: provider, mic: mic)
        let starting = Task { try await dm.start() }
        try await lifecycleWait("mic started") { mic.startCount == 1 }
        dm.cancelPendingStart()
        try expect(!mic.isRunning, "cancel must release the mic before returning")
        mic.deliverLate([Float](repeating: 0, count: 16_000))
        try expectEqual(dm.bufferedSampleCount, 0, "a late callback must not reach the next session")
        try await lifecycleExpectCancelled { try await starting.value }
        try expectEqual(dm.state, .idle)
    }

    await testAsync("an engine switch during a load: the old engine cannot replace the desired one") {
        let provider = LifecycleProvider()
        provider.completeImmediately = false
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        dm.modelVersion = .v3
        let first = Task { try await dm.start() }
        try await lifecycleWait("v3 load requested") { provider.requests.count == 1 }
        dm.modelVersion = .v2
        try expectEqual(dm.state, .idle)
        let second = Task { try await dm.start() }
        try await lifecycleWait("v2 load requested") { provider.requests.count == 2 }
        // Oldest pending load is the v3 one. Its completion must not publish or start the mic.
        provider.completeOldest(.success(LifecycleEngine(name: "v3-old")))
        try await lifecycleExpectCancelled { try await first.value }
        try expectEqual(dm.state, .loading)
        try expectEqual(mic.startCount, 0)
        provider.completeOldest(.success(LifecycleEngine(name: "v2")))
        try await second.value
        try expectEqual(dm.state, .listening)
        try expectEqual(mic.startCount, 1)
        try expectEqual(provider.requests, [.v3, .v2])
    }

    await testAsync("rapid start and stop cycles leave no capture running and no stuck state") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        for _ in 0..<20 {
            let attempt = Task { try await dm.start() }
            try await lifecycleWait("start settled") { dm.state != .idle }
            await dm.requestStop()
            _ = try? await attempt.value
        }
        try expectEqual(dm.state, .idle)
        try expect(!mic.isRunning)
        try expectEqual(provider.requests.count, 1)
    }

    await testAsync("a second start while listening is refused and leaves the session running") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        try await dm.start()
        let refused = await lifecycleThrows { try await dm.start() }
        try expect(refused, "a second start must be refused")
        try expectEqual(dm.state, .listening)
        try expect(mic.isRunning, "the running session must not be torn down")
        try expectEqual(mic.cancelCount, 0)
    }

    await testAsync("a start cancelled before it first runs touches neither the model nor the mic") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        let task = Task { try await dm.start() }
        task.cancel()
        let refused = await lifecycleThrows { try await task.value }
        try expect(refused, "a pre-cancelled start must throw")
        try expectEqual(provider.requests.count, 0)
        try expectEqual(mic.startCount, 0)
        try expectEqual(dm.state, .idle)
        try await dm.start()
        try expectEqual(dm.state, .listening)
    }

    await testAsync("a stop aimed at a stale session leaves the current session running") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        let session = try await dm.start()
        await dm.requestStop(session: session &+ 1)
        try expectEqual(dm.state, .listening)
        try expect(mic.isRunning, "a stale stop must not touch the current session")
        await dm.requestStop(session: session)
        try expectEqual(dm.state, .idle)
    }

    await testAsync("a denied microphone is refused before any model load") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        mic.isMicrophoneDenied = true
        let dm = DictationManager(provider: provider, mic: mic)
        let refused = await lifecycleThrows { try await dm.start() }
        try expect(refused)
        try expectEqual(provider.requests.count, 0)
        try expectEqual(dm.state, .idle)
    }

    await testAsync("preload and start share one engine load") {
        let provider = LifecycleProvider()
        provider.completeImmediately = false
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        dm.preloadModelsInBackground()
        try await lifecycleWait("preload requested") { provider.requests.count == 1 }
        let starting = Task { try await dm.start() }
        try await lifecycleWait("start waiting for the load") { dm.state == .loading }
        try expectEqual(provider.requests.count, 1)
        provider.completeOldest(.success(LifecycleEngine(name: "v2")))
        try await starting.value
        try expectEqual(provider.requests.count, 1)
        try expectEqual(dm.state, .listening)
    }

    await testAsync("a failed preload is silent in the manager; only start reports failures") {
        let provider = LifecycleProvider()
        provider.failNextWith = TestFailure("preload failed")
        let mic = LifecycleMic()
        let dm = DictationManager(provider: provider, mic: mic)
        var messages: [String] = []
        dm.onFailure = { messages.append($0) }
        dm.preloadModelsInBackground()
        try await lifecycleWait("preload requested") { provider.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        try expect(messages.isEmpty, "a preload failure must not surface as a dictation error")
        try expectEqual(dm.state, .idle)
    }

    await testAsync("a transcription failure is reported through onFailure, and the manager returns to idle") {
        let provider = LifecycleProvider()
        let mic = LifecycleMic()
        mic.firstBuffer = [Float](repeating: 0, count: 16_000)
        let dm = DictationManager(provider: provider, mic: mic)
        var messages: [String] = []
        dm.onFailure = { messages.append($0) }
        try await dm.start()
        await dm.stop()
        try expectEqual(dm.state, .idle)
        try expectEqual(messages.count, 1)
        try expect(messages.first?.hasPrefix("Dictation couldn't transcribe") == true, "unexpected message: \(messages)")
    }
}
