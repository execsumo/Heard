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
}
