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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            HStack(spacing: 5) {
                ServerDot(ok: hub.serverOK)
                Text("\(hub.agents.count) ИИ")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.07)))

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
struct AlertView: View {
    let item: AlertItem
    @State private var hop = false

    private var accent: Color {
        switch item.kind {
        case .done: return Theme.green
        case .permission: return Theme.orange
        case .error: return Theme.red
        case .info: return Theme.accentSoft
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Text(item.emoji)
                .font(.system(size: 27))
                .offset(y: hop ? -3 : 2)
                .animation(.easeInOut(duration: 0.38).repeatForever(autoreverses: true), value: hop)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Text(item.text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18)
        .padding(.top, NotchState.shared.notchH + 4)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onAppear { hop = true }
        .onTapGesture {
            let s = NotchState.shared
            s.dismissAlert()
            s.tab = .pets
            s.onExpandRequest?(true)
        }
    }
}
