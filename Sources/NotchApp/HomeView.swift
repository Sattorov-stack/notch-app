import SwiftUI
import AppKit
import EventKit

// MARK: - Главный экран: всё важное в одном месте

struct HomeView: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HomeMusicCard()
                HomeAgentsCard()
                    .frame(width: 190)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                HomeCalendarCard()
                    .frame(width: 196)
                HomeClipCard()
                HomeShelfCard()
                    .frame(width: 126)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Музыка

private struct HomeMusicCard: View {
    @ObservedObject var m = MusicService.shared

    private var progress: CGFloat {
        guard m.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, m.position / m.duration)))
    }

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("МУЗЫКА")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    if !m.app.isEmpty {
                        Text(m.app)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }

                if m.title.isEmpty {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ничего не играет")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Music, Spotify или видео в браузере — включи и вернись")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                smallButton("Music") { m.open("Music") }
                                smallButton("Spotify") { m.open("Spotify") }
                                smallButton("Яндекс") { m.open("Яндекс Музыка") }
                            }
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "waveform")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundStyle(Theme.accent.opacity(0.12))
                            .padding(.trailing, 8)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [Theme.accent.opacity(0.55),
                                                              Color.purple.opacity(0.45)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: m.playing ? "waveform" : "pause.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text(m.artist.isEmpty ? (m.browser ? "вкладка браузера" : "—") : m.artist)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { NotchState.shared.tab = .music }

                    if m.duration > 0 && !m.browser {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(Theme.accentSoft).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                    }

                    HStack {
                        if m.duration > 0 && !m.browser {
                            Text(timeText(m.position))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        if m.browserBundle == "org.mozilla.firefox" || m.browserBundle == "ru.yandex.desktop.music" {
                            Text("на вкладке")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.faint)
                        } else {
                            HStack(spacing: 16) {
                                Button { m.command("previous track") } label: {
                                    Image(systemName: m.browser ? "gobackward.10" : "backward.fill")
                                }
                                Button { m.command("playpause") } label: {
                                    Image(systemName: m.browser ? "playpause.fill"
                                          : (m.playing ? "pause.fill" : "play.fill"))
                                        .font(.system(size: 13))
                                }
                                Button { m.command("next track") } label: {
                                    Image(systemName: m.browser ? "goforward.10" : "forward.fill")
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text)
                        }
                        Spacer()
                        if m.duration > 0 && !m.browser {
                            Text(timeText(m.duration))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.faint)
                        } else if m.browser {
                            Text(m.app)
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .onAppear { m.update() }
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Питомцы

private struct HomeAgentsCard: View {
    @ObservedObject var hub = AgentHub.shared

    private var limitKeys: [String] {
        hub.limits.keys.sorted().filter { hub.limits[$0] != nil }
    }

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("ПИТОМЦЫ")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    ServerDot(ok: hub.serverOK)
                    Text(":\(String(AgentHub.port))")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.faint)
                }

                HStack(spacing: 5) {
                    ForEach(hub.agents.prefix(4), id: \.self) { a in
                        AgentChip(agent: a)
                    }
                    if hub.agents.count > 4 {
                        Text("+\(hub.agents.count - 4)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                if limitKeys.isEmpty {
                    Text("Лимиты появятся, когда агент пришлёт remaining")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                } else {
                    Text(limitKeys.map { key in
                        let pct = Int(hub.limits[key]?.remaining ?? 0)
                        return hub.displayName(for: key) + " " + String(pct) + "%"
                    }.joined(separator: " · "))
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    NotchState.shared.tab = .pets
                } label: {
                    HStack(spacing: 3) {
                        Text("Все питомцы")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.accentSoft)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Календарь

private struct HomeCalendarCard: View {
    @ObservedObject var cal = CalendarService.shared

    private var upcoming: [EKEvent] {
        cal.events.filter { $0.endDate >= Date() }.prefix(2).map { $0 }
    }

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.orange)
                    Text("СЕГОДНЯ")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Text(Date().formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }

                if !cal.authorized {
                    Text("Нет доступа к Календарю")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                    Button("Разрешить") { cal.request() }
                        .font(.system(size: 10))
                        .controlSize(.small)
                } else if upcoming.isEmpty {
                    Text("Событий больше нет")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(upcoming, id: \.self) { e in
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.orange.opacity(0.85))
                                    .frame(width: 2.5, height: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.isAllDay ? "весь день"
                                         : e.startDate.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.faint)
                                    Text(e.title ?? "")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    NotchState.shared.tab = .calendar
                } label: {
                    HStack(spacing: 3) {
                        Text("Календарь")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.accentSoft)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Буфер

private struct HomeClipCard: View {
    @ObservedObject var store = ClipboardStore.shared

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("БУФЕР")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Text("\(store.items.count)")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }

                if store.items.isEmpty {
                    Text("Скопируй что-нибудь — появится здесь")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 3) {
                        ForEach(store.items.prefix(3)) { item in
                            Button { store.copy(item) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.faint)
                                    Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        NotchState.shared.tab = .clipboard
                    } label: {
                        Text("Вся история →")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Полка

private struct HomeShelfCard: View {
    @ObservedObject var shelf = ShelfStore.shared

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.green)
                    Text("ПОЛКА")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                }
                if shelf.items.isEmpty {
                    Text("Перетащи файл в чёлку")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                } else {
                    HStack(spacing: 8) {
                        ForEach(shelf.items.prefix(3)) { item in
                            let url = URL(fileURLWithPath: item.path)
                            Button { NSWorkspace.shared.open(url) } label: {
                                VStack(spacing: 2) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(1)
                                        .frame(width: 44)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(url.lastPathComponent)
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    NotchState.shared.tab = .shelf
                } label: {
                    Text("Открыть полку →")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.accentSoft)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Мелкие детали

struct MiniBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(value < 0.2 ? Theme.red : (value < 0.5 ? Theme.orange : Theme.green))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 3)
    }
}
