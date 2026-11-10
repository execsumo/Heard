import ApplicationServices
import Foundation
import HeardCore

// MARK: - PermissionCenter Logic Tests
//
// These tests cover the combinatorial logic that decides which PermissionState to
// display for Screen Recording and Accessibility. They cannot exercise the live
// OS APIs (CGPreflightScreenCaptureAccess, SCShareableContent, AXIsProcessTrusted)
// but they DO cover every branch of the fix for stale-TCC caching on macOS 15+:
//
//  Screen Recording
//  ┌──────────┬──────────┬─────────────────────────────────────────────┐
//  │ sync     │ live     │ expected          │ scenario                 │
//  ├──────────┼──────────┼───────────────────┼──────────────────────────│
//  │ true     │ false    │ .granted          │ granted at launch        │
//  │ false    │ true     │ .granted          │ granted while running ← fixed bug │
//  │ true     │ true     │ .granted          │ both agree               │
//  │ false    │ false    │ .recommended      │ not granted              │
//  └──────────┴──────────┴───────────────────┴──────────────────────────┘
//
//  Accessibility: the trust check confirms the grant; a system-wide AX read
//  alone cannot prove access to other apps. API-disabled indicates denial.

func runPermissionCenterTests() {
    print("\n🔐 PermissionCenter Logic Tests")

    // MARK: Screen Recording

    test("Screen recording: sync=true, live=false → granted (app-launch path)") {
        let state = PermissionCenter.screenCapturePermissionState(syncGranted: true, liveGranted: false)
        try expectEqual(state, .granted)
    }

    test("Screen recording: sync=false, live=true → granted (regression: granted while running)") {
        // This is the case that was broken: CGPreflightScreenCaptureAccess() returned a
        // stale false after the user granted in System Settings while the app was running.
        let state = PermissionCenter.screenCapturePermissionState(syncGranted: false, liveGranted: true)
        try expectEqual(state, .granted)
    }

    test("Screen recording: sync=true, live=true → granted") {
        let state = PermissionCenter.screenCapturePermissionState(syncGranted: true, liveGranted: true)
        try expectEqual(state, .granted)
    }

    test("Screen recording: sync=false, live=false → not granted") {
        let state = PermissionCenter.screenCapturePermissionState(syncGranted: false, liveGranted: false)
        try expectEqual(state, .recommended)
    }

    // MARK: Accessibility

    test("Accessibility: trusted process is granted") {
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: true, liveError: .cannotComplete), .granted)
    }

    test("Accessibility: system-wide success does not prove target-app access") {
        // Observed during a meeting: this query succeeded while every Teams
        // window query returned apiDisabled and AXIsProcessTrusted was false.
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: false, liveError: .success), .unverified)
    }

    test("Accessibility: no focused value does not confirm target-app access") {
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: false, liveError: .noValue), .unverified)
    }

    test("Accessibility: API disabled is not granted") {
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: false, liveError: .apiDisabled), .recommended)
    }

    test("Accessibility: timeout is unverified, not granted") {
        // Observed in both trusted and untrusted processes in the same meeting.
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: false, liveError: .cannotComplete), .unverified)
    }

    test("Accessibility: unrelated AX errors are unverified") {
        try expectEqual(PermissionCenter.accessibilityPermissionState(isTrusted: false, liveError: .failure), .unverified)
    }

    // MARK: Screen Recording grant cache (revocation while app not running)

    test("Grant cache: cached grant from previous session is trusted at launch") {
        let cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true)
        try expect(cache.isGranted, "cached grant should show as granted during reconfirmation")
        try expect(!cache.confirmedThisSession)
    }

    test("Grant cache: no cache and failed probes → never granted, no persist action") {
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: false, reconfirmBudget: 3)
        for _ in 0..<10 {
            try expectEqual(cache.recordProbe(granted: false), nil)
        }
        try expect(!cache.isGranted)
    }

    test("Grant cache: successful probe confirms, persists once, and is sticky") {
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: false)
        try expectEqual(cache.recordProbe(granted: true), .markGranted)
        try expect(cache.isGranted)
        // Later stale-false probes within the session must not downgrade or re-persist.
        try expectEqual(cache.recordProbe(granted: false), nil)
        try expectEqual(cache.recordProbe(granted: true), nil)
        try expect(cache.isGranted)
    }

    test("Grant cache: cached grant clears once the reconfirmation budget is exhausted") {
        // The revocation-while-not-running case: user revoked in System Settings, then
        // relaunched Heard. Every probe fails; after the budget runs out the cache must
        // clear (and persist false) so the UI stops showing a stale "Granted".
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true, reconfirmBudget: 3)
        try expectEqual(cache.recordProbe(granted: false), nil)
        try expect(cache.isGranted, "still within the reconfirmation grace window")
        try expectEqual(cache.recordProbe(granted: false), nil)
        try expectEqual(cache.recordProbe(granted: false), .clearGrant)
        try expect(!cache.isGranted)
        // Further failed probes are quiet — no repeated UserDefaults writes.
        try expectEqual(cache.recordProbe(granted: false), nil)
    }

    test("Grant cache: probe success within the budget confirms and stops the countdown") {
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true, reconfirmBudget: 3)
        try expectEqual(cache.recordProbe(granted: false), nil)
        try expectEqual(cache.recordProbe(granted: true), .markGranted)
        try expect(cache.confirmedThisSession)
        // Sticky for the rest of the session even if later probes go stale-false.
        for _ in 0..<10 {
            try expectEqual(cache.recordProbe(granted: false), nil)
        }
        try expect(cache.isGranted)
    }

    test("Grant cache: re-grant after downgrade re-confirms and re-persists") {
        // False negatives outlasted the budget (e.g. no titled windows on screen for the
        // whole grace window). The next successful probe must recover the granted state.
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true, reconfirmBudget: 1)
        try expectEqual(cache.recordProbe(granted: false), .clearGrant)
        try expect(!cache.isGranted)
        try expectEqual(cache.recordProbe(granted: true), .markGranted)
        try expect(cache.isGranted)
    }

    test("Grant cache: authoritative false clears the cached grant immediately") {
        // SCShareableContent reads the live TCC database, so its false is definitive —
        // no reason to wait out the remaining budget.
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true, reconfirmBudget: 10)
        try expectEqual(cache.recordAuthoritativeProbe(granted: false), .clearGrant)
        try expect(!cache.isGranted)
    }

    test("Grant cache: authoritative false never downgrades a session-confirmed grant") {
        // Revocations only take effect after restart, so a grant confirmed this session
        // outranks even an authoritative false (which can only be a mid-session revoke
        // that won't apply until relaunch).
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: false)
        try expectEqual(cache.recordProbe(granted: true), .markGranted)
        try expectEqual(cache.recordAuthoritativeProbe(granted: false), nil)
        try expect(cache.isGranted)
    }

    test("Grant cache: authoritative true confirms like a normal probe") {
        var cache = ScreenCaptureGrantCache(cachedFromPreviousSession: true, reconfirmBudget: 3)
        try expectEqual(cache.recordAuthoritativeProbe(granted: true), .markGranted)
        try expect(cache.confirmedThisSession)
    }
}
