import AppKit
import Foundation

/// Injects text into the focused text field of any app using CGEvent unicode insertion.
public enum TextInjector {

    /// Snapshot of where keyboard focus was when dictation started: the owning
    /// app's pid plus the focused AX element (when readable). Captured on start
    /// and used at paste time so the transcript lands in the field the user was
    /// dictating into, even if they switched apps or fields while speaking.
    public struct FocusTarget {
        let pid: pid_t
        let element: AXUIElement?
    }

    /// Capture the currently focused UI element and its owning app. Returns nil
    /// when focus belongs to Heard itself (e.g. dictation toggled from the menu
    /// bar panel) or nothing useful can be read — injection then falls back to
    /// pasting at whatever is focused at paste time, matching old behavior.
    public static func captureFocusTarget() -> FocusTarget? {
        var element: AXUIElement?
        let sysWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            element = (focused as! AXUIElement)
        }

        // Prefer the pid of the focused element itself; fall back to the
        // frontmost app when the element (or its pid) is unreadable.
        var pid: pid_t = 0
        if let element, AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            // pid resolved from the focused element
        } else if let front = NSWorkspace.shared.frontmostApplication {
            pid = front.processIdentifier
        } else {
            DebugFileLog.log("TextInjector.captureFocusTarget failed — no focused element and no frontmost app")
            return nil
        }

        guard pid != ProcessInfo.processInfo.processIdentifier else {
            DebugFileLog.log("TextInjector.captureFocusTarget skipped — focus is on Heard itself")
            return nil
        }
        DebugFileLog.log("TextInjector.captureFocusTarget pid=\(pid) element=\(element != nil)")
        return FocusTarget(pid: pid, element: element)
    }

    /// A successful cross-app AX read can confirm access when the trust bit is
    /// stale. A system-wide read alone cannot prove access to another app.
    public static func canAttemptInjection(isTrusted: Bool, targetReadSucceeded: Bool) -> Bool {
        isTrusted || targetReadSucceeded
    }

    private static func canReadTargetApp(_ pid: pid_t?) -> Bool {
        guard let pid, pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], let window = windows.first else { return false }
        AXUIElementSetMessagingTimeout(window, 0.5)
        var role: AnyObject?
        return AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success && role != nil
    }

    /// Verify access without prompting. Check an actual target app if the
    /// process trust bit is stale rather than relying on system-wide AX calls.
    public static func accessibilityAccessVerified(restoringFocusTo target: FocusTarget? = nil) -> Bool {
        let trusted = AXIsProcessTrusted()
        let targetPID = target?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return canAttemptInjection(isTrusted: trusted, targetReadSucceeded: !trusted && canReadTargetApp(targetPID))
    }

    /// Check and prompt for Accessibility permission (needed for text injection).
    /// Call this when enabling dictation so the user gets the prompt early.
    @discardableResult
    public static func ensureAccessibility() -> Bool {
        if accessibilityAccessVerified() { return true }
        // A failed or inconclusive read is not a grant. Prompt only in this
        // explicit setup path, not from a background injection attempt.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Inject text via clipboard paste, first restoring focus to `target` (the
    /// field the user was in when dictation started) when one was captured.
    ///
    /// We previously had a "short text < 50 chars uses CGEvent unicode insertion"
    /// fast path to avoid touching the clipboard, but observed it dropping events
    /// silently for short transcripts in Code/Electron apps even at 1–2 chunks.
    /// CGEvent.postToPid returned success and the events never landed. Clipboard
    /// paste is one Cmd+V regardless of length and works reliably; the original
    /// pasteboard contents are restored after a short delay.
    /// Returns false when Accessibility access could not be verified. A true
    /// result means injection was attempted, not that the target app accepted it.
    @discardableResult
    public static func inject(_ text: String, restoringFocusTo target: FocusTarget? = nil) -> Bool {
        let allowed = accessibilityAccessVerified(restoringFocusTo: target)
        DebugFileLog.log("TextInjector.inject len=\(text.count) accessVerified=\(allowed)")
        guard allowed else {
            NSLog("Heard: TextInjector cannot inject text — Accessibility access is unverified")
            return false
        }

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            DebugFileLog.log("TextInjector injecting into frontApp=\(frontApp.localizedName ?? "?") pid=\(frontApp.processIdentifier)")
        }

        if let target, restoreFocus(to: target) {
            // App activation and AX focus changes take a beat to land; pasting
            // immediately would send Cmd+V to the previously focused app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                insertViaClipboard(text)
            }
        } else {
            insertViaClipboard(text)
        }
        return true
    }

    // MARK: - Focus restoration

    /// Bring the captured app/field back into keyboard focus. Returns true if
    /// any focus change was issued (the caller should wait before pasting),
    /// false if nothing needed to change or the target is gone.
    private static func restoreFocus(to target: FocusTarget) -> Bool {
        var changed = false

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
                DebugFileLog.log("TextInjector focus target pid=\(target.pid) no longer running — pasting at current focus")
                return false
            }
            DebugFileLog.log("TextInjector re-activating focus target app=\(app.localizedName ?? "?") pid=\(target.pid)")
            app.activate()
            changed = true
        }

        if let element = target.element {
            // Raise the element's window first — activating the app alone brings
            // forward whatever window was last key, which may not be the one the
            // user was dictating into.
            var windowRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
               let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
                AXUIElementPerformAction((windowRef as! AXUIElement), kAXRaiseAction as CFString)
            }
            let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            DebugFileLog.log("TextInjector restore AX focus err=\(err.rawValue)")
            if err == .success { changed = true }
        }

        return changed
    }

    // MARK: - Clipboard Paste

    /// Owns the general pasteboard while a transcript paste is pending. See `PasteboardLeaseController`.
    private static let pasteboardLease = PasteboardLeaseController(
        backend: SystemPasteboard(NSPasteboard.general),
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    )

    private static func insertViaClipboard(_ text: String) {
        let lease = pasteboardLease.place(text)

        // Cmd+V via CGEvent. The restore is scheduled even if the events cannot be created,
        // so the transcript never stays on the clipboard.
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            usleep(10000)
            keyUp.post(tap: .cghidEventTap)
        } else {
            DebugFileLog.log("TextInjector could not create Cmd+V events")
        }

        pasteboardLease.scheduleRestore(lease, after: 0.5)
    }
}

/// `PasteboardBackend` over a real NSPasteboard. Reads every item and every readable type, and
/// writes items back as separate NSPasteboardItems so item boundaries survive a restore.
public final class SystemPasteboard: PasteboardBackend {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func readItems() -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).compactMap { item -> PasteboardItemSnapshot? in
            let representations = item.types.compactMap { type -> PasteboardItemSnapshot.Representation? in
                guard let data = item.data(forType: type) else { return nil }
                return PasteboardItemSnapshot.Representation(type: type.rawValue, data: data)
            }
            return representations.isEmpty ? nil : PasteboardItemSnapshot(representations: representations)
        }
    }

    @discardableResult
    public func writeItems(_ items: [PasteboardItemSnapshot]) -> Int {
        pasteboard.clearContents()
        let objects = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in snapshot.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !objects.isEmpty {
            _ = pasteboard.writeObjects(objects)
        }
        return pasteboard.changeCount
    }
}
