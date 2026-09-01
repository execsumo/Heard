import AVFoundation
import SwiftUI

// MARK: - Settings Window

public struct SettingsView: View {
    @ObservedObject public var model: AppModel
    @ObservedObject var permissionCenter: PermissionCenter
enum HotkeyTarget: Identifiable {
        case dictation, meetingNote
        var id: Self { self }
    }
    @State var hotkeyTarget: HotkeyTarget? = nil
    @State var commandSpokenDraft = ""
    @State var commandWrittenDraft = ""
    @StateObject var clipPlayer = SpeakerClipController()
    @State var tableSortOrder: [KeyPathComparator<SpeakerProfile>] = [
        KeyPathComparator(\.lastSeen, order: .reverse)
    ]
    @Environment(\.openWindow) var openWindow

    public init(model: AppModel) {
        self.model = model
        self.permissionCenter = model.permissionCenter
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailPane
        }
        .frame(minWidth: 580, minHeight: 440)
        .sheet(item: $hotkeyTarget) { target in
            switch target {
            case .dictation:
                HotkeyRecorderView(
                    onCommit: { combo in
                        model.updateDictationHotkey(combo)
                        hotkeyTarget = nil
                    },
                    onCancel: { hotkeyTarget = nil },
                    conflictingHotkey: model.settingsStore.settings.meetingNoteHotkey
                )
            case .meetingNote:
                HotkeyRecorderView(
                    onCommit: { combo in
                        model.updateMeetingNoteHotkey(combo)
                        hotkeyTarget = nil
                    },
                    onCancel: { hotkeyTarget = nil },
                    conflictingHotkey: model.settingsStore.settings.dictationHotkey
                )
            }
        }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HeardMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Heard")
                        .font(HeardFont.title)
                        .foregroundStyle(HeardTheme.Terminal.ink)
                    Text(model.updateChecker.currentVersion)
                        .font(HeardFont.value)
                        .foregroundStyle(HeardTheme.Terminal.mute)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HeardTheme.Terminal.border.frame(height: HeardTheme.Stroke.hairline)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    if tab != .advanced || model.settingsStore.settings.showAdvancedSettings {
                        sidebarItem(tab)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)

            Spacer()
        }
        .frame(width: 188)
        .background(HeardTheme.Terminal.sidebar)
        .overlay(alignment: .trailing) {
            HeardTheme.Terminal.border.frame(width: HeardTheme.Stroke.hairline)
        }
    }

    func sidebarItem(_ tab: SettingsTab) -> some View {
        let isSelected = model.selectedSettingsTab == tab
        return Button {
            model.selectedSettingsTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? HeardTheme.Terminal.accent : HeardTheme.Terminal.ink2)
                    .frame(width: 18, alignment: .center)
                Text(tab.label)
                    .font(isSelected ? HeardFont.bodyMedium : HeardFont.body)
                    .foregroundStyle(isSelected ? HeardTheme.Terminal.ink : HeardTheme.Terminal.ink2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    // Selected nav item: square surface fill + 1px accent border, no shadow.
                    Rectangle()
                        .fill(HeardTheme.Terminal.surface)
                        .overlay(
                            Rectangle()
                                .stroke(HeardTheme.Terminal.accent, lineWidth: HeardTheme.Stroke.hairline)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: Detail pane

    var detailPane: some View {
        Group {
            switch model.selectedSettingsTab {
            case .general:       generalSection
            case .recording:     recordingSection
            case .dictation:     dictationSection
            case .speakers:      speakersSection
            case .meetings:      meetingsSection
            case .advanced:      advancedSection
            case .about:         aboutSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

extension SettingsView {
    // MARK: Pane helpers

    func paneScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(HeardTheme.Terminal.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func sectionGroup<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: label)
            content()
        }
    }

    func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settingsStore.settings[keyPath: keyPath] },
            set: { model.settingsStore.settings[keyPath: keyPath] = $0 }
        )
    }

    /// Explains the memory mode picker: what it does, the detected RAM, and (for
    /// Automatic) which mode the RAM check resolved to.
    var memoryModeSubtitle: String {
        let gb = Double(SystemMemory.physicalMemoryBytes) / (1024 * 1024 * 1024)
        let detected = "Detected \(Int(gb.rounded())) GB"
        let base = "Preprocesses audio tracks one at a time instead of simultaneously, halving peak RAM during transcription (~400 MB instead of ~800 MB) at a small speed cost."
        switch model.settingsStore.settings.memoryMode {
        case .auto:
            let resolved = SystemMemory.isLowMemoryMachine ? "low-memory mode" : "normal mode"
            return "\(base) \(detected) — Automatic runs in \(resolved)."
        case .low:
            return "\(base) \(detected). Forced on."
        case .normal:
            return "\(base) \(detected). Forced off."
        }
    }
}


