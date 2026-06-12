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
//  Accessibility
//  ┌──────────┬──────────┬───────────────────┬──────────────────────────┐
//  │ trusted  │ live     │ expected          │ scenario                 │
//  ├──────────┼──────────┼───────────────────┼──────────────────────────│
//  │ true     │ false    │ .granted          │ TCC returned live true   │
//  │ false    │ true     │ .granted          │ AX fallback confirms ← fixed bug │
//  │ true     │ true     │ .granted          │ both agree               │
//  │ false    │ false    │ .recommended      │ not granted              │
//  └──────────┴──────────┴───────────────────┴──────────────────────────┘

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

    test("Accessibility: isTrusted=true, liveGranted=false → granted (AXIsProcessTrusted path)") {
        let state = PermissionCenter.accessibilityPermissionState(isTrusted: true, liveGranted: false)
        try expectEqual(state, .granted)
    }

    test("Accessibility: isTrusted=false, liveGranted=true → granted (regression: AX fallback confirms)") {
        // This is the case that was broken: AXIsProcessTrusted() returned stale false
        // while a live AX API call confirmed the process actually has permission.
        let state = PermissionCenter.accessibilityPermissionState(isTrusted: false, liveGranted: true)
        try expectEqual(state, .granted)
    }

    test("Accessibility: isTrusted=true, liveGranted=true → granted") {
        let state = PermissionCenter.accessibilityPermissionState(isTrusted: true, liveGranted: true)
        try expectEqual(state, .granted)
    }

    test("Accessibility: isTrusted=false, liveGranted=false → not granted") {
        // Both kAXErrorAPIDisabled and kAXErrorNotTrusted produce liveGranted=false.
        let state = PermissionCenter.accessibilityPermissionState(isTrusted: false, liveGranted: false)
        try expectEqual(state, .recommended)
    }

    test("Accessibility: kAXErrorNoValue (no focused app) still counts as live-granted") {
        // kAXErrorNoValue means the process HAS permission but there is no focused element
        // right now. It must not be mistaken for a permission denial.
        // We simulate this by passing liveGranted=true (the caller computes this from the
        // AXError: err != .apiDisabled && err != .notTrusted).
        let state = PermissionCenter.accessibilityPermissionState(isTrusted: false, liveGranted: true)
        try expectEqual(state, .granted)
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
