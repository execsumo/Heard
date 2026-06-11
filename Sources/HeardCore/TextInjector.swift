import AppKit
import Foundation

/// Injects text into the focused text field of any app using CGEvent unicode insertion.
public enum TextInjector {

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

    /// Inject text into the currently focused app via clipboard paste.
    ///
    /// We previously had a "short text < 50 chars uses CGEvent unicode insertion"
    /// fast path to avoid touching the clipboard, but observed it dropping events
    /// silently for short transcripts in Code/Electron apps even at 1–2 chunks.
    /// CGEvent.postToPid returned success and the events never landed. Clipboard
    /// paste is one Cmd+V regardless of length and works reliably; the original
    /// pasteboard contents are restored after a short delay.
    public static func inject(_ text: String) {
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

        insertViaClipboard(text)
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
