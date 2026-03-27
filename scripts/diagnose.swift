#!/usr/bin/env swift
// Diagnostic script: run while in a Teams meeting to see what Lurk sees.

import AppKit
import IOKit.pwr_mgt

print("=== Running Apps (potential Teams matches) ===")
let apps = NSWorkspace.shared.runningApplications
let teamsLike = apps.filter { app in
    let name = app.localizedName ?? ""
    let bundleID = app.bundleIdentifier ?? ""
    return name.lowercased().contains("teams") || bundleID.lowercased().contains("teams")
}

if teamsLike.isEmpty {
    print("  No running apps with 'teams' in name or bundle ID!")
    print("\n  All running apps with localizedName:")
    for app in apps where app.activationPolicy == .regular {
        print("    - \"\(app.localizedName ?? "(nil)")\" (bundle: \(app.bundleIdentifier ?? "?"), pid: \(app.processIdentifier))")
    }
} else {
    for app in teamsLike {
        print("  Name: \"\(app.localizedName ?? "(nil)")\"")
        print("  Bundle ID: \(app.bundleIdentifier ?? "(nil)")")
        print("  PID: \(app.processIdentifier)")
        print("  Active: \(app.isActive)")
        print()
    }
}

print("\n=== Power Assertions ===")
var assertionsByPid: Unmanaged<CFDictionary>?
let status = IOPMCopyAssertionsByProcess(&assertionsByPid)
if status != kIOReturnSuccess {
    print("  IOPMCopyAssertionsByProcess failed with status: \(status)")
} else if let dict = assertionsByPid?.takeRetainedValue() as NSDictionary? {
    var foundTeamsAssertion = false
    for app in teamsLike {
        let pid = app.processIdentifier
        let key = NSNumber(value: pid)
        if let assertions = dict[key] as? [[String: Any]] {
            print("  PID \(pid) (\(app.localizedName ?? "?")) assertions:")
            for assertion in assertions {
                let type = assertion["AssertionType"] as? String ?? "?"
                let name = assertion["AssertName"] as? String ?? "?"
                print("    - Type: \(type), Name: \(name)")
                if type == "PreventUserIdleDisplaySleep" {
                    foundTeamsAssertion = true
                }
            }
        } else {
            print("  PID \(pid) (\(app.localizedName ?? "?")): no assertions found")
            // Try string key
            if let assertions = dict["\(pid)"] as? [[String: Any]] {
                print("    (found with string key instead!)")
                for assertion in assertions {
                    print("    - Type: \(assertion["AssertionType"] ?? "?"), Name: \(assertion["AssertName"] ?? "?")")
                }
            }
        }
    }
    if !foundTeamsAssertion {
        print("\n  ⚠️  No PreventUserIdleDisplaySleep assertion found for Teams!")
        print("  All PIDs with assertions:")
        for (key, value) in dict {
            if let assertions = value as? [[String: Any]] {
                for assertion in assertions {
                    let type = assertion["AssertionType"] as? String ?? "?"
                    if type == "PreventUserIdleDisplaySleep" {
                        print("    PID \(key): \(type) — \(assertion["AssertName"] ?? "?")")
                    }
                }
            }
        }
    }
} else {
    print("  Could not parse assertion dictionary")
}

print("\n=== Window Titles ===")
if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
    for window in windowList {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        if owner.lowercased().contains("teams") {
            let title = window[kCGWindowName as String] as? String ?? "(no title)"
            let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
            print("  [\(owner)] PID \(pid): \"\(title)\"")
        }
    }
} else {
    print("  CGWindowListCopyWindowInfo failed (need Screen Recording permission?)")
}

print("\nDone. If Teams is in a meeting and nothing was detected, the issue is in the detection logic above.")
