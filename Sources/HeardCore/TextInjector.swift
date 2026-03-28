import AppKit
import Foundation

/// Injects text into the focused text field of any app using CGEvent unicode insertion.
/// This sends text directly as keyboard events — no clipboard, no Accessibility needed.
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
            let result = AXIsProcessTrustedWithOptions(options)
            dictLog("TextInjector: AXIsProcessTrusted=\(result) (prompted)")
            return result
        }
        return true
    }

    /// Inject text into the currently focused app.
    public static func inject(_ text: String) {
        dictLog("TextInjector.inject called with: '\(text)'")

        let axTrusted = AXIsProcessTrusted()
        dictLog("TextInjector: AXIsProcessTrusted=\(axTrusted)")

        if !axTrusted {
            dictLog("TextInjector: WARNING - Accessibility not granted, text injection will fail")
        }

        // Get the frontmost app's PID
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            dictLog("TextInjector: No frontmost app")
            return
        }
        let pid = frontApp.processIdentifier
        dictLog("TextInjector: targeting PID \(pid) (\(frontApp.localizedName ?? "unknown"))")

        // Try CGEvent unicode insertion to specific PID first
        if insertTextBulk(text, targetPID: pid) {
            return
        }

        // Fallback: try HID tap (no PID targeting)
        if insertTextBulkHID(text) {
            return
        }

        // Last resort: clipboard paste
        dictLog("TextInjector: CGEvent methods failed, trying clipboard paste")
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
                dictLog("TextInjector: Failed to create CGEvents")
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

        dictLog("TextInjector: Posted CGEvents to PID \(targetPID)")
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

        dictLog("TextInjector: Posted CGEvents via HID tap")
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
