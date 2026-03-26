import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @StateObject private var appModel = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra("Meeting Transcriber", systemImage: appModel.menuBarIconName) {
            MenuBarView(model: appModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appModel)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
