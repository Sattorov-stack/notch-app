import SwiftUI

struct NotchView: View {
    @ObservedObject var state = NotchState.shared

    var body: some View {
        ZStack(alignment: .top) {
            GlassBackdrop()
            Group {
                if state.expanded {
                    ExpandedView(state: state)
                        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                } else if let a = state.alert {
                    AlertView(item: a)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.compactNotch, true)
        .buttonStyle(GlassButtonStyle())
        .animation(.easeOut(duration: 0.16), value: state.expanded)
    }
}

struct ExpandedView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var hub = AgentHub.shared

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            rail(Tab.leftRail)
            VStack(spacing: 9) {
                header
                SectionBody(tab: state.tab)
                    // Раздел не может растянуть панель: лишнее прокручивается внутри, углы на месте
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            .frame(maxWidth: .infinity)
            rail(Tab.rightRail)
        }
        .padding(.horizontal, 10)
        .padding(.top, state.notchH + 2)
        .padding(.bottom, 10)
    }

    private func rail(_ tabs: [Tab]) -> some View {
        VStack(spacing: 2) {
            ForEach(tabs) { t in
                RailButton(tab: t, active: state.tab == t) {
                    withAnimation(.easeOut(duration: 0.12)) { state.tab = t }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 42)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            SectionHeader(title: state.tab.title, subtitle: state.tab.subtitle)
            Spacer(minLength: 8)

            if let a = state.alert {
                Button {
                    state.dismissAlert()
                    state.tab = .pets
                } label: {
                    HStack(spacing: 4) {
                        Text(a.emoji).font(.system(size: 12))
                        Text(a.kind == .permission ? "Нужно разрешение"
                             : (a.kind == .done ? "Готово" : "Событие"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(kindColor(a.kind))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(kindColor(a.kind).opacity(0.14)))
                    .overlay(Capsule().strokeBorder(kindColor(a.kind).opacity(0.35), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .help(a.text)
            }

            MirrorButton()
            ColorPickButton()
            GlassIconButton(icon: "macwindow", help: "Открыть раздел в отдельном окне") {
                SectionWindows.shared.open(state.tab)
            }
            GlassIconButton(icon: state.pinned ? "pin.fill" : "pin",
                            tint: state.pinned ? Theme.orange : .white,
                            help: state.pinned ? "Открепить" : "Закрепить меню открытым") {
                state.pinned.toggle()
            }
            GlassIconButton(icon: "chevron.up", help: "Свернуть") {
                state.onExpandRequest?(false)
            }
        }
    }
}

/// Питомец выглядывает из чёлки с сообщением агента.
/// Уведомление в чёлке: только полоса по бокам от неё, на экран не опускается.
/// Слева — значок и от кого, справа — суть одной строкой. Полный текст — в подсказке.
struct AlertView: View {
    let item: AlertItem

    private var accent: Color {
        switch item.kind {
        case .done: return Theme.green
        case .permission: return Theme.orange
        case .error: return Theme.red
        case .info: return Theme.accentSoft
        }
    }

    var body: some View {
        let s = NotchState.shared
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(item.emoji).font(.system(size: 12))
                Text(item.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: s.notchW)              // место самой чёлки
            Text(item.text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: s.notchH)
        .contentShape(Rectangle())
        .help("\(item.title): \(item.text)")
        .onTapGesture {
            s.dismissAlert()
            if item.channel == .servers {
                s.tab = .servers
                s.onExpandRequest?(true)
            }
        }
    }
}
