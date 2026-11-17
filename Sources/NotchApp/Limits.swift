import Foundation
import Security

/// Настоящие остатки лимитов — те же запросы, которыми пользуются сами Claude Code и Codex:
///   • Claude:  GET api.anthropic.com/api/oauth/usage  (вход Claude Code из связки ключей)
///   • Codex:   GET chatgpt.com/backend-api/wham/usage (вход из ~/.codex/auth.json)
/// Ключи читаются только на этом Mac и отправляются только на сервер своего сервиса.
/// Остальные сервисы (ChatGPT-чат, Gemini, Cursor, DeepSeek, Grok…) остаток наружу не отдают.
final class LimitFetcher: ObservableObject {
    static let shared = LimitFetcher()
    @Published var status: [String: String] = [:]     // агент → почему нет данных
    @Published var lastUpdate: Date?

    private var timer: Timer?
    private var busy = false
    private var claudeDenied = false
    private var claudeToken: String?
    private var claudeRead = false
    private var claudeSeen: Date?
    @Published var claudeLinked = UserDefaults.standard.bool(forKey: "claudeLinked")

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refreshIfStale() {
        if let t = lastUpdate, Date().timeIntervalSince(t) < 60 { return }
        refresh()
    }

    /// force — повторно спросить доступ к входу Claude, если раньше отказали
    func refresh(force: Bool = false) {
        if force {
            claudeRead = false
            if !claudeLinked {
                claudeLinked = true
                UserDefaults.standard.set(true, forKey: "claudeLinked")
            }
        }
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            self.fetchCodex()      // первым: Claude может ждать ответа в окне связки ключей
            self.fetchClaude()
            DispatchQueue.main.async {
                self.busy = false
                self.lastUpdate = Date()
            }
        }
    }

    // MARK: Claude (Claude Code и приложение Claude — общий лимит подписки)
    //
    // Вход Claude Code лежит в связке ключей, и чтение защищено окном «Разрешить».
    // Поэтому читаем его только после нажатия ↻ в «Лимитах», а дальше — лишь когда
    // запись изменилась (например, после /login). Иначе macOS спрашивает снова и снова.

    private func claudeItemDate() -> Date? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Code-credentials",
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let a = out as? [String: Any] else { return nil }
        return a[kSecAttrModificationDate as String] as? Date
    }

    private func readClaudeToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Code-credentials",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound {
            note("claude", "Claude Code не вошёл в аккаунт: Терминал → claude → /login, потом ↻")
            return nil
        }
        guard st == errSecSuccess, let data = out as? Data else {
            note("claude", "Доступ к входу Claude Code не разрешён — нажми ↻ и выбери «Разрешать всегда»")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            note("claude", "Claude Code не вошёл в аккаунт: Терминал → claude → /login, потом ↻")
            return nil
        }
        return token
    }

    private func fetchClaude() {
        guard claudeLinked else {
            note("claude", "Лимит Claude: войди в Claude Code (claude → /login) и нажми ↻ здесь")
            return
        }
        let changed = claudeItemDate()
        if !claudeRead || changed != claudeSeen {
            claudeRead = true
            claudeSeen = changed
            claudeToken = readClaudeToken()          // единственное место, где macOS может спросить
        }
        guard let token = claudeToken else { return }
        let (code, j) = get("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "NotchApp/1.1"
        ])
        guard code == 200, let j else {
            note("claude", code == 401 ? "Вход устарел — открой Claude Code, он обновит его сам"
                                       : "Сервер не ответил (код \(code))")
            return
        }
        func window(_ key: String) -> (used: Double, reset: Date?)? {
            guard let w = j[key] as? [String: Any],
                  let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return (u, Self.isoDate(w["resets_at"] as? String))
        }
        guard let five = window("five_hour") else {
            note("claude", "В ответе нет лимита сессии")
            return
        }
        var label = "сессия 5 ч" + Self.resetText(five.reset)
        if let week = window("seven_day") {
            label += " · неделя \(Self.pct(100 - week.used))%"
        }
        publish("claude", remaining: 100 - five.used, label: label)
    }

    // MARK: Codex (подписка ChatGPT)

    private func fetchCodex() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            note("codex", "Codex не вошёл в аккаунт ChatGPT")
            return
        }
        var headers = ["Authorization": "Bearer \(access)",
                       "Accept": "application/json",
                       "User-Agent": "codex_cli_rs"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let (code, j) = get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        guard code == 200, let j else {
            note("codex", code == 401 ? "Вход устарел — открой Codex, он обновит его сам"
                                      : "Сервер не ответил (код \(code))")
            return
        }
        let rl = (j["rate_limit"] as? [String: Any]) ?? j
        func window(_ key: String) -> (used: Double, resetIn: Double?, length: Double?)? {
            guard let w = rl[key] as? [String: Any],
                  let u = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            return (u, (w["reset_after_seconds"] as? NSNumber)?.doubleValue,
                    (w["limit_window_seconds"] as? NSNumber)?.doubleValue)
        }
        guard let primary = window("primary_window") else {
            note("codex", "В ответе нет лимита")
            return
        }
        let hours = Int(((primary.length ?? 18000) / 3600).rounded())
        let span = hours >= 48 ? "\(hours / 24) дн" : "\(hours) ч"
        var label = "окно \(span)" + Self.resetText(primary.resetIn.map { Date().addingTimeInterval($0) })
        if let week = window("secondary_window") {
            label += " · неделя \(Self.pct(100 - week.used))%"
        }
        publish("codex", remaining: 100 - primary.used, label: label)
    }

    // MARK: Общее

    private var lowWarned: Set<String> = []

    private func publish(_ agent: String, remaining: Double, label: String) {
        DispatchQueue.main.async {
            AgentHub.shared.setLimit(agent, remaining: remaining, label: label)
            self.status[agent] = nil
            // Предупреждение, когда осталось меньше 10%
            if remaining < 10 {
                if !self.lowWarned.contains(agent) {
                    self.lowWarned.insert(agent)
                    NotchState.shared.showAlert(AlertItem(emoji: "⏳", title: agent,
                        text: "лимит почти закончился: осталось \(Self.pct(remaining))%", kind: .error, channel: .agents))
                }
            } else {
                self.lowWarned.remove(agent)
            }
        }
    }

    private func note(_ agent: String, _ text: String) {
        DispatchQueue.main.async { self.status[agent] = text }
    }

    private func get(_ url: String, headers: [String: String]) -> (Int, [String: Any]?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var r = URLRequest(url: u, timeoutInterval: 15)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var code = 0
        var json: [String: Any]?
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let data { json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return (code, json)
    }

    static func pct(_ v: Double) -> Int { Int(max(0, min(100, v)).rounded()) }

    static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// « · сброс через 2 ч 10 мин» / « · сброс в 18:40»
    static func resetText(_ d: Date?) -> String {
        guard let d else { return "" }
        let left = Int(d.timeIntervalSinceNow)
        if left <= 0 { return "" }
        if left < 6 * 3600 {
            let h = left / 3600, m = (left % 3600) / 60
            return h > 0 ? " · сброс через \(h) ч \(m) мин" : " · сброс через \(m) мин"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
        return " · сброс \(f.string(from: d))"
    }
}
