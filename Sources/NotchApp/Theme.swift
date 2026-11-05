import SwiftUI
import AppKit

// MARK: - Палитра и «жидкое стекло»

enum Theme {
    static let accent = Color(red: 0.42, green: 0.72, blue: 1.0)
    static let accentSoft = Color(red: 0.62, green: 0.84, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.66, blue: 0.28)
    static let green = Color(red: 0.35, green: 0.86, blue: 0.58)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)

    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.52)
    static let faint = Color.white.opacity(0.30)
    static let stroke = Color.white.opacity(0.10)
    static let cardFill = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.10)
}

enum NotchLayout {
    static let expandedWidth: CGFloat = 600
    static let expandedHeight: CGFloat = 320
    static let corner: CGFloat = 28
    static let railWidth: CGFloat = 54
}

/// Нативное размытие: просвечивает обои и окна, как стекло в macOS.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Стеклянная подложка панели чёлки.
struct GlassBackdrop: View {
    var corner: CGFloat = NotchLayout.corner
    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: corner,
                                           bottomTrailingRadius: corner,
                                           style: .continuous)
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            LinearGradient(colors: [Color(white: 0.08).opacity(0.72),
                                    Color(white: 0.02).opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(
            LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }
}

/// Карточка внутри меню и в отдельном окне.
struct GlassCard<Content: View>: View {
    var padding: CGFloat
    var corner: CGFloat
    let content: Content

    init(padding: CGFloat = 10, corner: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.corner = corner
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16),
                                                      Color.white.opacity(0.03)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 0.9))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
    }
}

/// Круглая кнопка-иконка в стиле стекла.
struct GlassIconButton: View {
    let icon: String
    var tint: Color = .white
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.opacity(hover ? 1 : 0.75))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Кнопка-иконка в боковой панели.
struct RailButton: View {
    let tab: Tab
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.white.opacity(0.15)
                                 : (hover ? Color.white.opacity(0.08) : Color.clear))
                Image(systemName: tab.icon)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.white.opacity(0.58))
            }
            .frame(width: 36, height: 30)
            .overlay(alignment: .leading) {
                if active {
                    Capsule().fill(Theme.accent)
                        .frame(width: 3, height: 15)
                        .offset(x: -7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title)
    }
}

private struct CompactNotchKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true — раздел рисуется внутри чёлки (мало места), false — в отдельном окне.
    var compactNotch: Bool {
        get { self[CompactNotchKey.self] }
        set { self[CompactNotchKey.self] = newValue }
    }
}

/// Единый вид кнопок внутри меню.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.20 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.8))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ServerDot: View {
    let ok: Bool

    var body: some View {
        Circle()
            .fill(ok ? Theme.green : Theme.red)
            .frame(width: 6, height: 6)
            .shadow(color: (ok ? Theme.green : Theme.red).opacity(0.8), radius: 3)
    }
}
