import AppKit
import LurkCore
import SwiftUI

@main
struct LurkApp: App {
    @StateObject private var appModel = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra("Lurk", systemImage: appModel.menuBarIconName) {
            MenuBarView(model: appModel)
        }
        .menuBarExtraStyle(.window)

        Window("Lurk Settings", id: "settings") {
            SettingsView(model: appModel)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    // Menu bar apps use .accessory policy which prevents keyboard focus.
                    // Switch to .regular so the settings window can receive keystrokes.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    // Revert to accessory (no dock icon) when settings closes.
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentSize)
    }
}
