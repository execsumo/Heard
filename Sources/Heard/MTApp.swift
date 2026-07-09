import AppKit
import HeardCore
import SwiftUI

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    // MenuBarExtra(.window) doesn't reliably forward child-store
    // objectWillChange events to the label, so observe MeetingDetector
    // directly. Without this, toggling watching off doesn't dim the icon.
    @ObservedObject private var meetingDetector: MeetingDetector
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        self.meetingDetector = model.meetingDetector
    }

    private static let templateImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else {
            return NSImage()
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .foregroundStyle(iconTint)
            .opacity(iconOpacity)
            .overlay(alignment: .topTrailing) {
                badge
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    /// Accent when actively capturing audio; primary otherwise.
    private var iconTint: AnyShapeStyle {
        (model.isDictating || model.phase == .recording)
            ? AnyShapeStyle(.tint)
            : AnyShapeStyle(.primary)
    }

    /// Dimmed when the app is idle and watching is off (paused); full otherwise.
    private var iconOpacity: Double {
        let paused = model.phase == .dormant
            && !model.isDictating
            && !meetingDetector.isWatching
        return paused ? 0.5 : 1.0
    }

    @ViewBuilder
    private var badge: some View {
        if model.phase == .error {
            Circle().fill(.red).frame(width: 5, height: 5)
                .offset(x: 1, y: -1)
        } else if model.phase == .userAction {
            Circle().fill(.orange).frame(width: 5, height: 5)
                .offset(x: 1, y: -1)
        } else if model.phase == .processing {
            Circle().fill(.yellow).frame(width: 5, height: 5)
                .offset(x: 1, y: -1)
        } else if model.isDictating {
            Circle().fill(.red).frame(width: 5, height: 5)
                .offset(x: 1, y: -1)
        } else {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
        return true
    }
}

@main
struct HeardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appModel)
                .heardAppearance(appModel.settingsStore.settings.appearance)
        } label: {
            MenuBarIcon(model: appModel)
        }
        .menuBarExtraStyle(.window)

        Window("Heard Settings", id: "settings") {
            SettingsView(model: appModel)
                .heardAppearance(appModel.settingsStore.settings.appearance)
                .onAppear { WindowActivationCoordinator.begin("settings") }
                .onDisappear { WindowActivationCoordinator.end("settings") }
        }
        .defaultSize(width: 680, height: 500)
        .windowResizability(.contentSize)

        Window("Name Speakers", id: "speaker-naming") {
            SpeakerNamingView(model: appModel)
                .heardAppearance(appModel.settingsStore.settings.appearance)
                .onAppear { WindowActivationCoordinator.begin("speaker-naming") }
                // Closing the window means "later", not "skip" — candidates stay
                // pending and the window can be reopened from the menu bar. Skipping
                // is only ever the explicit "Skip All" button.
                .onDisappear { WindowActivationCoordinator.end("speaker-naming") }
        }
        .defaultSize(width: 560, height: 520)
        .windowResizability(.contentSize)
    }
}
