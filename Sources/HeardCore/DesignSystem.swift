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

enum HeardTheme {
    enum Paper {
        static let bg           = Color(light: "F5EFE4", dark: "1C2024")
        static let surface      = Color(light: "FBF7EF", dark: "252A30")
        static let surfaceAlt   = Color(light: "EFE7D7", dark: "2E3338")
        static let sidebar      = Color(light: "EBE2CE", dark: "22272D")
        static let border       = Color(light: "D9CFB9", dark: "4A515A")
        static let borderSoft   = Color(light: "E5DCC8", dark: "3A3F47")
        static let ink          = Color(light: "1C2024", dark: "F5EFE4")
        static let ink2         = Color(light: "3A3F47", dark: "D9CFB9")
        static let mute         = Color(light: "7B7264", dark: "9A9184")
        static let muteSoft     = Color(light: "C9BBA5", dark: "4A515A")
        static let accent       = Color(light: "3F5C8C", dark: "658BC9")
        static let accentInk    = Color(light: "2F4570", dark: "8BB2F2")
        static let accentSoft   = Color(light: "E5EAF3", dark: "26334A")
        static let good         = Color(light: "3D7A4F", dark: "53A66B")
        static let goodSoft     = Color(light: "E1EEDF", dark: "243D2D")
        static let warn         = Color(light: "A66A1F", dark: "D98A29")
        static let warnSoft     = Color(light: "F4E6CE", dark: "4D351A")
        static let bad          = Color(light: "A6452B", dark: "D65738")
        static let badSoft      = Color(light: "F2DCD2", dark: "4A251C")
        static let recordingBg  = Color(light: "2E3338", dark: "A6452B")
        static let recordingInk = Color(light: "F5EFE4", dark: "1C2024")
    }

    static var accent: Color { Paper.accent }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        static let inline: CGFloat = 6
        static let card: CGFloat = 10
        static let hero: CGFloat = 14
    }
}

// MARK: - HeardMark

struct HeardMark: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 64
            // Squircle background gradient
            let bgPath = RoundedRectangle(cornerRadius: 14 * s)
                .path(in: CGRect(origin: .zero, size: sz))
            ctx.fill(bgPath, with: .linearGradient(
                Gradient(colors: [Color(hex: "E8DFD2"), Color(hex: "C9BBA5")]),
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
                Gradient(colors: [Color(hex: "2E3338"), Color(hex: "1C2024")]),
                startPoint: CGPoint(x: sz.width / 2, y: 0),
                endPoint: CGPoint(x: sz.width / 2, y: sz.height)
            ))
            // Three dots (cx 24/32/40, cy 29, r 2.4/3.2/2.4)
            let dot = Color(hex: "E8DFD2")
            ctx.fill(Path(ellipseIn: CGRect(x: (24-2.4)*s, y: (29-2.4)*s, width: 4.8*s, height: 4.8*s)),
                     with: .color(dot.opacity(0.65)))
            ctx.fill(Path(ellipseIn: CGRect(x: (32-3.2)*s, y: (29-3.2)*s, width: 6.4*s, height: 6.4*s)),
                     with: .color(dot))
            ctx.fill(Path(ellipseIn: CGRect(x: (40-2.4)*s, y: (29-2.4)*s, width: 4.8*s, height: 4.8*s)),
                     with: .color(dot.opacity(0.65)))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Toggle Style
struct HeardToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? HeardTheme.Paper.accent : HeardTheme.Paper.muteSoft)
                .frame(width: 30, height: 18)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.14), value: configuration.isOn)
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Shared card components
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.7)
            .foregroundStyle(HeardTheme.Paper.mute)
    }
}
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeardTheme.Paper.surface)
        .clipShape(RoundedRectangle(cornerRadius: HeardTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: HeardTheme.Radius.card)
                .stroke(HeardTheme.Paper.border, lineWidth: 0.5)
        )
        .shadow(color: Color(red: 60/255, green: 45/255, blue: 20/255).opacity(0.06),
                radius: 1, x: 0, y: 1)
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
                HeardTheme.Paper.borderSoft
                    .frame(height: 0.5)
                    .padding(.leading, 12)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HeardTheme.Paper.ink)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(HeardTheme.Paper.mute)
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
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}

// Used inside the dark hero card in the Models tab
struct HeroButtonStyle: ButtonStyle {
    var isDanger: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isDanger ? Color(hex: "F2DCD2") : HeardTheme.Paper.recordingInk)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                isDanger ? Color(hex: "A6452B").opacity(0.4) : Color.white.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(pulse ? 0.22 : 0))
                    .frame(width: 13, height: 13)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            }
            Circle()
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
                .textFieldStyle(.roundedBorder)
        } else {
            Text(value)
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
