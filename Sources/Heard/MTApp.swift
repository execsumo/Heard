import AppKit
import HeardCore
import SwiftUI

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isDictating {
                Image(systemName: "record")
                    .symbolVariant(.circle)
                    .symbolEffect(.breathe, isActive: true)
            } else {
                switch model.phase {
                case .dormant:
                    Image(systemName: "recordingtape")
                case .recording:
                    Image(systemName: "record")
                        .symbolVariant(.circle)
                        .symbolEffect(.breathe, isActive: true)
                case .processing:
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative.reversing)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                case .userAction:
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                }
            }
        }
    }
}

@main
struct HeardApp: App {
    @StateObject private var appModel = AppModel.bootstrap()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appModel)
        } label: {
            MenuBarIcon(model: appModel)
        }
        .menuBarExtraStyle(.window)

        Window("Heard Settings", id: "settings") {
            SettingsView(model: appModel)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { WindowActivationCoordinator.begin("settings") }
                .onDisappear { WindowActivationCoordinator.end("settings") }
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentSize)

        Window("Name Speakers", id: "speaker-naming") {
            SpeakerNamingView(model: appModel)
                .onAppear { WindowActivationCoordinator.begin("speaker-naming") }
                .onDisappear {
                    WindowActivationCoordinator.end("speaker-naming")
                    // If user closes window without naming, skip naming
                    if !appModel.namingCandidates.isEmpty {
                        appModel.skipNaming()
                    }
                }
        }
        .defaultSize(width: 520, height: 420)
        .windowResizability(.contentSize)
    }
}
