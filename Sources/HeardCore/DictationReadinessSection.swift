import SwiftUI

/// Readiness line for the dictation engine in Settings > Dictation. Observes `ModelDownloadManager`
/// directly, so it updates without AppModel forwarding nested changes. Hidden when dictation is off.
struct DictationReadinessSection: View {
    @ObservedObject var downloads: ModelDownloadManager

    var body: some View {
        if downloads.dictationReadiness != .notRequired {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Dictation Model")
                SettingsCard {
                    CardRow(isLast: true) {
                        HStack(spacing: 8) {
                            Text("Dictation engine")
                                .font(HeardFont.bodyMedium)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                            Spacer()
                            statusView
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch downloads.dictationReadiness {
        case .notRequired:
            EmptyView()
        case .notDownloaded:
            Text("Not downloaded")
                .font(HeardFont.caption)
                .foregroundStyle(HeardTheme.Terminal.mute)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading")
                    .font(HeardFont.caption)
                    .foregroundStyle(HeardTheme.Terminal.mute)
            }
        case .ready:
            Text("Ready")
                .font(HeardFont.caption)
                .foregroundStyle(HeardTheme.Terminal.ink)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(HeardFont.caption)
                    .foregroundStyle(HeardTheme.Terminal.bad)
                    .lineLimit(2)
                Button("Retry") {
                    Task { try? await downloads.prepareDictationEngine() }
                }
                .buttonStyle(TerminalButtonStyle(.secondary, size: .sm))
            }
        }
    }
}
