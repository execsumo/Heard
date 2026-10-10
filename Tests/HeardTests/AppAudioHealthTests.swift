import Foundation
import HeardCore

// MARK: - AppAudioHealthMonitor Tests
//
// The monitor replaces the old one-shot T+2s self-test, which flagged a recording as
// "mic only" whenever nobody spoke in the first few seconds. These cover: no warning
// for quiet starts or quiet meetings, rebuilds before warnings, mid-session dead taps,
// and the warning clearing itself when audio returns.

func runAppAudioHealthTests() {
    print("\n🎧 AppAudioHealthMonitor Tests")

    /// Feed `count` 2 s ticks with the same observations; return every action emitted.
    func run(_ monitor: inout AppAudioHealthMonitor, ticks count: Int,
             audio: Bool = false, callbacks: Bool = true, outputActive: Bool = true) -> [AppAudioHealthMonitor.Action] {
        var all: [AppAudioHealthMonitor.Action] = []
        for _ in 0..<count {
            all += monitor.tick(seconds: 2, receivedAudio: audio, callbacksFiring: callbacks,
                                meetingAppOutputActive: outputActive)
        }
        return all
    }

    test("Health: audio on the first tick confirms capture with no rebuild") {
        var m = AppAudioHealthMonitor()
        try expectEqual(run(&m, ticks: 1, audio: true), [.confirmCapture])
        try expectEqual(run(&m, ticks: 5, audio: true), [])
    }

    test("Health: silent start rebuilds fresh once at the startup check") {
        var m = AppAudioHealthMonitor()
        try expectEqual(run(&m, ticks: 1), [.rebuildFresh])
        try expectEqual(run(&m, ticks: 1), [])
    }

    test("Health: a quiet first minute does not warn before 60 s (regression: 4 s false alarm)") {
        var m = AppAudioHealthMonitor()
        let actions = run(&m, ticks: 29)   // 58 s
        try expect(!actions.contains(.flagSilent), "warned too early: \(actions)")
        try expect(!m.isFlagged)
    }

    test("Health: sustained silence while the app plays rebuilds at 30 s, then warns at 60 s") {
        var m = AppAudioHealthMonitor()
        _ = run(&m, ticks: 1)                         // startup rebuild (2 s)
        let toRebuild = run(&m, ticks: 15)            // 30 s of counted silence
        try expectEqual(toRebuild, [.rebuildPreservingFile])
        let toWarn = run(&m, ticks: 15)               // 60 s
        try expectEqual(toWarn, [.flagSilent])
        try expect(m.looksLikePermissionDenied)
    }

    test("Health: silence while the meeting app plays nothing never warns") {
        var m = AppAudioHealthMonitor()
        let actions = run(&m, ticks: 300, outputActive: false)   // 10 minutes in a lobby
        try expectEqual(actions, [.rebuildFresh])
        try expect(!m.isFlagged)
    }

    test("Health: warning clears itself when audio arrives") {
        var m = AppAudioHealthMonitor()
        _ = run(&m, ticks: 31)                        // startup tick + 60 s
        try expect(m.isFlagged)
        try expectEqual(run(&m, ticks: 1, audio: true), [.confirmCapture, .clearFlag])
        try expect(!m.isFlagged)
        try expect(!m.looksLikePermissionDenied)
    }

    test("Health: tap going silent mid-session rebuilds while keeping the file") {
        var m = AppAudioHealthMonitor()
        _ = run(&m, ticks: 60, audio: true)
        let actions = run(&m, ticks: 15)              // 30 s of zeros
        try expectEqual(actions, [.rebuildPreservingFile])
        try expect(!m.looksLikePermissionDenied, "audio was heard earlier — not a denial")
    }

    test("Health: one rebuild per silent stretch, a new stretch can rebuild again") {
        var m = AppAudioHealthMonitor()
        _ = run(&m, ticks: 1, audio: true)
        try expectEqual(run(&m, ticks: 40).filter { $0 == .rebuildPreservingFile }.count, 1)
        _ = run(&m, ticks: 1, audio: true)
        try expectEqual(run(&m, ticks: 15), [.rebuildPreservingFile])
    }

    test("Health: stopped callbacks rebuild after 10 s even if the app is quiet") {
        var m = AppAudioHealthMonitor()
        _ = run(&m, ticks: 1, audio: true)
        try expectEqual(run(&m, ticks: 5, callbacks: false, outputActive: false), [.rebuildPreservingFile])
    }

    test("Health: rebuilds are capped per recording") {
        var config = AppAudioHealthMonitor.Config()
        config.maxRebuilds = 2
        var m = AppAudioHealthMonitor(config: config)
        _ = run(&m, ticks: 1, audio: true)
        let actions = run(&m, ticks: 100, callbacks: false)
        try expectEqual(actions.filter { $0 == .rebuildPreservingFile }.count, 2)
        try expectEqual(m.rebuildCount, 2)
    }

    // MARK: System Audio permission state

    test("System Audio: confirmed audio → granted") {
        try expectEqual(PermissionCenter.audioCaptureState(granted: true, unverified: false), .granted)
    }

    test("System Audio: tap heard only silence → unverified (regression: showed Granted)") {
        try expectEqual(PermissionCenter.audioCaptureState(granted: false, unverified: true), .unverified)
    }

    test("System Audio: never confirmed → not granted") {
        try expectEqual(PermissionCenter.audioCaptureState(granted: false, unverified: false), .recommended)
    }
}
