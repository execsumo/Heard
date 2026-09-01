import AVFoundation
import SwiftUI

// MARK: - Color helpers
extension Color {
    init(hex: String) {
        let v = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: v).scanHexInt64(&n)
        self.init(
            red:   Double((n >> 16) & 0xFF) / 255,
            green: Double((n >>  8) & 0xFF) / 255,
            blue:  Double( n        & 0xFF) / 255
        )
    }
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(Color(hex: dark))
            } else {
                return NSColor(Color(hex: light))
            }
        }))
    }
}

// MARK: - AppAppearance Extension

public extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Appearance Modifier
struct AppearanceModifier: ViewModifier {
    let appearance: AppAppearance
    @State private var systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(resolvedScheme)
            .onReceive(
                DistributedNotificationCenter.default()
                    .publisher(for: NSNotification.Name("AppleInterfaceThemeChangedNotification"))
            ) { _ in
                // Short delay: effectiveAppearance may not yet reflect the change
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                }
            }
    }

    private var resolvedScheme: ColorScheme? {
        switch appearance {
        case .system: systemIsDark ? .dark : .light
        case .light:  .light
        case .dark:   .dark
        }
    }
}

public extension View {
    func heardAppearance(_ appearance: AppAppearance) -> some View {
        modifier(AppearanceModifier(appearance: appearance))
    }
}

// MARK: - Theme
//
// "Modern Terminal Brutalism" — see DESIGN.md. Dark values are the spec verbatim;
// light values are a derived "paper terminal" counterpart so the Appearance
// preference (System/Light/Dark) keeps working. Ink-black surfaces, warm amber
// primary, structural borders instead of shadows, square corners everywhere.

enum HeardTheme {
    enum Terminal {
        // Surfaces — flat backgrounds, containers lift by one tonal step
        static let bg           = Color(light: "F4F3F0", dark: "131316")
        static let surface      = Color(light: "FFFFFF", dark: "1B1B1F")
        static let surfaceAlt   = Color(light: "EAE8E3", dark: "201F23")
        static let surfaceHigh  = Color(light: "DFDCD6", dark: "2A292D")
        static let sidebar      = Color(light: "EDEBE7", dark: "0E0E11")

        // Structure — depth is borders, not shadows
        static let border       = Color(light: "CFCBC4", dark: "2A292D")
        static let borderSoft   = Color(light: "E3E0DA", dark: "1C1C22")

        // Text
        static let ink          = Color(light: "131316", dark: "E5E1E6")
        static let ink2         = Color(light: "3A3A3F", dark: "D7C3B4")
        static let mute         = Color(light: "6E6A63", dark: "9F8D80")
        static let muteSoft     = Color(light: "C4C0B8", dark: "524439")

        // Primary — warm amber
        static let accent       = Color(light: "8A4B00", dark: "FFB46E")
        static let accentInk    = Color(light: "4B2800", dark: "FFD9BA")
        static let accentSoft   = Color(light: "FFEBD6", dark: "3A2A16")

        // Status
        static let good         = Color(light: "4F7A0F", dark: "A6E22E")
        static let goodSoft     = Color(light: "EDF4DA", dark: "25300F")
        static let warn         = Color(light: "8A5A00", dark: "FFB876")
        static let warnSoft     = Color(light: "FBEBD6", dark: "3A2A16")
        static let bad          = Color(light: "93000A", dark: "FFB4AB")
        static let badSoft      = Color(light: "FFDAD6", dark: "4A1417")
        static let info         = Color(light: "00596B", dark: "66D9EF")
        static let infoSoft     = Color(light: "DCF3FA", dark: "0E2A32")

        // Recording strip
        static let recordingBg  = Color(light: "131316", dark: "93000A")
        static let recordingInk = Color(light: "F4F3F0", dark: "FFDAD6")

        // Syntax accents — reserved for terminal output / code
        static let terminalGreen = Color(light: "4F7A0F", dark: "A6E22E")
        static let terminalBlue  = Color(light: "00596B", dark: "66D9EF")

        /// Heavy dim for modals and overlays (DESIGN.md: 80% black).
        static let scrim = Color.black.opacity(0.8)
    }

    static var accent: Color { Terminal.accent }

    /// 4px baseline. DESIGN.md increments: 8, 16, 24, 32, 48, 64.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let gutter: CGFloat = 24
    }

    /// The shape language is strictly sharp. These stay as named members so call
    /// sites read intentionally, but every one of them is 0.
    enum Radius {
        static let inline: CGFloat = 0
        static let card: CGFloat = 0
        static let hero: CGFloat = 0
    }

    /// Structural borders are 1px — visible, not hairline.
    enum Stroke {
        static let hairline: CGFloat = 1
        static let emphasis: CGFloat = 2
    }
}

// MARK: - Typography
//
// JetBrains Mono exclusively (DESIGN.md). The TTFs ship in Resources/Fonts and are
// registered by ATSApplicationFontsPath in Info.plist, so they resolve only inside
// the .app bundle — under `swift run` we fall back to the system monospaced face
// rather than silently rendering in San Francisco.
//
// DESIGN.md's scale is web-sized (48/32/16/14/12); it is mapped down to the app's
// macOS scale here, preserving the hierarchy and switching the family.

enum HeardFont {
    static let family = "JetBrains Mono"

    /// The bundled face only resolves inside the .app bundle (ATSApplicationFontsPath),
    /// so under `swift run` this is false and every role falls back to system monospaced.
    static let isAvailable: Bool = NSFont(name: family, size: 12) != nil

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        isAvailable
            ? .custom(family, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }

    static var headlineXL: Font  { mono(26, .bold) }      // About sheet app name
    static var headlineLG: Font  { mono(19, .semibold) }  // pane H1
    static var title: Font       { mono(13, .semibold) }  // window + card titles
    static var body: Font        { mono(12) }             // row labels
    static var bodyMedium: Font  { mono(12, .medium) }    // emphasised row labels
    static var caption: Font     { mono(11) }             // subtitles
    static var label: Font       { mono(10.5, .bold) }    // UPPERCASE section labels
    static var value: Font       { mono(11) }             // tabular values, paths, sizes
    static var pill: Font        { mono(10, .semibold) }
}

// MARK: - HeardMark

struct HeardMark: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 64
            // Square enclosure — the shape language is strictly sharp
            let bgPath = Path(CGRect(origin: .zero, size: sz))
            ctx.fill(bgPath, with: .linearGradient(
                Gradient(colors: [Color(hex: "FFD9BA"), Color(hex: "FFB46E")]),
                startPoint: CGPoint(x: sz.width / 2, y: 0),
                endPoint: CGPoint(x: sz.width / 2, y: sz.height)
            ))
            // Bubble shape
            var bubble = Path()
            bubble.move(to: CGPoint(x: 16*s, y: 22*s))
            bubble.addCurve(to: CGPoint(x: 22*s, y: 16*s),
                            control1: CGPoint(x: 16*s, y: 18.7*s),
                            control2: CGPoint(x: 19.4*s, y: 16*s))
            bubble.addLine(to: CGPoint(x: 42*s, y: 16*s))
            bubble.addCurve(to: CGPoint(x: 48*s, y: 22*s),
                            control1: CGPoint(x: 45.3*s, y: 16*s),
                            control2: CGPoint(x: 48*s, y: 18.7*s))
            bubble.addLine(to: CGPoint(x: 48*s, y: 36*s))
            bubble.addCurve(to: CGPoint(x: 42*s, y: 42*s),
                            control1: CGPoint(x: 48*s, y: 39.3*s),
                            control2: CGPoint(x: 45.3*s, y: 42*s))
            bubble.addLine(to: CGPoint(x: 35*s, y: 42*s))
            bubble.addLine(to: CGPoint(x: 28*s, y: 48*s))
            bubble.addLine(to: CGPoint(x: 28*s, y: 42*s))
            bubble.addLine(to: CGPoint(x: 22*s, y: 42*s))
            bubble.addCurve(to: CGPoint(x: 16*s, y: 36*s),
                            control1: CGPoint(x: 18.7*s, y: 42*s),
                            control2: CGPoint(x: 16*s, y: 39.3*s))
            bubble.closeSubpath()
            ctx.fill(bubble, with: .linearGradient(
                Gradient(colors: [Color(hex: "201F23"), Color(hex: "131316")]),
                startPoint: CGPoint(x: sz.width / 2, y: 0),
                endPoint: CGPoint(x: sz.width / 2, y: sz.height)
            ))
            // Three blocks (cx 24/32/40, cy 29) — square, per the shape language
            let dot = Color(hex: "FFB46E")
            ctx.fill(Path(CGRect(x: (24-2.4)*s, y: (29-2.4)*s, width: 4.8*s, height: 4.8*s)),
                     with: .color(dot.opacity(0.65)))
            ctx.fill(Path(CGRect(x: (32-3.2)*s, y: (29-3.2)*s, width: 6.4*s, height: 6.4*s)),
                     with: .color(dot))
            ctx.fill(Path(CGRect(x: (40-2.4)*s, y: (29-2.4)*s, width: 4.8*s, height: 4.8*s)),
                     with: .color(dot.opacity(0.65)))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Toggle Style
struct HeardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Rectangle()
                .fill(configuration.isOn ? HeardTheme.Terminal.accent : HeardTheme.Terminal.surfaceAlt)
                .overlay(
                    Rectangle()
                        .stroke(configuration.isOn ? HeardTheme.Terminal.accent : HeardTheme.Terminal.border,
                                lineWidth: HeardTheme.Stroke.hairline)
                )
                .frame(width: 32, height: 18)
            Rectangle()
                .fill(configuration.isOn ? HeardTheme.Terminal.bg : HeardTheme.Terminal.mute)
                .frame(width: 12, height: 12)
                .padding(3)
        }
        .animation(.easeInOut(duration: 0.14), value: configuration.isOn)
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Button Style
//
// DESIGN.md: large sharp rectangles. Primary is a solid amber fill with ink text;
// secondary is a 1px border with no fill. Pressed states invert.

struct TerminalButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case sm, md }

    var kind: Kind = .secondary
    var size: Size = .md

    init(_ kind: Kind = .secondary, size: Size = .md) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(size == .sm ? HeardFont.mono(11, .medium) : HeardFont.mono(12, .medium))
            .foregroundStyle(foreground(pressed: pressed))
            .padding(.vertical, size == .sm ? 3 : 5)
            .padding(.horizontal, size == .sm ? 8 : 12)
            .background(Rectangle().fill(background(pressed: pressed)))
            .overlay(
                Rectangle().stroke(border, lineWidth: HeardTheme.Stroke.hairline)
            )
            .contentShape(Rectangle())
    }

    private var border: Color {
        switch kind {
        case .primary:   HeardTheme.Terminal.accent
        case .secondary: HeardTheme.Terminal.border
        case .ghost:     .clear
        case .danger:    HeardTheme.Terminal.bad
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:   pressed ? HeardTheme.Terminal.bg : HeardTheme.Terminal.accent
        case .secondary: pressed ? HeardTheme.Terminal.ink : .clear
        case .ghost:     pressed ? HeardTheme.Terminal.surfaceAlt : .clear
        case .danger:    pressed ? HeardTheme.Terminal.bad : .clear
        }
    }

    private func foreground(pressed: Bool) -> Color {
        switch kind {
        case .primary:   pressed ? HeardTheme.Terminal.accent : HeardTheme.Terminal.bg
        case .secondary: pressed ? HeardTheme.Terminal.bg : HeardTheme.Terminal.ink
        case .ghost:     HeardTheme.Terminal.ink2
        case .danger:    pressed ? HeardTheme.Terminal.bg : HeardTheme.Terminal.bad
        }
    }
}

// MARK: - Text Field Style
//
// DESIGN.md: styled like a command line — square, bordered, monospaced.

struct TerminalTextFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(HeardFont.body)
            .foregroundStyle(HeardTheme.Terminal.ink)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Rectangle().fill(HeardTheme.Terminal.surfaceAlt))
            .overlay(
                Rectangle().stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline)
            )
    }
}

// MARK: - Shared card components

/// 1px hairline used to separate rows and card titles from content.
struct TerminalRule: View {
    var color: Color = HeardTheme.Terminal.borderSoft
    var body: some View {
        color.frame(height: HeardTheme.Stroke.hairline)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(HeardFont.label)
            .kerning(0.6)
            .foregroundStyle(HeardTheme.Terminal.mute)
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeardTheme.Terminal.surface)
        .overlay(
            Rectangle()
                .stroke(HeardTheme.Terminal.border, lineWidth: HeardTheme.Stroke.hairline)
        )
    }
}

/// DESIGN.md: card titles are separated from content by a 1px horizontal rule.
struct CardHeader: View {
    let title: String
    var trailing: AnyView? = nil

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HeardTheme.Spacing.sm) {
                Text(title.uppercased())
                    .font(HeardFont.label)
                    .kerning(0.6)
                    .foregroundStyle(HeardTheme.Terminal.ink2)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            TerminalRule(color: HeardTheme.Terminal.border)
        }
    }
}

struct CardRow<Content: View>: View {
    var isLast: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            if !isLast {
                // Full-bleed: structural borders define sections, not inset whitespace
                TerminalRule()
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var isLast: Bool = false
    let isOn: Binding<Bool>

    var body: some View {
        CardRow(isLast: isLast) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HeardFont.bodyMedium)
                        .foregroundStyle(HeardTheme.Terminal.ink)
                    if let sub = subtitle {
                        Text(sub)
                            .font(HeardFont.caption)
                            .foregroundStyle(HeardTheme.Terminal.mute)
                    }
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(HeardToggleStyle())
                    .labelsHidden()
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    let fg: Color
    let bg: Color

    var body: some View {
        Text(text.uppercased())
            .font(HeardFont.pill)
            .kerning(0.4)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Rectangle().fill(bg))
            .overlay(Rectangle().stroke(fg.opacity(0.35), lineWidth: HeardTheme.Stroke.hairline))
    }
}

// Used inside the dark hero card in the Models tab
struct HeroButtonStyle: ButtonStyle {
    var isDanger: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let tint = isDanger ? HeardTheme.Terminal.bad : HeardTheme.Terminal.recordingInk
        return configuration.label
            .font(HeardFont.mono(11, .medium))
            .foregroundStyle(configuration.isPressed ? HeardTheme.Terminal.recordingBg : tint)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(Rectangle().fill(configuration.isPressed ? tint : Color.clear))
            .overlay(Rectangle().stroke(tint.opacity(0.55), lineWidth: HeardTheme.Stroke.hairline))
            .contentShape(Rectangle())
    }
}

/// Square status block — the shape language is sharp, so this is a block, not a dot.
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing {
                Rectangle()
                    .fill(color.opacity(pulse ? 0.22 : 0))
                    .frame(width: 13, height: 13)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            }
            Rectangle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 13, height: 13)
        .onAppear { if pulsing { pulse = true } }
    }
}

struct InlineEditableText: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        if isEditing {
            TextField("Name", text: $draft, onCommit: commit)
                .textFieldStyle(TerminalTextFieldStyle())
        } else {
            Text(value)
                .font(HeardFont.body)
                .onTapGesture {
                    draft = value
                    isEditing = true
                }
        }
    }

    private func commit() {
        isEditing = false
        guard !draft.isEmpty else { return }
        onCommit(draft)
    }
}

// MARK: - Flow Layout
struct WrapLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                y += rowHeight + vSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + vSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct FlowLayout<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: [Data.Element]
    private let id: KeyPath<Data.Element, ID>
    private let content: (Data.Element) -> Content

    init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = Array(data)
        self.id = id
        self.content = content
    }

    var body: some View {
        WrapLayout(hSpacing: 8, vSpacing: 8) {
            ForEach(data, id: id, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
