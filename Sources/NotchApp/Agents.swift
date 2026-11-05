import SwiftUI
import AppKit
import Darwin

// MARK: - Модели

struct AgentEvent: Identifiable {
    let id = UUID()
    let agent: String
    let kind: AlertKind
    let message: String
    let date = Date()
}

struct LimitInfo: Codable, Equatable {
    var remaining: Double      // 0...100 %
    var label: String
    var updated = Date()
}

struct AgentFamily {
    let id: String
    let title: String
    let emoji: String
    let keys: [String]
    var bundleKeys: [String] = []
}

// MARK: - HTTP-приёмник событий (127.0.0.1)

/// Простой сервер на BSD-сокетах: без Network.framework, который на macOS
/// отказывался слушать loopback с requiredInterfaceType = .loopback.
final class AgentHTTPServer {
    private let queue = DispatchQueue(label: "notch.agent.http", qos: .utility)
    private var listenFD: Int32 = -1
    private var running = false

    var onJSON: (([String: Any]) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onGetState: (() -> [String: Any]?)?
    var onOpen: ((String) -> Void)?
    var onSnapshot: ((String) -> Bool)?

    func start(port: UInt16) {
        queue.async { [weak self] in self?.listenLoop(port) }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func listenLoop(_ port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            DispatchQueue.main.async { self.onReady?(false) }
            return
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            DispatchQueue.main.async { self.onReady?(false) }
            return
        }

        listenFD = fd
        running = true
        DispatchQueue.main.async { self.onReady?(true) }

        while running {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if !running { break }
                continue
            }
            // Отдельная очередь: listenLoop занимает serial-очередь навсегда,
            // поэтому обработчики нельзя ставить в неё же.
            DispatchQueue.global(qos: .utility).async { self.handle(client) }
        }
        close(fd)
        listenFD = -1
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Int?
        var bodyLength = 0

        while data.count < 2_000_000 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r.upperBound
                let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                for line in head.components(separatedBy: "\r\n")
                where line.lowercased().hasPrefix("content-length:") {
                    bodyLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let end = headerEnd, data.count - end >= bodyLength { break }
        }

        guard let end = headerEnd else { return }
        let head = String(decoding: data[..<end], as: UTF8.self)
        let bodyData = data.dropFirst(end)
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        var status = "200 OK"
        var response = "{\"ok\":true}"

        if method == "POST" && path.hasPrefix("/event") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any] {
                DispatchQueue.main.async { self.onJSON?(obj) }
                response = "{\"ok\":true}"
            } else {
                status = "400 Bad Request"
                response = "{\"ok\":false,\"error\":\"bad json\"}"
            }
        } else if path.hasPrefix("/health") {
            response = "{\"ok\":true,\"port\":47321}"
        } else if path.hasPrefix("/music") {
            DispatchQueue.main.async { MusicService.shared.update() }
            response = "{\"ok\":true}"
        } else if path.hasPrefix("/ax") {
            var dict: [String: Any] = ["trusted": AXWindow.trusted]
            dict["firefox"] = AXWindow.title(bundleID: "org.mozilla.firefox") ?? ""
            dict["chrome"] = AXWindow.title(bundleID: "com.google.Chrome") ?? ""
            dict["firefoxAutomation"] = Automation.allowed("org.mozilla.firefox")
            dict["chromeAutomation"] = Automation.allowed("com.google.Chrome")
            dict["quicktimeAutomation"] = Automation.allowed("com.apple.QuickTimePlayerX")
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let json = String(data: data, encoding: .utf8) {
                response = json
            } else {
                response = "{\"ok\":false}"
            }
        } else if method == "GET" && path.hasPrefix("/browser") {
            let chrome = AppleScriptRunner.run("""
            tell application "Google Chrome"
                if (count of windows) is 0 then return ""
                return (title of active tab of front window) & "||" & (URL of active tab of front window)
            end tell
            """)
            let safari = AppleScriptRunner.run("""
            tell application "Safari"
                if (count of windows) is 0 then return ""
                return (name of current tab of front window) & "||" & (URL of current tab of front window)
            end tell
            """)
            let dict: [String: Any] = ["chrome_out": chrome.out, "chrome_err": chrome.err,
                                       "safari_out": safari.out, "safari_err": safari.err]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let json = String(data: data, encoding: .utf8) {
                response = json
            } else {
                response = "{\"ok\":false}"
            }
        } else if method == "GET" && path.hasPrefix("/state") {
            if let state = onGetState?(),
               let data = try? JSONSerialization.data(withJSONObject: state),
               let json = String(data: data, encoding: .utf8) {
                response = json
            } else {
                response = "{\"ok\":false}"
            }
        } else if method == "POST" && path.hasPrefix("/snapshot") {
            var tab = "home"
            if let obj = try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any],
               let t = obj["tab"] as? String { tab = t }
            let ok = DispatchQueue.main.sync { self.onSnapshot?(tab) ?? false }
            response = ok ? "{\"ok\":true}" : "{\"ok\":false}"
        } else if method == "POST" && path.hasPrefix("/open") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any],
               let tab = obj["tab"] as? String {
                DispatchQueue.main.async { self.onOpen?(tab) }
                response = "{\"ok\":true}"
            } else {
                status = "400 Bad Request"
                response = "{\"ok\":false,\"error\":\"need {tab}\"}"
            }
        } else if method == "GET" && path == "/" {
            response = "{\"ok\":true,\"usage\":\"POST /event {agent,event,message,remaining,label}\"}"
        } else if method == "POST" {
            status = "404 Not Found"
            response = "{\"ok\":false,\"error\":\"unknown path\"}"
        }

        let headOut = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(response.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(headOut.utf8)
        out.append(Data(response.utf8))
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = send(client, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - Хаб агентов

final class AgentHub: ObservableObject {
    static let shared = AgentHub()
    static let port: UInt16 = 47321
    static let petChoices = ["🦊", "🐱", "🐶", "🦉", "🐙", "🐼", "🐧", "🐸", "🐨", "🐺",
                             "🦄", "🐹", "🐥", "🦖", "🐲", "🦦",
                             "🤖", "👾", "🧑‍💻", "👩‍🚀", "🧙", "🦸"]

    static let families: [AgentFamily] = [
        AgentFamily(id: "harness", title: "DeepSeek Harness", emoji: "🐧",
                    keys: ["deepseek harness", "dsh"], bundleKeys: ["harness"]),
        AgentFamily(id: "claude", title: "Claude", emoji: "🦊",
                    keys: ["claude"], bundleKeys: ["anthropic.claude", "claude"]),
        AgentFamily(id: "opencode", title: "OpenCode", emoji: "🦀",
                    keys: ["opencode"], bundleKeys: ["opencode"]),
        AgentFamily(id: "koda", title: "Koda Code", emoji: "🦫",
                    keys: ["koda"], bundleKeys: ["kodacode"]),
        AgentFamily(id: "chatgpt", title: "ChatGPT", emoji: "🐱",
                    keys: ["chatgpt", "openai"], bundleKeys: ["openai.chat"]),
        AgentFamily(id: "codex", title: "Codex", emoji: "🐱",
                    keys: ["codex"], bundleKeys: ["openai.codex"]),
        AgentFamily(id: "cursor", title: "Cursor", emoji: "🐙",
                    keys: ["cursor"], bundleKeys: ["cursor"]),
        AgentFamily(id: "gemini", title: "Gemini", emoji: "🦉",
                    keys: ["gemini"], bundleKeys: ["google.gemini"]),
        AgentFamily(id: "copilot", title: "Copilot", emoji: "🐼",
                    keys: ["copilot"], bundleKeys: ["github.copilot"]),
        AgentFamily(id: "grok", title: "Grok", emoji: "🐺",
                    keys: ["grok"], bundleKeys: ["xai.grok", "grok"]),
        AgentFamily(id: "deepseek", title: "DeepSeek", emoji: "🐋",
                    keys: ["deepseek"], bundleKeys: ["deepseek"]),
        AgentFamily(id: "kimi", title: "Kimi", emoji: "🐨",
                    keys: ["kimi", "moonshot"], bundleKeys: ["moonshot"]),
        AgentFamily(id: "manus", title: "Manus", emoji: "🐸",
                    keys: ["manus"], bundleKeys: ["manus"]),
        AgentFamily(id: "perplexity", title: "Perplexity", emoji: "🐝",
                    keys: ["perplexity"], bundleKeys: ["perplexity"]),
        AgentFamily(id: "windsurf", title: "Windsurf", emoji: "🏄",
                    keys: ["windsurf", "codeium"], bundleKeys: ["windsurf", "codeium"]),
        AgentFamily(id: "warp", title: "Warp", emoji: "🌊",
                    keys: ["warp"], bundleKeys: ["warp"]),
        AgentFamily(id: "raycast", title: "Raycast", emoji: "🚀",
                    keys: ["raycast"], bundleKeys: ["raycast"]),
        AgentFamily(id: "poe", title: "Poe", emoji: "🧠",
                    keys: ["poe"], bundleKeys: ["poe"]),
        AgentFamily(id: "mistral", title: "Mistral", emoji: "🌬",
                    keys: ["mistral"], bundleKeys: ["mistral"]),
        AgentFamily(id: "qwen", title: "Qwen", emoji: "🐫",
                    keys: ["qwen"], bundleKeys: ["qwen"]),
        AgentFamily(id: "ollama", title: "Ollama", emoji: "🦙",
                    keys: ["ollama"], bundleKeys: ["ollama"]),
        AgentFamily(id: "lmstudio", title: "LM Studio", emoji: "🎛",
                    keys: ["lm studio", "lmstudio"], bundleKeys: ["lmstudio"])
    ]
    @Published var events: [AgentEvent] = []
    @Published var status: [String: AlertKind] = [:]
    @Published var running: Set<String> = []
    @Published var limits: [String: LimitInfo] = [:] { didSet { Disk.save(limits, "limits.json") } }
    @Published var agents: [String] = []
    @Published var claudeTokens = 0
    @Published var serverOK = false
    @Published var scanning = false
    @Published var pets: [String: String] = (UserDefaults.standard.dictionary(forKey: "pets") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(pets, forKey: "pets") }
    }

    private let server = AgentHTTPServer()
    private var scanTimer: Timer?
    private var runningTimer: Timer?

    private init() {
        agents = Self.detectAgents()
        let custom = UserDefaults.standard.stringArray(forKey: "customAgents") ?? []
        for c in custom where !agents.contains(c) { agents.append(c) }
        limits = Disk.load("limits.json", as: [String: LimitInfo].self) ?? [:]
        server.onJSON = { [weak self] obj in self?.process(obj) }
        server.onReady = { [weak self] ok in self?.serverOK = ok }
        server.onGetState = { [weak self] in
            guard let self else { return nil }
            return DispatchQueue.main.sync {
                ["ok": true,
                 "port": Int(Self.port),
                 "expanded": NotchState.shared.expanded,
                 "tab": NotchState.shared.tab.rawValue,
                 "agents": self.agents,
                 "limits": self.limits.mapValues { $0.remaining },
                 "alert": NotchState.shared.alert?.text ?? "",
                 "running": Array(self.running).sorted(),
                 "music": ["title": MusicService.shared.title,
                           "app": MusicService.shared.app,
                           "playing": MusicService.shared.playing,
                           "system": MusicService.shared.system,
                           "browser": MusicService.shared.browser,
                           "debug": MusicService.shared.debug,
                           "clipDebug": ClipboardStore.shared.debug,
                           "yandexDebug": MusicService.shared.yandexDebug,
                           "clips": ClipboardStore.shared.items.count],
                 "events": self.events.count]
            }
        }
        server.onOpen = { tab in
            DispatchQueue.main.async {
                if let t = Tab(rawValue: tab) { SectionWindows.shared.open(t) }
            }
        }
        server.onSnapshot = { tab in
            guard let t = Tab(rawValue: tab) else { return false }
            return Self.snapshot(t)
        }
    }

    // MARK: Поиск установленных ИИ

    static func family(matching name: String, bundle: String) -> AgentFamily? {
        let n = name.lowercased()
        let b = bundle.lowercased()
        return families.first { fam in
            fam.keys.contains { !$0.isEmpty && n.contains($0) } ||
            fam.bundleKeys.contains { !$0.isEmpty && b.contains($0) }
        }
    }

    /// Какие из найденных агентов сейчас запущены — чтобы питомец не «спал», когда приложение открыто.
    func refreshRunning() {
        var ids = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let fam = Self.family(matching: app.localizedName ?? "",
                                     bundle: app.bundleIdentifier ?? "") {
                ids.insert(fam.id)
            }
        }
        if ids != running { running = ids }
    }

    func statusText(for agent: String) -> String {
        if let kind = status[agent] { return kindLabel(kind) }
        return running.contains(agent) ? "онлайн" : "отдыхает"
    }

    func statusColor(for agent: String) -> Color {
        if let kind = status[agent] { return kindColor(kind) }
        return running.contains(agent) ? Theme.green : Theme.faint
    }

    static func detectAgents() -> [String] {
        var found = Set<String>()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Одно приложение — один питомец: берём самое конкретное совпадение
        func consider(name: String, bundle: String) {
            if let fam = family(matching: name, bundle: bundle) {
                found.insert(fam.id)
            }
        }

        let dirs = ["/Applications", home.appendingPathComponent("Applications").path]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let plistPath = dir + "/" + item + "/Contents/Info.plist"
                let bundle = (NSDictionary(contentsOfFile: plistPath)?["CFBundleIdentifier"] as? String) ?? ""
                consider(name: item, bundle: bundle)
            }
        }

        // CLI-агенты и их папки настроек
        let markers: [(String, String)] = [
            (".claude", "claude"), (".codex", "codex"), (".gemini", "gemini"),
            (".cursor", "cursor"), (".copilot", "copilot"), (".kimi", "kimi"),
            (".deepseek", "deepseek"), (".manus", "manus"), (".opencode", "opencode"),
            (".koda", "koda")
        ]
        for (marker, id) in markers where fm.fileExists(atPath: home.appendingPathComponent(marker).path) {
            found.insert(id)
        }

        // Запущенные приложения (могли поставить в другом месте)
        for app in NSWorkspace.shared.runningApplications {
            consider(name: app.localizedName ?? "", bundle: app.bundleIdentifier ?? "")
        }

        if found.isEmpty { found.insert("claude") }
        let order = families.map { $0.id }
        return found.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }

    static func family(for agent: String) -> AgentFamily? {
        let s = agent.lowercased()
        return families.first { fam in fam.keys.contains { s.contains($0) } || fam.id == s }
    }

    func displayName(for agent: String) -> String {
        if agent == "codex" { return "Codex" }
        return Self.family(for: agent)?.title ?? agent.prefix(1).uppercased() + agent.dropFirst()
    }

    func pet(for agent: String) -> String {
        if let p = pets[agent] { return p }
        return Self.family(for: agent)?.emoji ?? "🤖"
    }

    func add(_ agent: String) {
        let id = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, !agents.contains(id) else { return }
        agents.append(id)
        var custom = UserDefaults.standard.stringArray(forKey: "customAgents") ?? []
        if !custom.contains(id) {
            custom.append(id)
            UserDefaults.standard.set(custom, forKey: "customAgents")
        }
    }

    func remove(_ agent: String) {
        agents.removeAll { $0 == agent }
        status[agent] = nil
        var custom = UserDefaults.standard.stringArray(forKey: "customAgents") ?? []
        custom.removeAll { $0 == agent }
        UserDefaults.standard.set(custom, forKey: "customAgents")
    }

    /// Рендер раздела в PNG (диагностика вёрстки без разрешения на запись экрана).
    static func snapshot(_ tab: Tab) -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { snapshotMain(tab) }
    }

    @MainActor
    private static func snapshotMain(_ tab: Tab) -> Bool {
        if #available(macOS 13.0, *) {
            let view = SectionBody(tab: tab)
                .frame(width: NotchLayout.expandedWidth - 20 - 84 - 12, height: tab.panelHeight - 95)
                .padding(10)
                .background(Color(white: 0.02))
                .environment(\.colorScheme, .dark)
                .environment(\.compactNotch, true)
                .buttonStyle(GlassButtonStyle())
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let img = renderer.nsImage,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return false }
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-\(tab.rawValue).png")
            try? png.write(to: url)
            return true
        }
        return false
    }

    // MARK: Сервер

    func start() {
        server.start(port: Self.port)
        refreshRunning()
        runningTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshRunning()
        }
        scanClaude()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.scanClaude()
        }
    }

    private func process(_ obj: [String: Any]) {
        let agent = ((obj["agent"] as? String) ?? (obj["source"] as? String) ?? "ai").lowercased()
        if !agents.contains(agent) { agents.append(agent) }

        if let n = obj["remaining"] as? NSNumber {
            setLimit(agent, remaining: n.doubleValue, label: (obj["label"] as? String) ?? "")
        }
        if let p = obj["pet"] as? String, !p.isEmpty { pets[agent] = p }
        if let ev = obj["event"] as? String {
            push(agent: agent, kind: kind(from: ev), message: (obj["message"] as? String) ?? "")
        }
    }

    private func kind(from s: String) -> AlertKind {
        switch s.lowercased() {
        case "done", "stop", "finished", "complete", "completed": return .done
        case "permission", "ask", "notification", "input", "waiting": return .permission
        case "error", "fail", "failed", "crash": return .error
        default: return .info
        }
    }

    func push(agent: String, kind: AlertKind, message: String) {
        let id = agent.lowercased()
        if !agents.contains(id) { agents.append(id) }
        events.insert(AgentEvent(agent: id, kind: kind, message: message), at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
        status[id] = kind

        let title = displayName(for: id)
        let text = message.isEmpty ? kindLabel(kind) : "\(kindLabel(kind)) — \(message)"
        NotchState.shared.showAlert(AlertItem(emoji: pet(for: id), title: title, text: text, kind: kind))
        if kind == .permission || kind == .error { NSSound(named: "Glass")?.play() }
    }

    func setLimit(_ agent: String, remaining: Double, label: String) {
        let id = agent.lowercased()
        if !agents.contains(id) { agents.append(id) }
        limits[id] = LimitInfo(remaining: max(0, min(100, remaining)), label: label)
    }

    func askAgent() {
        let alert = NSAlert()
        alert.messageText = "Добавить агента"
        alert.informativeText = "Имя, которое агент присылает в /event (например, aider)"
        alert.addButton(withTitle: "Добавить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "aider"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            add(field.stringValue)
        }
    }

    func askLimit(for agent: String) {
        let alert = NSAlert()
        alert.messageText = "Лимит \(displayName(for: agent))"
        alert.informativeText = "Сколько процентов осталось? Агент может присылать это сам через /event."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.stringValue = String(Int(limits[agent]?.remaining ?? 100))
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn, let v = Double(field.stringValue) {
            setLimit(agent, remaining: v, label: "вручную")
        }
    }

    // MARK: Лимит Claude Code: приблизительный подсчёт по локальным логам

    func scanClaude() {
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let cutoff = Date().addingTimeInterval(-5 * 3600)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoShort = ISO8601DateFormatter()
            var total = 0
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let url as URL in en where url.pathExtension == "jsonl" {
                    let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    if mod < cutoff { continue }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                        else { continue }
                        if let ts = obj["timestamp"] as? String {
                            let d = iso.date(from: ts) ?? isoShort.date(from: ts)
                            if let d, d < cutoff { continue }
                        }
                        if let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                            total += ((u["input_tokens"] as? Int) ?? 0) + ((u["output_tokens"] as? Int) ?? 0)
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.claudeTokens = total
                self.scanning = false
            }
        }
    }
}

// MARK: - Подписи и цвета статусов

func kindLabel(_ kind: AlertKind?) -> String {
    guard let kind else { return "отдыхает" }
    switch kind {
    case .done: return "Готово"
    case .permission: return "Нужно разрешение"
    case .error: return "Сбой"
    case .info: return "Сообщение"
    }
}

func kindColor(_ kind: AlertKind?) -> Color {
    guard let kind else { return Theme.faint }
    switch kind {
    case .done: return Theme.green
    case .permission: return Theme.orange
    case .error: return Theme.red
    case .info: return Theme.accentSoft
    }
}

// MARK: - Вид

struct AgentChip: View {
    let agent: String
    @ObservedObject var hub = AgentHub.shared

    var body: some View {
        Text(hub.pet(for: agent))
            .font(.system(size: 17))
            .frame(width: 33, height: 27)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hub.statusColor(for: agent).opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hub.statusColor(for: agent).opacity(0.35), lineWidth: 0.8))
            .help("\(hub.displayName(for: agent)): \(hub.statusText(for: agent))")
            .onTapGesture { NotchState.shared.tab = .pets }
    }
}

struct AgentTile: View {
    let agent: String
    var compact: Bool = false
    var onTap: (() -> Void)? = nil
    @ObservedObject var hub = AgentHub.shared
    @State private var hover = false

    private var color: Color { hub.statusColor(for: agent) }

    var body: some View {
        VStack(spacing: compact ? 1 : 3) {
            Text(hub.pet(for: agent))
                .font(.system(size: compact ? 16 : 25))
                .frame(width: compact ? 22 : 44, height: compact ? 22 : 44)
                .background(Circle().fill(color.opacity(0.13)))
                .overlay(Circle().strokeBorder(color.opacity(0.30), lineWidth: 0.8))
            Text(hub.displayName(for: agent))
                .font(.system(size: compact ? 7.5 : 9.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(compact ? 2 : 1)
                .multilineTextAlignment(.center)
            if compact {
                Text(hub.statusText(for: agent))
                    .font(.system(size: 6.5))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let l = hub.limits[agent] {
                    MiniBar(value: l.remaining / 100)
                        .frame(width: 40)
                    Text(String(Int(l.remaining)) + "%")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(l.remaining < 20 ? Theme.red : Theme.green)
                } else {
                    Text("лимит —")
                        .font(.system(size: 6.5))
                        .foregroundStyle(Theme.faint)
                }
            } else {
                Text(hub.statusText(for: agent))
                    .font(.system(size: 8.5))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let l = hub.limits[agent] {
                    MiniBar(value: l.remaining / 100)
                        .frame(width: 52)
                    Text("\(Int(l.remaining))%")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(l.remaining < 20 ? Theme.red : Theme.green)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 2 : 7)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(hover ? Theme.cardHover : Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 0.8))
        .onHover { hover = $0 }
        .onTapGesture { if compact { onTap?() } }
        .help(compact ? "Нажми, чтобы задать лимит" : hub.displayName(for: agent))
        .contextMenu {
            Menu("Питомец") {
                ForEach(AgentHub.petChoices, id: \.self) { p in
                    Button(p) { hub.pets[agent] = p }
                }
            }
            Button("Задать лимит вручную…") { hub.askLimit(for: agent) }
            Button("Уведомить: готово") { hub.push(agent: agent, kind: .done, message: "готово") }
            Divider()
            Button("Убрать из списка") { hub.remove(agent) }
        }
    }
}

struct PetsView: View {
    @ObservedObject var hub = AgentHub.shared
    @AppStorage("claudeCap") private var cap = 0
    @State private var newAgent = ""
    @State private var editingAgent: String?
    @State private var editValue: Double = 50

    @Environment(\.compactNotch) private var compact

    var body: some View {
        if compact {
            compactLayout
        } else {
            HStack(alignment: .top, spacing: 10) {
                leftColumn
                limitsColumn
                    .frame(width: 218)
            }
        }
    }

    // MARK: Компактный вид для чёлки

    private var compactLayout: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                ServerDot(ok: hub.serverOK)
                Text(hub.serverOK ? "Приём событий · порт " + String(AgentHub.port)
                     : "Сервер не запустился")
                    .font(.system(size: 9.5))
                    .foregroundStyle(hub.serverOK ? Theme.dim : Theme.red)
                Spacer()
                Button("Тест") {
                    hub.push(agent: "claude", kind: .done, message: "тестовое уведомление")
                }
                .controlSize(.mini)
                Button {
                    hub.askAgent()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Добавить своего агента")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5),
                      spacing: 4) {
                ForEach(hub.agents, id: \.self) { a in
                    AgentTile(agent: a, compact: true) {
                        editingAgent = a
                        editValue = hub.limits[a]?.remaining ?? 50
                    }
                }
            }

            if let editing = editingAgent {
                limitEditor(for: editing)
            } else {
                compactFooter
            }
        }
    }

    private var compactLimits: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ЛИМИТЫ ИИ")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
            let withData = hub.agents.filter { hub.limits[$0] != nil }
            if withData.isEmpty {
                Text("Нет данных: агент присылает процент сам")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
            } else {
                ForEach(withData.prefix(3), id: \.self) { a in
                    limitRow(a)
                }
            }
            Divider().overlay(Theme.stroke)
            HStack(spacing: 4) {
                Text("Claude Code · 5 ч")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Button(hub.scanning ? "…" : "Скан") { hub.scanClaude() }
                    .controlSize(.mini)
            }
            Text(cap > 0 ? "≈ " + String(max(0, cap - hub.claudeTokens)) + " из " + String(cap) + " токенов"
                 : "≈ " + String(hub.claudeTokens) + " токенов")
                .font(.system(size: 9))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 0.8))
    }

    private func limitEditor(for agent: String) -> some View {
        HStack(spacing: 6) {
            Text(hub.pet(for: agent))
            Text(hub.displayName(for: agent))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Slider(value: $editValue, in: 0...100)
                .frame(width: 150)
                .controlSize(.mini)
            Text(String(Int(editValue)) + "%")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(editValue < 20 ? Theme.red : Theme.green)
                .monospacedDigit()
                .frame(width: 34)
            Button("OK") {
                hub.setLimit(agent, remaining: editValue, label: "вручную")
                editingAgent = nil
            }
            .controlSize(.mini)
            Button {
                editingAgent = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardFill))
    }

    private var compactFooter: some View {
        HStack(spacing: 5) {
            if let e = hub.events.first {
                Text(hub.pet(for: e.agent)).font(.system(size: 9))
                Text(e.message.isEmpty ? kindLabel(e.kind) : e.message)
                    .font(.system(size: 8.5))
                    .foregroundStyle(kindColor(e.kind))
                    .lineLimit(1)
            } else {
                Text("Нажми на питомца — задать свой лимит")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
            Text("Claude ≈ " + String(hub.claudeTokens))
                .font(.system(size: 8))
                .foregroundStyle(Theme.faint)
            Button(hub.scanning ? "…" : "Скан") { hub.scanClaude() }
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardFill))
    }

    private var leftColumn: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ServerDot(ok: hub.serverOK)
                Text(hub.serverOK ? "Приём событий · порт \(String(AgentHub.port))" : "Сервер не запустился")
                    .font(.system(size: 10))
                    .foregroundStyle(hub.serverOK ? Theme.dim : Theme.red)
                Spacer()
                Button("Проверить питомца") {
                    hub.push(agent: "claude", kind: .done, message: "тестовое уведомление")
                }
                .controlSize(.mini)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 7)], spacing: 7) {
                    ForEach(hub.agents, id: \.self) { a in
                        AgentTile(agent: a)
                    }
                }
                .padding(.vertical, 1)
            }

            HStack(spacing: 6) {
                TextField("Свой агент, например aider", text: $newAgent)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07)))
                    .onSubmit { addAgent() }
                Button("Добавить") { addAgent() }
                    .controlSize(.mini)
            }

            eventsLog
        }
    }

    private var eventsLog: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("СОБЫТИЯ")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text("curl -X POST 127.0.0.1:\(String(AgentHub.port))/event -d '{...}'")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if hub.events.isEmpty {
                        Text("Пока тихо. Агент пришлёт событие — здесь появится запись, а из чёлки выглянет питомец.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(2)
                    }
                    ForEach(hub.events.prefix(12)) { e in
                        HStack(spacing: 5) {
                            Text(hub.pet(for: e.agent)).font(.system(size: 11))
                            Text(hub.displayName(for: e.agent))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.dim)
                            Text(e.message.isEmpty ? kindLabel(e.kind) : e.message)
                                .font(.system(size: 9.5))
                                .foregroundStyle(kindColor(e.kind))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(e.date.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 8.5))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                }
            }
            .frame(maxHeight: 78)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill))
    }

    private var limitsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ЛИМИТЫ ИИ")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.dim)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(hub.agents, id: \.self) { a in
                        limitRow(a)
                    }
                }
            }

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Claude Code · 5 ч")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Button(hub.scanning ? "…" : "Скан") { hub.scanClaude() }
                        .controlSize(.mini)
                }
                if cap > 0 {
                    MiniBar(value: Double(max(0, cap - hub.claudeTokens)) / Double(cap))
                    Text("≈ \(max(0, cap - hub.claudeTokens)) из \(cap) токенов")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                } else {
                    Text("≈ \(hub.claudeTokens) токенов за 5 ч")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }
                HStack(spacing: 4) {
                    Text("Лимит:")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                    TextField("0", value: $cap, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                        .frame(width: 66)
                    Text("токенов")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.cardFill))

            Text("Агент сам присылает процент: POST /event {\"agent\":\"codex\",\"remaining\":64}")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.faint)
                .lineLimit(3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func limitRow(_ a: String) -> some View {
        let info = hub.limits[a]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(hub.pet(for: a)).font(.system(size: 11))
                Text(hub.displayName(for: a))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer()
                Button {
                    hub.askLimit(for: a)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Задать лимит вручную")
            }
            if let info {
                MiniBar(value: info.remaining / 100)
                HStack {
                    Text(info.label.isEmpty ? "осталось" : info.label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(info.remaining))%")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(info.remaining < 20 ? Theme.red : Theme.green)
                }
            } else {
                Text("нет данных")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private func addAgent() {
        hub.add(newAgent)
        newAgent = ""
    }
}
