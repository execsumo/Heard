import AppKit
import Carbon
import Foundation

/// A configurable keyboard shortcut for dictation toggle.
public struct HotkeyCombo: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt  // NSEvent.ModifierFlags.rawValue

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Default: Ctrl+Shift+D
    public static let `default` = HotkeyCombo(
        keyCode: 2, // 'D' key
        modifiers: [.control, .shift]
    )

    /// Convert NSEvent modifier flags to Carbon modifier flags.
    var carbonModifiers: UInt32 {
        var carbonFlags: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        return carbonFlags
    }

    public var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        let keyName = Self.keyCodeName(keyCode)
        parts.append(keyName)
        return parts.joined()
    }

    static func keyCodeName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            // Letters
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            // Numbers
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9", 29: "0",
            // Special
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20",
        ]
        return names[code] ?? "Key\(code)"
    }
}

// MARK: - Carbon Hot Key Manager

/// Singleton storage for the Carbon event handler callback.
/// Carbon uses a C function pointer callback, so we need a global to bridge back to Swift.
private var hotkeyManagerInstance: HotkeyManager?

/// Carbon event handler callback — dispatches to the HotkeyManager singleton.
private func carbonHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    let eventKind = Int(GetEventKind(event))
    DispatchQueue.main.async {
        if eventKind == kEventHotKeyPressed {
            hotkeyManagerInstance?.handleHotkeyPressed()
        } else if eventKind == kEventHotKeyReleased {
            hotkeyManagerInstance?.handleHotkeyReleased()
        }
    }
    return noErr
}

/// Registers a global keyboard shortcut using Carbon's RegisterEventHotKey.
/// This is the most reliable global hotkey API on macOS — does not require
/// Accessibility permission and works with ad-hoc signed apps.
@MainActor
public final class HotkeyManager {

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkey: HotkeyCombo
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?

    private static let hotkeyID = EventHotKeyID(
        signature: OSType(0x48524430),  // "HRD0"
        id: 1
    )

    public init(hotkey: HotkeyCombo = .default, onPressed: (() -> Void)? = nil, onReleased: (() -> Void)? = nil) {
        self.hotkey = hotkey
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    public func setCallbacks(onPressed: @escaping () -> Void, onReleased: (() -> Void)? = nil) {
        self.onPressed = onPressed
        self.onReleased = onReleased
    }

    public func updateHotkey(_ newHotkey: HotkeyCombo) {
        let wasActive = hotkeyRef != nil
        if wasActive { deactivate() }
        hotkey = newHotkey
        if wasActive { activate() }
    }

    public func activate() {
        guard hotkeyRef == nil else { return }

        // Store singleton reference for C callback
        hotkeyManagerInstance = self

        // Install Carbon event handler for both pressed and released events
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,
            2,
            &eventTypes,
            nil,
            &eventHandlerRef
        )

        guard status == noErr else {
            NSLog("Heard: Failed to install Carbon event handler: \(status)")
            return
        }

        // Register the hotkey
        var hotkeyID = Self.hotkeyID
        let regStatus = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if regStatus != noErr {
            NSLog("Heard: Failed to register hotkey: \(regStatus)")
            deactivate()
        }
    }

    public func deactivate() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        if hotkeyManagerInstance === self {
            hotkeyManagerInstance = nil
        }
    }

    func handleHotkeyPressed() {
        onPressed?()
    }

    func handleHotkeyReleased() {
        onReleased?()
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
        if hotkeyManagerInstance === self { hotkeyManagerInstance = nil }
    }
}
