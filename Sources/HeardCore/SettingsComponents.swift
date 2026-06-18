import AVFoundation
import SwiftUI

// MARK: - Model Status Row

// MARK: - Microphone Picker Row
struct MicrophonePickerRow: View {
    let selectedUID: String?
    let onSelect: (String?) -> Void

    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDevice: AudioInputDevice?

    var body: some View {
        HStack {
            Text("Input Device")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HeardTheme.Paper.ink)
            Spacer()
            Picker("", selection: pickerBinding) {
                Text(systemDefaultLabel).tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
                // Keep the stored UID selectable even if the device is currently
                // unplugged, so the user doesn't silently lose their preference.
                if let uid = selectedUID, devices.first(where: { $0.uid == uid }) == nil {
                    Text("Unavailable — last used \(shortUID(uid))")
                        .tag(String?.some(uid))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(width: 220)
        }
        .onAppear { refresh() }
    }

    private var pickerBinding: Binding<String?> {
        Binding(
            get: { selectedUID },
            set: { onSelect($0) }
        )
    }

    private var systemDefaultLabel: String {
        if let name = defaultDevice?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }

    private func refresh() {
        devices = AudioInputDevices.list()
        defaultDevice = AudioInputDevices.defaultInputDevice()
    }

    private func shortUID(_ uid: String) -> String {
        uid.count <= 16 ? uid : String(uid.prefix(13)) + "…"
    }
}
struct ModelStatusRow: View {
    let item: ModelStatusItem
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(statusBg)
                    .frame(width: 28, height: 28)
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.modelKind.displayName(for: downloadManager.transcriptionModel))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HeardTheme.Paper.ink)

                if let progress = downloadManager.downloadProgress[item.modelKind] {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(HeardTheme.Paper.mute)
                        .monospacedDigit()
                } else if let error = downloadManager.errors[item.modelKind] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(HeardTheme.Paper.bad)
                        .lineLimit(1)
                } else {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(item.availability == .ready ? HeardTheme.Paper.good : HeardTheme.Paper.mute)
                }
            }

            Spacer()

            if item.availability == .notDownloaded && downloadManager.downloadProgress[item.modelKind] == nil {
                Button("Download") { downloadManager.download(item.modelKind) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        if downloadManager.downloadProgress[item.modelKind] != nil { return "arrow.down.circle" }
        if downloadManager.errors[item.modelKind] != nil { return "exclamationmark.triangle" }
        switch item.availability {
        case .ready:         return "checkmark.circle.fill"
        case .downloading:   return "arrow.down.circle"
        case .notDownloaded: return "arrow.down.to.line"
        }
    }

    private var statusColor: Color {
        if downloadManager.downloadProgress[item.modelKind] != nil { return HeardTheme.Paper.accent }
        if downloadManager.errors[item.modelKind] != nil { return HeardTheme.Paper.bad }
        switch item.availability {
        case .ready:         return HeardTheme.Paper.good
        case .downloading:   return HeardTheme.Paper.accent
        case .notDownloaded: return HeardTheme.Paper.mute
        }
    }

    private var statusBg: Color {
        if downloadManager.errors[item.modelKind] != nil { return HeardTheme.Paper.badSoft }
        switch item.availability {
        case .ready:         return HeardTheme.Paper.goodSoft
        case .downloading:   return HeardTheme.Paper.accentSoft
        case .notDownloaded: return HeardTheme.Paper.surfaceAlt
        }
    }
}

// MARK: - Permission Row
struct PermissionRow: View {
    let permission: PermissionStatus
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: HeardTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconBg)
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HeardTheme.Paper.ink)
                    if permission.id == "microphone" || permission.id == "screenCapture" {
                        StatusPill(text: "Required",
                                   fg: HeardTheme.Paper.bad,
                                   bg: HeardTheme.Paper.badSoft)
                    }
                }
                Text(permission.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(HeardTheme.Paper.mute)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(text: permission.state.badge, fg: pillFg, bg: pillBg)
                if permission.state != .granted {
                    Button("Grant…") {
                        switch permission.id {
                        case "microphone":    model.permissionCenter.requestMicrophone()
                        case "audioCapture":  model.permissionCenter.requestAudioCapture()
                        case "screenCapture": model.permissionCenter.openScreenCaptureSettings()
                        case "accessibility": model.permissionCenter.openAccessibilitySettings()
                        default: break
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch permission.id {
        case "microphone":    return "mic.fill"
        case "audioCapture":  return "speaker.wave.2.fill"
        case "screenCapture": return "rectangle.dashed.badge.record"
        case "accessibility": return "figure.stand"
        default:              return "lock.fill"
        }
    }

    private var iconTint: Color {
        permission.state == .granted ? HeardTheme.Paper.good : HeardTheme.Paper.accent
    }

    private var iconBg: Color {
        permission.state == .granted ? HeardTheme.Paper.goodSoft : HeardTheme.Paper.accentSoft
    }

    private var pillFg: Color {
        switch permission.state {
        case .granted:     return HeardTheme.Paper.good
        case .recommended: return HeardTheme.Paper.warn
        case .unknown:     return HeardTheme.Paper.bad
        }
    }

    private var pillBg: Color {
        switch permission.state {
        case .granted:     return HeardTheme.Paper.goodSoft
        case .recommended: return HeardTheme.Paper.warnSoft
        case .unknown:     return HeardTheme.Paper.badSoft
        }
    }
}

// MARK: - About Badge
struct AboutBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(HeardTheme.Paper.mute)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(HeardTheme.Paper.surfaceAlt, in: Capsule())
    }
}

// MARK: - Hotkey Recorder
struct HotkeyRecorderView: View {
    let onCommit: (HotkeyCombo) -> Void
    let onCancel: () -> Void
    var conflictingHotkey: HotkeyCombo? = nil

    @State private var captured: HotkeyCombo? = nil
    @State private var monitorToken: Any? = nil
enum ValidationKind { case noModifier, forbidden, singleModifier, heardConflict }

    var body: some View {
        VStack(spacing: HeardTheme.Spacing.lg) {
            Image(systemName: "keyboard")
                .font(.system(size: 36))
                .foregroundStyle(HeardTheme.Paper.accent)

            Text("Record Shortcut")
                .font(.title2.weight(.semibold))
                .foregroundStyle(HeardTheme.Paper.ink)

            Text("Press the key combination you want to use for dictation.")
                .font(.callout)
                .foregroundStyle(HeardTheme.Paper.mute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Group {
                if let combo = captured {
                    Text(combo.displayString)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(HeardTheme.Paper.accentSoft,
                                    in: RoundedRectangle(cornerRadius: HeardTheme.Radius.inline))
                        .foregroundStyle(HeardTheme.Paper.accent)
                } else {
                    Text("Waiting for input…")
                        .font(.callout)
                        .foregroundStyle(HeardTheme.Paper.mute)
                        .padding(.vertical, 8)
                }
            }
            .frame(height: 44)

            if let validation = captured.flatMap({ validate($0) }) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: validation == .singleModifier
                          ? "exclamationmark.triangle.fill"
                          : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(validation == .singleModifier ? HeardTheme.Paper.warn : HeardTheme.Paper.bad)
                    Text(validationMessage(validation))
                        .font(.caption)
                        .foregroundStyle(validation == .singleModifier ? HeardTheme.Paper.warn : HeardTheme.Paper.bad)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: 280, alignment: .leading)
            }

            HStack(spacing: HeardTheme.Spacing.md) {
                Button("Cancel") {
                    stopMonitoring()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    stopMonitoring()
                    if let combo = captured { onCommit(combo) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil || isBlocked(captured))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(HeardTheme.Spacing.xl)
        .frame(width: 360)
        .background(HeardTheme.Paper.bg)
        .onAppear { startMonitoring() }
        .onDisappear { stopMonitoring() }
    }

    private func isBlocked(_ combo: HotkeyCombo?) -> Bool {
        guard let combo else { return false }
        let v = validate(combo)
        return v == .noModifier || v == .forbidden || v == .heardConflict
    }

    private func isFunctionKeyCode(_ code: UInt16) -> Bool {
        let functionKeyCodes: Set<UInt16> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
            105, 107, 113, 106, 64, 79, 80, 90,
        ]
        return functionKeyCodes.contains(code)
    }

    private func validate(_ combo: HotkeyCombo) -> ValidationKind? {
        let flags = combo.modifierFlags
        let modifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
        let modCount = modifiers.filter { flags.contains($0) }.count
        if modCount == 0 && !isFunctionKeyCode(combo.keyCode) { return .noModifier }
        if isForbiddenCombo(combo) { return .forbidden }
        if let other = conflictingHotkey, combo == other { return .heardConflict }
        if modCount == 1 && !isFunctionKeyCode(combo.keyCode) { return .singleModifier }
        return nil
    }

    private func validationMessage(_ kind: ValidationKind) -> String {
        switch kind {
        case .noModifier:     return "A modifier key (⌘, ⌃, ⌥, or ⇧) is required."
        case .forbidden:      return "This shortcut is reserved by macOS. Please choose another."
        case .heardConflict:  return "This shortcut is already used by another Heard hotkey. Please choose another."
        case .singleModifier: return "Single-modifier shortcuts may conflict with app shortcuts."
        }
    }

    private func isForbiddenCombo(_ combo: HotkeyCombo) -> Bool {
        let blocked: [(UInt16, NSEvent.ModifierFlags)] = [
            (48, .command), (49, .command), (49, [.command, .option]),
            (49, .control), (12, .command), (4, .command), (46, .command),
            (13, .command), (43, .command), (50, .command),
            (20, [.command, .shift]), (21, [.command, .shift]), (22, [.command, .shift]),
        ]
        return blocked.contains { keyCode, mods in
            combo.keyCode == keyCode && combo.modifierFlags == mods
        }
    }

    private func startMonitoring() {
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isModifierOnlyKeyCode(event.keyCode) else { return event }
            let combo = HotkeyCombo(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .option, .control, .shift])
            )
            captured = combo
            return nil
        }
    }

    private func stopMonitoring() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }

    private func isModifierOnlyKeyCode(_ code: UInt16) -> Bool {
        Set<UInt16>([54, 55, 56, 57, 58, 59, 60, 61, 62, 63]).contains(code)
    }
}

// MARK: - Reusable Components

