import SwiftUI
import AppKit

enum AlertChannel { case local, servers, agents }

/// Дублирует важные уведомления в Telegram — чтобы узнавать о падениях, не сидя за Mac.
/// Нужен свой бот: @BotFather → /newbot → токен; потом написать своему боту /start.
/// Токен хранится только на этом Mac (файл с доступом только для тебя).
final class TelegramNotifier: ObservableObject {
    static let shared = TelegramNotifier()
    @Published var token = ""
    @Published var chatId = ""
    @Published var servers = true
    @Published var agents = false
    @Published var status = ""

    private let url = Disk.dir.appendingPathComponent("telegram.json")

    init() { load() }

    var isReady: Bool { !token.isEmpty && !chatId.isEmpty }

    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    func load() {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        token = o["token"] as? String ?? ""
        chatId = o["chat"] as? String ?? ""
        servers = o["servers"] as? Bool ?? true
        agents = o["agents"] as? Bool ?? false
    }

    func save() {
        let o: [String: Any] = ["token": cleanToken, "chat": chatId, "servers": servers, "agents": agents]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Вызывается для каждого уведомления чёлки — отправляет только выбранные виды
    func forward(_ a: AlertItem) {
        guard isReady else { return }
        switch a.channel {
        case .servers where servers: break
        case .agents where agents: break
        default: return
        }
        send("\(a.emoji) \(a.title)\n\(a.text)")
    }

    func send(_ text: String, done: ((Bool, String) -> Void)? = nil) {
        guard let u = URL(string: "https://api.telegram.org/bot\(cleanToken)/sendMessage") else {
            done?(false, "Неверный токен")
            return
        }
        var r = URLRequest(url: u, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatId, "text": text])
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let desc = obj?["description"] as? String
            DispatchQueue.main.async { done?(code == 200, code == 200 ? "Отправлено ✓" : (desc ?? "Ошибка \(code)")) }
        }.resume()
    }

    /// Находит твой чат по последнему сообщению боту (сначала напиши боту /start)
    func detectChat() {
        save()
        status = "Ищу чат…"
        guard let u = URL(string: "https://api.telegram.org/bot\(cleanToken)/getUpdates") else {
            status = "Неверный токен"
            return
        }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            var found: String?
            var err: String?
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let res = o["result"] as? [[String: Any]] {
                    for upd in res.reversed() {
                        let msg = (upd["message"] as? [String: Any]) ?? (upd["my_chat_member"] as? [String: Any])
                        if let chat = msg?["chat"] as? [String: Any], let id = chat["id"] as? NSNumber {
                            found = id.stringValue
                            break
                        }
                    }
                } else {
                    err = o["description"] as? String
                }
            } else {
                err = "Нет связи с Telegram"
            }
            DispatchQueue.main.async {
                if let found {
                    self.chatId = found
                    self.save()
                    self.send("✅ Чёлка подключена. Сюда будут приходить уведомления о серверах.") { ok, m in
                        self.status = ok ? "Подключено ✓" : m
                    }
                } else {
                    self.status = err ?? "Сообщений нет: напиши своему боту /start и нажми ещё раз"
                }
            }
        }.resume()
    }
}

struct TelegramSettingsView: View {
    @ObservedObject var tg = TelegramNotifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Уведомления в Telegram")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
            Text("1) В Telegram открой @BotFather → /newbot → скопируй токен.\n2) Вставь токен ниже и напиши своему новому боту /start.\n3) Нажми «Подключить» — придёт сообщение-проверка.")
                .font(.system(size: 9.5)).foregroundStyle(Theme.dim)
            SecureField("Токен бота", text: $tg.token).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Button("Подключить") { tg.detectChat() }.disabled(tg.token.isEmpty)
                Button("Проверить") {
                    tg.send("🔔 Проверка уведомлений от чёлки") { ok, m in tg.status = ok ? "Пришло? ✓" : m }
                }
                .disabled(!tg.isReady)
                Text(tg.status).font(.system(size: 9.5)).foregroundStyle(Theme.dim).lineLimit(2)
            }
            Toggle("Серверы, сайты и резервные копии", isOn: $tg.servers).toggleStyle(.checkbox)
            Toggle("ИИ-агенты: «готово», «нужно разрешение», лимиты", isOn: $tg.agents).toggleStyle(.checkbox)
            Text("Работает, пока Mac не спит. Чтобы не засыпал с закрытой крышкой — «Инструменты» → «Не засыпать».")
                .font(.system(size: 9)).foregroundStyle(Theme.faint)
        }
        .font(.system(size: 10.5))
        .controlSize(.small)
        .onChange(of: tg.servers) { _, _ in tg.save() }
        .onChange(of: tg.agents) { _, _ in tg.save() }
    }
}
