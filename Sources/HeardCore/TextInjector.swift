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

    /// Check and prompt for Accessibility permission (needed for text injection).
    /// Call this when enabling dictation so the user gets the prompt early.
    @discardableResult
    public static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Live fallback: AXIsProcessTrusted() can return a stale false on macOS 15+.
        // Confirm with a real AX API call before showing the permission prompt.
        let sysWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(sysWide, kAXFocusedApplicationAttribute as CFString, &value)
        if err != .apiDisabled { return true }
        // Genuinely not granted — show the system prompt.
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
    public static func inject(_ text: String, restoringFocusTo target: FocusTarget? = nil) {
        var trusted = AXIsProcessTrusted()
        if !trusted {
            // Live fallback: AXIsProcessTrusted() returns a stale cached false on macOS 15+
            // even when Accessibility IS granted. A real AX API call returns .apiDisabled only
            // when genuinely denied — if it returns any other error (or success), access is live.
            let sysWide = AXUIElementCreateSystemWide()
            var value: AnyObject?
            trusted = AXUIElementCopyAttributeValue(sysWide, kAXFocusedApplicationAttribute as CFString, &value) != .apiDisabled
        }
        DebugFileLog.log("TextInjector.inject len=\(text.count) axTrusted=\(trusted)")
        guard trusted else {
            NSLog("Heard: TextInjector cannot inject text — Accessibility not granted")
            return
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

    private static func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Cmd+V via CGEvent
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(10000)
        keyUp.post(tap: .cghidEventTap)

        // Restore clipboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let previous = previousContents, !previous.isEmpty {
                pasteboard.clearContents()
                for (typeRaw, data) in previous {
                    pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawValue: typeRaw))
                }
            }
        }
    }
}
