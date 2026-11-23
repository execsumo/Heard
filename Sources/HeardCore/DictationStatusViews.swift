import SwiftUI

/// Dictation failure banner in the menu bar. It is instantiated whenever dictation is enabled and observes
/// the download manager directly, so a failed engine stays visible even when no error string is set.
struct DictationStatusBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var downloads: ModelDownloadManager

    /// Engine readiness failure. Persists until Retry succeeds or dictation is turned off, so it has no Dismiss.
    private var failureMessage: String? {
        if case .failed(let message) = downloads.dictationReadiness { return message }
        return nil
    }

    /// Explicit error from a start, transcription, or paste. Skipped when it repeats the readiness message.
    private var errorText: String? {
        guard let error = model.dictationError, error != failureMessage else { return nil }
        return error
    }

    var body: some View {
        if failureMessage != nil || errorText != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let failureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        warningIcon
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dictation model unavailable: \(failureMessage)")
                                .font(HeardFont.caption)
                                .foregroundStyle(HeardTheme.Terminal.ink)
                                .lineLimit(3)
                            Button("Retry") { model.retryDictationSetup() }
                                .buttonStyle(.plain)
                                .font(HeardFont.mono(11, .medium))
                                .foregroundStyle(HeardTheme.Terminal.accent)
                        }
                        Spacer(minLength: 4)
                    }
                }
                if let errorText {
                    HStack(alignment: .top, spacing: 8) {
                        warningIcon
                        Text(errorText)
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.ink)
                            .lineLimit(3)
                        Spacer(minLength: 4)
                        Button("Dismiss") { model.dictationError = nil }
                            .buttonStyle(.plain)
                            .font(HeardFont.mono(11, .medium))
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                }
            }
            .padding(10)
            .background(Rectangle().fill(HeardTheme.Terminal.badSoft))
            .overlay(Rectangle().stroke(HeardTheme.Terminal.bad.opacity(0.35), lineWidth: HeardTheme.Stroke.hairline))
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(HeardTheme.Terminal.bad)
            .font(HeardFont.caption)
    }
}

/// Shown while the dictation hotkey is not registered. The enabled setting alone does not mean the shortcut works.
struct DictationHotkeyWarning: View {
    let hotkey: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HeardTheme.Terminal.warn)
                .font(HeardFont.caption)
            Text("Dictation hotkey \(hotkey) is not registered. Another app may use it. Choose another in Settings.")
                .font(HeardFont.caption)
                .foregroundStyle(HeardTheme.Terminal.ink)
                .lineLimit(3)
        }
        .padding(10)
        .background(Rectangle().fill(HeardTheme.Terminal.warnSoft))
        .overlay(Rectangle().stroke(HeardTheme.Terminal.warn.opacity(0.35), lineWidth: HeardTheme.Stroke.hairline))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// Menu bar icon dot for dictation states. Colors come from the design tokens; HeardTheme is module-internal,
/// so the Heard app target uses this view rather than the tokens directly.
public struct DictationIconBadge: View {
    public enum Kind {
        case preparing
        case error
    }

    let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var body: some View {
        Circle()
            .fill(kind == .error ? HeardTheme.Terminal.bad : HeardTheme.Terminal.mute)
            .frame(width: 5, height: 5)
            .offset(x: 1, y: -1)
    }
}
