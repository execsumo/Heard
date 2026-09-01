import AppKit
import SwiftUI

/// Floating composer for in-meeting notes. Hotkey opens the panel; the panel
/// becomes key immediately so the first keystroke goes into the field. Esc
/// cancels, Return submits, Cmd+Return inserts a newline.
@MainActor
public final class MeetingNoteComposer {
    public static let shared = MeetingNoteComposer()

    private var panel: KeyablePanel?
    /// Captured at the instant the panel is shown so a slow typer's note still
    /// anchors to when they reacted to what was being said, not when they hit
    /// Return.
    private var openedAt: Date?
    private var onSubmit: ((Date, String) -> Void)?
    private var onCancel: (() -> Void)?

    /// - Parameter recordingStart: Pass the recording start time during a meeting to show an
    ///   elapsed-time offset in the composer. Pass `nil` for standalone (out-of-meeting) notes.
    public func present(
        meetingTitle: String,
        recordingStart: Date?,
        onSubmit: @escaping (Date, String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        // If already showing, bring it forward rather than stacking.
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let now = Date()
        self.openedAt = now
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        let offsetSeconds: TimeInterval = recordingStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let view = MeetingNoteComposerView(
            meetingTitle: meetingTitle,
            offsetSecondsAtOpen: offsetSeconds,
            showOffset: recordingStart != nil,
            onSubmit: { [weak self] text in self?.submit(text: text) },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 420, height: 200)
        host.frame = NSRect(origin: .zero, size: size)

        let p = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Note"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.center()
        p.delegate = panelDelegate

        // Activate the app briefly so the panel can take key — without this,
        // a backgrounded menu-bar app's panels won't accept keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        panel = p
    }

    /// Programmatically dismiss the composer (e.g. on app teardown).
    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        openedAt = nil
        onSubmit = nil
        onCancel = nil
    }

    private func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let openedAt {
            onSubmit?(openedAt, trimmed)
        }
        teardown()
    }

    private func cancel() {
        onCancel?()
        teardown()
    }

    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        openedAt = nil
        onSubmit = nil
        onCancel = nil
    }

    // The panel delegate is held by the composer (NSPanel.delegate is weak).
    private lazy var panelDelegate: ComposerPanelDelegate = {
        ComposerPanelDelegate { [weak self] in self?.cancel() }
    }()
}

/// NSPanel that can become key — required for text input. The default NSPanel
/// with `.nonactivatingPanel` won't accept keystrokes; overriding canBecomeKey
/// is the standard fix.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ComposerPanelDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Composer view

private struct MeetingNoteComposerView: View {
    let meetingTitle: String
    let offsetSecondsAtOpen: TimeInterval
    let showOffset: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(headerTitle)
                    .font(HeardFont.title)
                    .foregroundStyle(HeardTheme.Terminal.ink)
                Spacer()
                if showOffset {
                    Text("[\(offsetSecondsAtOpen.timestampString)]")
                        .font(HeardFont.value)
                        .monospacedDigit()
                        .foregroundStyle(HeardTheme.Terminal.mute)
                }
            }

            NoteTextEditor(
                text: $text,
                onSubmit: { submitIfNotEmpty() },
                onCancel: onCancel
            )
            .frame(minHeight: 96)
            .overlay(
                Rectangle()
                    .stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline)
            )

            HStack(spacing: 8) {
                Text("↩ to save  ·  ⌘↩ new line  ·  Esc to cancel")
                    .font(HeardFont.caption)
                    .foregroundStyle(HeardTheme.Terminal.mute)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(TerminalButtonStyle(.ghost))
                Button("Save Note") { submitIfNotEmpty() }
                    .buttonStyle(TerminalButtonStyle(.primary))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420, height: 200, alignment: .topLeading)
        .background(HeardTheme.Terminal.bg)
    }

    private func submitIfNotEmpty() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }

    private var headerTitle: String {
        let trimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Note" : "Note · \(trimmed)"
    }
}

// MARK: - NSViewRepresentable text editor

/// Wraps NSTextView directly so we can intercept Return / Cmd+Return at the
/// AppKit level. SwiftUI's `onKeyPress` never fires inside a TextEditor because
/// the underlying NSTextView consumes Return before the SwiftUI event system
/// sees it.
private struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.textView
        tv.isRichText = false
        tv.font = NSFont(name: HeardFont.family, size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(HeardTheme.Terminal.surfaceAlt)
        tv.textColor = NSColor(HeardTheme.Terminal.ink)
        tv.insertionPointColor = NSColor(HeardTheme.Terminal.accent)
        tv.textContainerInset = NSSize(width: 4, height: 4)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = tv
        tv.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let tv = context.coordinator.textView
        if tv.string != text {
            tv.string = text
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let textView = NoteNSTextView()
        var text: Binding<String>
        var onSubmit: () -> Void = {}
        var onCancel: () -> Void = {}

        init(text: Binding<String>) {
            self.text = text
            super.init()
            textView.delegate = self
            textView.onReturn = { [weak self] in self?.onSubmit() }
            textView.onEscape = { [weak self] in self?.onCancel() }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

/// NSTextView subclass that routes Return → submit and Cmd+Return → newline.
private final class NoteNSTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Grab first-responder as soon as the view is in a key window so the
        // first keystroke goes into the text field without a manual click.
        if let w = window, w.isKeyWindow {
            w.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            if event.modifierFlags.contains(.command) {
                insertNewline(nil)
            } else {
                onReturn?()
            }
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}
