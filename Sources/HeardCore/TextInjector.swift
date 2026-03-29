import AppKit
import Foundation

/// Injects text into the focused text field of any app using CGEvent unicode insertion.
public enum TextInjector {

    /// Maximum UTF-16 units per CGEvent (macOS limit).
    private static let cgEventUnicodeLimit = 20

    /// Check and prompt for Accessibility permission (needed for text injection).
    /// Call this when enabling dictation so the user gets the prompt early.
    @discardableResult
    public static func ensureAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            // Prompt the user with the system dialog
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return true
    }

    /// Inject text into the currently focused app.
    public static func inject(_ text: String) {
        guard AXIsProcessTrusted() else {
            NSLog("Heard: TextInjector cannot inject text — Accessibility not granted")
            return
        }

        // Get the frontmost app's PID
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        // Try CGEvent unicode insertion to specific PID first
        if insertTextBulk(text, targetPID: pid) {
            return
        }

        // Fallback: try HID tap (no PID targeting)
        if insertTextBulkHID(text) {
            return
        }

        // Last resort: clipboard paste
        insertViaClipboard(text)
    }

    // MARK: - CGEvent Unicode Insertion

    /// Send text as unicode keyboard events to a specific PID.
    private static func insertTextBulk(_ text: String, targetPID: pid_t) -> Bool {
        let utf16Array = Array(text.utf16)

        // Split into chunks if needed
        var offset = 0
        while offset < utf16Array.count {
            let end = min(offset + cgEventUnicodeLimit, utf16Array.count)
            let chunk = Array(utf16Array[offset..<end])

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)

            keyDown.postToPid(targetPID)
            usleep(2000)
            keyUp.postToPid(targetPID)
            usleep(2000)

            offset = end
        }

        return true
    }

    /// Send text as unicode keyboard events via HID (no PID targeting).
    private static func insertTextBulkHID(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)

        var offset = 0
        while offset < utf16Array.count {
            let end = min(offset + cgEventUnicodeLimit, utf16Array.count)
            let chunk = Array(utf16Array[offset..<end])

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)

            keyDown.post(tap: .cghidEventTap)
            usleep(2000)
            keyUp.post(tap: .cghidEventTap)
            usleep(2000)

            offset = end
        }

        return true
    }

    // MARK: - Clipboard Fallback

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
