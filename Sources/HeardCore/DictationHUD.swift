import AppKit
import SwiftUI

// A small floating panel shown when dictation is active.
// Appears at the bottom-centre of the screen with a mic animation.
// Fades to semi-transparent after a brief delay so it's unobtrusive,
// then fades out fully when dictation stops.
@MainActor
public final class DictationHUD {
    public static let shared = DictationHUD()

    private var panel: NSPanel?
    private var fadeTimer: Timer?

    private static let size = NSSize(width: 160, height: 44)
    private static let activeAlpha: CGFloat = 1.0
    private static let dimmedAlpha: CGFloat = 0.35
    private static let fadeDelay: TimeInterval = 2.5

    public func show() {
        if panel == nil { buildPanel() }
        fadeTimer?.invalidate()
        panel?.alphaValue = Self.activeAlpha
        panel?.orderFront(nil)
        // Dim after a delay — stays visible but unobtrusive while recording
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Self.fadeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.animateAlpha(to: Self.dimmedAlpha, duration: 0.5)
            }
        }
    }

    public func hide() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        animateAlpha(to: 0, duration: 0.25) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    private func animateAlpha(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            panel?.animator().alphaValue = target
        }, completionHandler: completion)
    }

    private func buildPanel() {
        let content = NSHostingView(rootView: DictationHUDView())
        content.frame = NSRect(origin: .zero, size: Self.size)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = content
        p.alphaValue = 0

        positionPanel(p)
        panel = p
    }

    private func positionPanel(_ p: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let sf = screen.visibleFrame
        let origin = CGPoint(
            x: sf.midX - Self.size.width / 2,
            y: sf.minY + 72
        )
        p.setFrameOrigin(origin)
    }
}

// MARK: - HUD content view

private struct DictationHUDView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              options: .repeating)
            Text("Dictating")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(width: 160, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
