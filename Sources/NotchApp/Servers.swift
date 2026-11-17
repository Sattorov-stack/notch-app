import SwiftUI
import AppKit

// MARK: - Серверы pm2 (по ssh)

struct ServerConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var target: String      // user@host или имя Host из ~/.ssh/config
    var port: Int = 22
}

struct PM2Proc: Identifiable {
    let id: Int
    let name: String
    let status: String
    let cpu: Double
    let memMB: Double
    let uptime: Date?
    let restarts: Int
    var kind = "pm2"          // pm2 | service | docker

    /// Работает ли: pm2 «online», служба «active», контейнер «running»
    var ok: Bool { status == "online" || status == "active" || status == "running" }
}

struct ServerStatus {
    var procs: [PM2Proc] = []
    var error: String?
    var updated = Date()
    var meta = ServerMeta()
}

/// Сводка по серверу: память, swap, диск, нагрузка, время работы
struct ServerSample: Codable {
    let t: Date
    let ram: Int
    let cpu: Int
}

/// Маленькая кнопка-«таблетка»: в одну строку, без переносов
struct ChipButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .contentShape(Capsule())
    }
}

struct SiteCheck {
    let code: Int
    let time: Double
    let up: Bool
}

struct ServerMeta {
    var memTotal: Double = 0, memUsed: Double = 0
    var swapTotal: Double = 0, swapUsed: Double = 0
    var diskTotal: Double = 0, diskUsed: Double = 0
    var load1: Double = 0
    var cores = 0
    var uptime = 0
    var reboot = false
    var os = ""
    var updates = -1
    var cpuReal = -1          // настоящая загрузка процессора, %
    var topProc = ""          // кто грузит больше всего
    /// Загрузка процессора: настоящая, а если её нет — по средней нагрузке
    var cpuPct: Int { cpuReal >= 0 ? cpuReal : loadPct }
    var banned = -1
    var sshFail = -1
    var certs: [(name: String, until: Date)] = []
    var domains: [String] = []

    var hasData: Bool { memTotal > 0 }
    var memPct: Int { memTotal > 0 ? Int(memUsed / memTotal * 100) : 0 }
    var swapPct: Int { swapTotal > 0 ? Int(swapUsed / swapTotal * 100) : 0 }
    var diskPct: Int { diskTotal > 0 ? Int(diskUsed / diskTotal * 100) : 0 }
    var loadPct: Int { cores > 0 ? Int(load1 / Double(cores) * 100) : 0 }

    var dict: [String: Any] {
        ["ram": memPct, "swap": swapPct, "disk": diskPct, "load": load1, "cores": cores,
         "uptimeHours": uptime / 3600, "reboot": reboot, "os": os,
         "updates": updates, "cpu": cpuPct, "topProc": topProc, "banned": banned, "sshFail": sshFail, "domains": domains,
         "certs": certs.map { "\($0.name): \(Int($0.until.timeIntervalSinceNow / 86400)) дн" }]
    }
}

/// Раз в минуту читает `pm2 jlist` на каждом сервере. Если процесс упал или
/// сервер пропал — питомец выглядывает из чёлки.
final class ServersService: ObservableObject {
    static let shared = ServersService()
    @Published var servers: [ServerConfig] = Disk.load("servers.json", as: [ServerConfig].self) ?? []
    @Published var status: [UUID: ServerStatus] = [:]
    @Published var loading: Set<UUID> = []

    private var lastStates: [String: String] = [:]
    private var unreachable: Set<UUID> = []
    private var everReachable: Set<UUID> = []
    private var failCount: [UUID: Int] = [:]
    private var cpuHigh: [UUID: Int] = [:]
    private var restartHistory: [String: [(Date, Int)]] = [:]
    @Published var history: [String: [ServerSample]] =
        Disk.load("server-history.json", as: [String: [ServerSample]].self) ?? [:]
    private var lastHistorySave = Date.distantPast

    /// Запоминаем память и процессор раз в минуту — для графика за сутки
    private func record(_ s: ServerConfig, _ m: ServerMeta) {
        var h = history[s.id.uuidString] ?? []
        h.append(ServerSample(t: Date(), ram: m.memPct, cpu: min(100, m.cpuPct)))
        let cutoff = Date().addingTimeInterval(-86400)
        h.removeAll { $0.t < cutoff }
        history[s.id.uuidString] = h
        if Date().timeIntervalSince(lastHistorySave) > 600 {
            lastHistorySave = Date()
            Disk.save(history, "server-history.json")
        }
    }

    /// Выполнить команду на сервере и вернуть вывод (обновление пакетов, очистка логов, перезагрузка)
    func run(_ s: ServerConfig, _ cmd: String, timeout: Double, _ done: @escaping (String) -> Void) {
        Self.ssh(s, cmd, timeout: timeout) { out, err in
            let text = out ?? err ?? ""
            done(text.isEmpty ? "Готово" : text)
        }
    }

    /// Открыть Терминал сразу на сервере
    func openTerminal(_ s: ServerConfig) {
        let safeName = s.name.filter { $0.isLetter || $0.isNumber }
        let url = Disk.dir.appendingPathComponent("ssh-\(safeName.isEmpty ? "server" : safeName).command")
        var cmd = "#!/bin/bash\nexec ssh -o UseKeychain=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=8"
        if s.port != 22 { cmd += " -p \(s.port)" }
        cmd += " '\(s.target.replacingOccurrences(of: "'", with: ""))'\n"
        try? cmd.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static let updateCmd = "export DEBIAN_FRONTEND=noninteractive; apt-get update -q >/dev/null 2>&1; apt-get -y -q -o Dpkg::Options::=--force-confold upgrade 2>&1 | tail -15; [ -f /var/run/reboot-required ] && echo '⚠︎ После обновления нужна перезагрузка'"
    private var timer: Timer?

    /// pm2 часто стоит через nvm — подгружаем его, если не найден в PATH
    private static let pm2Prefix = "command -v pm2 >/dev/null 2>&1 || . ~/.nvm/nvm.sh >/dev/null 2>&1; "

    func start() {
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshAll() }
        siteTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.checkSites() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkSites() }
    }

    // MARK: Сайты: открываются ли и как быстро (проверка с этого Mac раз в 5 минут)

    @Published var sites: [String: SiteCheck] = [:]
    private var siteTimer: Timer?
    private var sitesDown: Set<String> = []
    private var sitesEverUp: Set<String> = []

    func checkSites() {
        let domains = Set(status.values.flatMap { $0.meta.domains })
        for d in domains {
            guard let url = URL(string: "https://\(d)") else { continue }
            var r = URLRequest(url: url, timeoutInterval: 10)
            r.httpMethod = "HEAD"
            let t0 = Date()
            URLSession.shared.dataTask(with: r) { [weak self] _, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let dt = Date().timeIntervalSince(t0)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let up = code > 0 && code < 500
                    self.sites[d] = SiteCheck(code: code, time: dt, up: up)
                    if up {
                        self.sitesEverUp.insert(d)
                        if self.sitesDown.remove(d) != nil {
                            NotchState.shared.showAlert(AlertItem(emoji: "🌐", title: d, text: "сайт снова работает", kind: .done, channel: .servers))
                        }
                    } else if !self.sitesDown.contains(d) {
                        self.sitesDown.insert(d)
                        if self.sitesEverUp.contains(d) {
                            NotchState.shared.showAlert(AlertItem(emoji: "🌐", title: d,
                                text: code == 0 ? "сайт не отвечает" : "сайт отвечает ошибкой \(code)", kind: .error, channel: .servers))
                        }
                    }
                }
            }.resume()
        }
    }

    // MARK: Логи

    func logs(_ s: ServerConfig, _ p: PM2Proc, _ done: @escaping (String) -> Void) {
        let safe = !p.name.isEmpty && p.name.allSatisfy { $0.isLetter || $0.isNumber || "@._-".contains($0) }
        let cmd: String
        switch p.kind {
        case "service":
            guard safe else { done("Недопустимое имя службы"); return }
            cmd = "journalctl -u \(p.name).service -n 80 --no-pager -o short-iso 2>&1"
        case "docker":
            guard safe else { done("Недопустимое имя контейнера"); return }
            cmd = "docker logs --tail 80 \(p.name) 2>&1"
        default:
            cmd = "bash -lc '" + Self.pm2Prefix + "pm2 logs \(p.id) --lines 80 --nostream --raw 2>&1'"
        }
        Self.ssh(s, cmd) { out, err in
            let text = out ?? err ?? ""
            done(text.isEmpty ? "Логов нет" : text)
        }
    }

    func add(name: String, target: String, port: Int) {
        let s = ServerConfig(name: name.isEmpty ? target : name, target: target, port: port)
        servers.append(s)
        save()
        refresh(s)
    }

    func remove(_ s: ServerConfig) {
        servers.removeAll { $0.id == s.id }
        status[s.id] = nil
        save()
    }

    private func save() { Disk.save(servers, "servers.json") }

    func refreshAll() { servers.forEach { refresh($0) } }

    /// Одним заходом: процессы pm2, свои службы systemd (из /etc/systemd/system и
    /// важные пакеты вроде nginx) и контейнеры Docker.
    private static let probeScript = """
    exec 9>/tmp/.notch_probe.lock
    flock -n 9 || exit 0
    renice -n 10 $$ >/dev/null 2>&1
    command -v pm2 >/dev/null 2>&1 || . ~/.nvm/nvm.sh >/dev/null 2>&1
    echo "@@PM2"
    command -v pm2 >/dev/null 2>&1 && pm2 jlist 2>/dev/null; echo
    echo "@@SYSTEMD"
    systemctl show '*.service' -p Id -p ActiveState -p FragmentPath -p MemoryCurrent -p UnitFileState -p NRestarts --no-pager 2>/dev/null | awk -F= '/^Id=/{id=$2} /^ActiveState=/{st=$2} /^FragmentPath=/{fp=$2} /^MemoryCurrent=/{mem=$2} /^UnitFileState=/{uf=$2} /^NRestarts=/{nr=$2} /^$/{ if (id!="") print id"|"st"|"fp"|"mem"|"uf"|"nr; id=""; st=""; fp=""; mem=""; uf=""; nr="" } END{ if (id!="") print id"|"st"|"fp"|"mem"|"uf"|"nr }'
    echo "@@DOCKER"
    command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}|{{.State}}' 2>/dev/null
    echo "@@DSTATS"
    command -v docker >/dev/null 2>&1 && docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null
    echo "@@META"
    free -b | awk '/^Mem:/{print "mem|"$2"|"$7} /^Swap:/{print "swap|"$2"|"$3}'
    df -B1 / | awk 'NR==2{print "disk|"$2"|"$3}'
    echo "load|$(cut -d' ' -f1-3 /proc/loadavg)|$(nproc)"
    echo "uptime|$(cut -d. -f1 /proc/uptime)"
    [ -f /var/run/reboot-required ] && echo "reboot|1"
    echo "os|$(. /etc/os-release && echo "$PRETTY_NAME")"
    U=/tmp/.notch_updates
    if [ ! -s $U ] || [ $(( $(date +%s) - $(stat -c %Y $U) )) -gt 21600 ]; then
      if [ -x /usr/lib/update-notifier/apt-check ]; then timeout 60 nice -n 19 /usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f1 > $U
      else timeout 60 nice -n 19 apt list --upgradable 2>/dev/null | grep -c upgradable > $U; fi
    fi
    echo "updates|$(cat $U 2>/dev/null)"
    read -r _ a b c d e f g h _ < /proc/stat; sleep 1; read -r _ A B C D E F G H _ < /proc/stat
    echo "cpu|$(( ((A+B+C+F+G+H) - (a+b+c+f+g+h)) * 100 / ((A+B+C+D+E+F+G+H) - (a+b+c+d+e+f+g+h) + 1) ))"
    echo "topproc|$(ps -eo %cpu,comm --sort=-%cpu | sed -n 2p | awk '{print $2 " " $1 "%"}')"
    command -v fail2ban-client >/dev/null 2>&1 && echo "banned|$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/ /,"",$2); print $2}')"
    echo "sshfail|$(journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -cE 'Failed password|Invalid user')"
    for c in /etc/letsencrypt/live/*/cert.pem; do [ -f "$c" ] && echo "cert|$(basename "$(dirname "$c")")|$(date -d "$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)" +%s)"; done
    command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | awk '$1=="server_name"{for(i=2;i<=NF;i++){if($i ~ /^#/) break; gsub(/;/,"",$i); print "domain|"$i}}' | sort -u
    echo "@@END"
    """

    func refresh(_ s: ServerConfig) {
        guard !loading.contains(s.id) else { return }
        loading.insert(s.id)
        Self.ssh(s, "bash -l -s", input: Self.probeScript) { [weak self] out, err in
            guard let self else { return }
            self.loading.remove(s.id)
            var st = ServerStatus()
            if let out, out.contains("@@END") {
                self.failCount[s.id] = 0
                st.procs = Self.parseAll(out)
                st.meta = Self.parseMeta(out)
            } else {
                // Связь мигнула — показываем прежние данные и ждём; «нет связи» — после 3 неудач подряд
                let fails = (self.failCount[s.id] ?? 0) + 1
                self.failCount[s.id] = fails
                if fails < 3, let prev = self.status[s.id], prev.error == nil { return }
                st.error = err ?? "Сервер не ответил"
            }
            self.status[s.id] = st
            if st.meta.hasData { self.record(s, st.meta) }
            self.notifyChanges(s, st)
        }
    }

    /// Перезапуск: pm2 — по номеру, служба и контейнер — по имени (только безопасные символы).
    func restart(_ s: ServerConfig, _ p: PM2Proc) {
        let safe = !p.name.isEmpty && p.name.allSatisfy { $0.isLetter || $0.isNumber || "@._-".contains($0) }
        let cmd: String
        switch p.kind {
        case "service":
            guard safe else { return }
            cmd = "systemctl restart \(p.name).service"
        case "docker":
            guard safe else { return }
            cmd = "docker restart \(p.name)"
        default:
            cmd = "bash -lc '" + Self.pm2Prefix + "pm2 restart \(p.id)'"
        }
        loading.insert(s.id)
        Self.ssh(s, cmd) { [weak self] _, err in
            guard let self else { return }
            self.loading.remove(s.id)
            if let err { self.alert(s, "не удалось перезапустить \(p.name): \(err.prefix(60))", .error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh(s) }
        }
    }

    private func notifyChanges(_ s: ServerConfig, _ st: ServerStatus) {
        if let err = st.error {
            // Предупреждаем, только если сервер раньше отвечал: при первой проверке не шумим
            if !unreachable.contains(s.id) {
                unreachable.insert(s.id)
                if everReachable.contains(s.id) { alert(s, "нет связи: \(err.prefix(70))", .error) }
            }
            return
        }
        everReachable.insert(s.id)
        // Память или диск почти заполнены — питомец предупредит один раз
        if st.meta.hasData {
            for (key, pct, what) in [("ram", st.meta.memPct, "память"), ("disk", st.meta.diskPct, "диск")] {
                let k = "\(s.id)/\(key)"
                let high = pct >= 90
                if high && lastStates[k] != "high" { alert(s, "\(what) заполнена на \(pct)%", .error) }
                lastStates[k] = high ? "high" : "ok"
            }
            if st.meta.cpuReal >= 90 {
                let n = (cpuHigh[s.id] ?? 0) + 1
                cpuHigh[s.id] = n
                if n == 5 { alert(s, "процессор \(st.meta.cpuReal)% уже 5 мин — \(st.meta.topProc)", .error) }
            } else {
                cpuHigh[s.id] = 0
            }
            for c in st.meta.certs {
                let days = Int(c.until.timeIntervalSinceNow / 86400)
                let k = "\(s.id)/cert/\(c.name)"
                if days < 14 && lastStates[k] != "soon" { alert(s, "SSL \(c.name) истекает через \(days) дн", .error) }
                lastStates[k] = days < 14 ? "soon" : "ok"
            }
        }
        if unreachable.remove(s.id) != nil { alert(s, "снова на связи", .done) }
        for p in st.procs {
            let key = p.kind == "pm2" ? "\(s.id)/pm2/\(p.id)" : "\(s.id)/\(p.kind)/\(p.name)"
            let prev = lastStates[key]
            lastStates[key] = p.ok ? "ok" : p.status
            // Зацикленный перезапуск: больше 3 перезапусков за час
            var h = (restartHistory[key] ?? []).filter { Date().timeIntervalSince($0.0) < 3600 }
            h.append((Date(), p.restarts))
            restartHistory[key] = h
            let delta = (h.last?.1 ?? 0) - (h.first?.1 ?? 0)
            let loopKey = key + "/loop"
            if delta >= 3 && lastStates[loopKey] != "loop" {
                alert(s, "\(p.name) перезапускается по кругу: \(delta) раз за час", .error)
            }
            lastStates[loopKey] = delta >= 3 ? "loop" : "ok"
            if prev == "ok" && !p.ok {
                alert(s, "\(p.name) — \(Self.statusRu(p.status))", .error)
            } else if let prev, prev != "ok", p.ok {
                alert(s, "\(p.name) снова работает", .done)
            }
        }
    }

    private func alert(_ s: ServerConfig, _ text: String, _ kind: AlertKind) {
        NotchState.shared.showAlert(AlertItem(emoji: "🖥️", title: s.name, text: text, kind: kind, channel: .servers))
        if kind == .error { NSSound(named: "Basso")?.play() }
    }

    static func ssh(_ s: ServerConfig, _ command: String, input: String? = nil, timeout: Double = 45, _ done: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // UseKeychain: пароль-фраза ключа берётся из связки ключей macOS — чёлка
            // работает в фоне и спросить фразу не может
            // Одно постоянное соединение на сервер (ControlMaster) и «пинги» каждые 10 с:
            // на медленной и скачущей связи не нужно каждый раз подключаться заново
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "UseKeychain=yes",
                        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
                        "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cm-notch-%C",
                        "-o", "ControlPersist=10m",
                        "-o", "StrictHostKeyChecking=accept-new"]
            if s.port != 22 { args += ["-p", String(s.port)] }   // иначе порт берётся из ~/.ssh/config
            // Пробуем все твои ключи из ~/.ssh (например, id_ed25519_new), а не только стандартные
            let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) {
                for f in files.sorted() where f.hasPrefix("id_") && !f.hasSuffix(".pub") {
                    args += ["-i", sshDir.appendingPathComponent(f).path]
                }
            }
            args += [s.target, command]
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inPipe: Pipe? = input == nil ? nil : Pipe()
            if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }
            do { try p.run() } catch {
                DispatchQueue.main.async { done(nil, "ssh не запустился") }
                return
            }
            if let inPipe, let input {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let code = p.terminationStatus
            let os = String(decoding: o, as: UTF8.self)
            let es = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if code == 0 {
                    done(os, nil)
                } else {
                    let last = es.split(separator: "\n").last.map(String.init) ?? ""
                    done(nil, last.isEmpty ? "ssh: код \(code)" : last)
                }
            }
        }
    }

    /// pm2 печатает JSON одной строкой; до неё могут идти предупреждения — их пропускаем.
    static func parse(_ out: String) -> [PM2Proc]? {
        let line = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("[{") || $0 == "[]" }
        guard let line,
              let arr = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else { return nil }
        return arr.map { p in
            let env = p["pm2_env"] as? [String: Any] ?? [:]
            let mon = p["monit"] as? [String: Any] ?? [:]
            let up = (env["pm_uptime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return PM2Proc(id: (p["pm_id"] as? Int) ?? 0,
                           name: (p["name"] as? String) ?? "?",
                           status: (env["status"] as? String) ?? "?",
                           cpu: (mon["cpu"] as? Double) ?? 0,
                           memMB: ((mon["memory"] as? Double) ?? 0) / 1_048_576,
                           uptime: up,
                           restarts: (env["restart_time"] as? Int) ?? 0)
        }
    }

    /// Разбор ответа по секциям @@PM2, @@SYSTEMD, @@DOCKER, @@DSTATS, @@META.
    static func section(_ out: String, _ name: String) -> String {
        guard let a = out.range(of: "@@\(name)\n") else { return "" }
        let rest = out[a.upperBound...]
        if rest.hasPrefix("@@") { return "" }
        let end = rest.range(of: "\n@@")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func parseAll(_ out: String) -> [PM2Proc] {
        var items = parse(section(out, "PM2")) ?? []
        let known = ["nginx", "docker", "apache2", "caddy", "postgresql", "mysql", "mariadb", "redis-server", "mongod"]
        var n = 100_000
        for line in section(out, "SYSTEMD").split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            let name = f[0].replacingOccurrences(of: ".service", with: "")
            let custom = f[2].hasPrefix("/etc/systemd/system/") && !name.hasPrefix("pm2-")
            let important = known.contains(name) || (name.hasPrefix("php") && name.hasSuffix("-fpm"))
            guard custom || important else { continue }
            // Выключенные из автозапуска и остановленные службы не показываем
            if f.count > 4, f[4] == "disabled", f[1] == "inactive" { continue }
            let mem = f.count > 3 ? (Double(f[3]) ?? 0) / 1_048_576 : 0
            n += 1
            items.append(PM2Proc(id: n, name: name, status: f[1], cpu: -1, memMB: mem,
                                 uptime: nil, restarts: f.count > 5 ? (Int(f[5]) ?? 0) : 0, kind: "service"))
        }
        var stats: [String: (cpu: Double, mem: Double)] = [:]
        for line in section(out, "DSTATS").split(separator: "\n") {
            let f = line.split(separator: "|").map(String.init)
            guard f.count >= 3 else { continue }
            let cpu = Double(f[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
            let mem = bytes(f[2].components(separatedBy: "/").first ?? "") / 1_048_576
            stats[f[0]] = (cpu, mem)
        }
        var m = 200_000
        for line in section(out, "DOCKER").split(separator: "\n") {
            let f = line.split(separator: "|").map(String.init)
            guard f.count >= 2 else { continue }
            m += 1
            let st = stats[f[0]]
            items.append(PM2Proc(id: m, name: f[0], status: f[1], cpu: st?.cpu ?? -1, memMB: st?.mem ?? 0,
                                 uptime: nil, restarts: 0, kind: "docker"))
        }
        return items
    }

    static func parseMeta(_ out: String) -> ServerMeta {
        var m = ServerMeta()
        for line in section(out, "META").split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let key = f.first else { continue }
            func num(_ i: Int) -> Double {
                i < f.count ? Double(f[i].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
            }
            switch key {
            case "mem": m.memTotal = num(1); m.memUsed = max(0, num(1) - num(2))
            case "swap": m.swapTotal = num(1); m.swapUsed = num(2)
            case "disk": m.diskTotal = num(1); m.diskUsed = num(2)
            case "load":
                let parts = (f.count > 1 ? f[1] : "").split(separator: " ")
                m.load1 = parts.first.flatMap { Double($0) } ?? 0
                m.cores = Int(num(2))
            case "uptime": m.uptime = Int(num(1))
            case "reboot": m.reboot = true
            case "os": m.os = f.count > 1 ? f[1] : ""
            case "updates": m.updates = Int(num(1))
            case "cpu": m.cpuReal = min(100, max(0, Int(num(1))))
            case "topproc": m.topProc = f.count > 1 ? f[1] : ""
            case "banned": m.banned = Int(num(1))
            case "sshfail": m.sshFail = Int(num(1))
            case "cert":
                if f.count > 2, let t = Double(f[2]) {
                    m.certs.append((name: f[1], until: Date(timeIntervalSince1970: t)))
                }
            case "domain":
                let d = f.count > 1 ? f[1] : ""
                let isIP = d.allSatisfy { $0.isNumber || $0 == "." }
                // только настоящие домены: с точкой и из допустимых символов (без «# managed by Certbot»)
                let looksLikeDomain = d.contains(".") && d.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                guard looksLikeDomain else { continue }
                if !d.isEmpty, d != "_", d != "localhost", !d.contains("*"), !d.contains("$"),
                   !isIP, !m.domains.contains(d) {
                    m.domains.append(d)
                }
            default: break
            }
        }
        return m
    }

    /// «12.5MiB» → байты
    static func bytes(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
                                         ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, mult) in units where t.hasSuffix(u) {
            return (Double(t.dropLast(u.count)) ?? 0) * mult
        }
        return Double(t) ?? 0
    }

    static func statusRu(_ s: String) -> String {
        switch s {
        case "stopped", "inactive", "dead": return "остановлен"
        case "exited": return "выключен"
        case "errored", "failed": return "ошибка"
        case "activating", "restarting": return "перезапуск…"
        default: return s
        }
    }

    /// Хосты из ~/.ssh/config — чтобы добавить сервер одним нажатием.
    static func sshConfigHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("host ") else { continue }
            for h in t.dropFirst(5).split(separator: " ") where !h.contains("*") && !h.contains("?") {
                hosts.append(String(h))
            }
        }
        return hosts
    }
}

struct ServersView: View {
    @ObservedObject var svc = ServersService.shared
    @Environment(\.compactNotch) private var compact
    @State private var selected: UUID?
    @State private var adding = false
    @State private var name = ""
    @State private var target = ""
    @State private var port = "22"
    @State private var logTitle: String?
    @State private var logText = ""
    @State private var showTelegram = false
    @State private var armed: String?
    @ObservedObject var backups = BackupMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(svc.servers) { s in serverRow(s) }
                        if adding { addForm }
                    }
                }
                HStack(spacing: 6) {
                    Button(adding ? "Отмена" : "+ Сервер") { adding.toggle() }.buttonStyle(ChipButtonStyle())
                    Button { showTelegram.toggle() } label: { Image(systemName: "paperplane") }
                        .buttonStyle(ChipButtonStyle(tint: showTelegram ? Theme.green : Theme.text))
                        .help("Уведомления в Telegram")
                    Spacer(minLength: 0)
                    Button { svc.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(ChipButtonStyle())
                        .help("Обновить сейчас")
                }
            }
            .frame(width: compact ? 150 : 210)

            processPanel
        }
        .onAppear {
            if selected == nil { selected = svc.servers.first?.id }
            svc.refreshAll()
        }
    }

    private func serverRow(_ s: ServerConfig) -> some View {
        let st = svc.status[s.id]
        let online = st?.procs.filter { $0.ok }.count ?? 0
        let total = st?.procs.count ?? 0
        let color: Color = st == nil ? Theme.faint
            : (st?.error != nil ? Theme.red : (online == total ? Theme.green : Theme.orange))
        let ram = st.map { $0.meta.hasData ? " · ОЗУ \($0.meta.memPct)%" : "" } ?? ""
        let caption = st == nil ? "проверяю…" : (st?.error != nil ? "нет связи" : "\(online)/\(total) работают" + ram)
        return Button { selected = s.id; showTelegram = false } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(Theme.text)
                    Text(caption).font(.system(size: 9)).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
                if svc.loading.contains(s.id) { ProgressView().controlSize(.mini) }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected == s.id ? Color.white.opacity(0.12) : Color.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Удалить сервер") {
                svc.remove(s)
                if selected == s.id { selected = svc.servers.first?.id }
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Название", text: $name).textFieldStyle(.roundedBorder)
            TextField("root@1.2.3.4 или Host", text: $target).textFieldStyle(.roundedBorder)
            HStack(spacing: 4) {
                TextField("22", text: $port).textFieldStyle(.roundedBorder).frame(width: 46)
                Button("Добавить") {
                    svc.add(name: name, target: target.trimmingCharacters(in: .whitespaces),
                            port: Int(port) ?? 22)
                    selected = svc.servers.last?.id
                    name = ""; target = ""; adding = false
                }
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let hosts = ServersService.sshConfigHosts().filter { h in !svc.servers.contains { $0.target == h } }
            if !hosts.isEmpty {
                Text("Из ~/.ssh/config:").font(.system(size: 9)).foregroundStyle(Theme.dim)
                HStack(spacing: 4) {
                    ForEach(hosts.prefix(4), id: \.self) { h in
                        Button(h) {
                            svc.add(name: h, target: h, port: 22)
                            selected = svc.servers.last?.id
                            adding = false
                        }
                    }
                }
            }
        }
        .font(.system(size: 10.5))
        .controlSize(.small)
    }

    @ViewBuilder private var processPanel: some View {
        if showTelegram {
            ScrollView { TelegramSettingsView() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if let id = selected, let s = svc.servers.first(where: { $0.id == id }) {
            let st = svc.status[id]
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.target).font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer()
                    if let st {
                        Text("обновлено \(st.updated.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9)).foregroundStyle(Theme.faint)
                    }
                }
                if let title = logTitle {
                    HStack {
                        Text("Логи: \(title)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button("Закрыть") { logTitle = nil }.buttonStyle(ChipButtonStyle())
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(logText)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("logEnd")
                        }
                        .onChange(of: logText) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
                    }
                } else {
                    // Сводка, кнопки и процессы прокручиваются вместе — панель не растягивается
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let m = st?.meta, m.hasData { metrics(m, s) }
                            actionsRow(s)
                            if let err = st?.error {
                                Text(err).font(.system(size: 10)).foregroundStyle(Theme.red).lineLimit(3)
                                Text(err.contains("Permission denied")
                                     ? "Если ключ защищён паролем-фразой — один раз в Терминале: ssh-add --apple-use-keychain ~/.ssh/id_ed25519_new. Если сервер не знает ключ: ssh-copy-id -i ~/.ssh/id_ed25519_new.pub \(s.target)."
                                     : "Сервер не отвечает по ssh — проверь, что он включён и доступен.")
                                    .font(.system(size: 9)).foregroundStyle(Theme.dim)
                                    .textSelection(.enabled)
                            }
                            VStack(spacing: 3) {
                                ForEach((st?.procs ?? []).filter { !$0.ok } + (st?.procs ?? []).filter { $0.ok }) { p in procRow(s, p) }
                            }
                            Text("Правый клик по строке — логи и перезапуск")
                                .font(.system(size: 9)).foregroundStyle(Theme.faint)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Нажми «+ Сервер» и укажи адрес для ssh, например root@1.2.3.4, или выбери хост из ~/.ssh/config.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                Text("Раз в минуту чёлка читает pm2 и предупредит, если процесс упал или сервер недоступен.")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func metrics(_ m: ServerMeta, _ s: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                bar("ОЗУ", m.memPct, "\(Self.gb(m.memUsed)) из \(Self.gb(m.memTotal)) ГБ")
                bar("Диск", m.diskPct, "\(Self.gb(m.diskUsed)) из \(Self.gb(m.diskTotal)) ГБ")
                bar("Процессор", min(100, m.cpuPct),
                    m.topProc.isEmpty ? String(format: "нагрузка %.2f · ядер %d", m.load1, m.cores) : "больше всего: \(m.topProc)")
            }
            HStack(spacing: 8) {
                if m.swapTotal > 0 { Text("Swap \(m.swapPct)%") }
                Text("Работает \(Self.days(m.uptime))")
                if m.updates >= 0 { Text("Обновлений \(m.updates)") }
                if m.reboot { Text("⚠︎ нужна перезагрузка").foregroundStyle(Theme.orange) }
                Spacer(minLength: 0)
                Text(m.os).lineLimit(1).foregroundStyle(Theme.faint)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.dim)
            if m.banned >= 0 || m.sshFail >= 0 {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.green)
                    if m.sshFail >= 0 { Text("Попыток подобрать вход за сутки: \(m.sshFail)") }
                    if m.banned >= 0 { Text("· в бане fail2ban: \(m.banned)") }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.dim)
            }
            let hist = svc.history[s.id.uuidString] ?? []
            if hist.count > 2 {
                HStack(spacing: 10) {
                    Text("24 ч").foregroundStyle(Theme.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ОЗУ").foregroundStyle(Theme.dim)
                        Sparkline(values: Sparkline.thin(hist.map { $0.ram }), color: Theme.green).frame(height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Процессор").foregroundStyle(Theme.dim)
                        Sparkline(values: Sparkline.thin(hist.map { $0.cpu }), color: Theme.orange).frame(height: 16)
                    }
                }
                .font(.system(size: 9))
            }
            backupRow(s)
            if !m.domains.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(m.domains.prefix(4)), id: \.self) { d in siteChip(d, m) }
                }
                .font(.system(size: 9.5))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func backupRow(_ s: ServerConfig) -> some View {
        let e = backups.entry(for: s.target)
        let color: Color = e == nil ? Theme.faint : ((e?.ok ?? false) ? Theme.green : Theme.red)
        return HStack(spacing: 6) {
            Image(systemName: "externaldrive").foregroundStyle(color)
            if let e {
                Text(e.ok ? "Копия \(BackupMonitor.ago(e.time)), \(String(format: "%.1f", Double(e.size) / 1_048_576)) МБ"
                          : "Копия не удалась: \(e.error)")
                    .lineLimit(1)
                if e.ok { Button("Показать") { backups.reveal(e) }.buttonStyle(ChipButtonStyle()) }
            } else {
                Text("Резервной копии ещё нет — делается каждую ночь в 03:30").lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(backups.running ? "Копирую…" : "Копировать") { backups.runNow() }
                .buttonStyle(ChipButtonStyle())
                .disabled(backups.running)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Theme.dim)
        .controlSize(.mini)
    }

    /// Кнопки управления в два ряда — чтобы не вылезали за край панели
    private func actionsRow(_ s: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { svc.openTerminal(s) } label: { Label("Терминал", systemImage: "terminal") }
                    .buttonStyle(ChipButtonStyle())
                confirmButton("Обновить пакеты", key: "upd-\(s.id)") {
                    runAction(s, "Обновление пакетов", ServersService.updateCmd, 900)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                confirmButton("Почистить логи", key: "logs-\(s.id)") {
                    runAction(s, "Очистка логов", "journalctl --vacuum-size=200M 2>&1 | tail -2; echo; echo \"Логи теперь: $(du -sh /var/log | cut -f1)\"", 120)
                }
                confirmButton("Перезагрузить", key: "reboot-\(s.id)") {
                    runAction(s, "Перезагрузка", "nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 & echo 'Сервер перезагружается, вернётся через 1–2 минуты'", 20)
                }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 9.5))
        .controlSize(.mini)
    }

    /// Опасные действия — только после второго нажатия в течение 4 секунд
    private func confirmButton(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(armed == key ? "Точно? Нажми ещё раз" : title) {
            if armed == key {
                armed = nil
                action()
            } else {
                armed = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == key { armed = nil } }
            }
        }
        .buttonStyle(ChipButtonStyle(tint: armed == key ? Theme.orange : Theme.text))
    }

    private func runAction(_ s: ServerConfig, _ title: String, _ cmd: String, _ timeout: Double) {
        logTitle = "\(title) — \(s.name)"
        logText = "Выполняю… (может занять несколько минут)"
        svc.run(s, cmd, timeout: timeout) { text in
            logText = text
            svc.refresh(s)
        }
    }

    private func openLogs(_ s: ServerConfig, _ p: PM2Proc) {
        logTitle = p.name
        logText = "Загружаю…"
        svc.logs(s, p) { text in logText = text }
    }

    private func siteChip(_ d: String, _ m: ServerMeta) -> some View {
        let check = svc.sites[d]
        let cert = m.certs.first { d == $0.name || d.hasSuffix("." + $0.name) }
        let days = cert.map { Int($0.until.timeIntervalSinceNow / 86400) }
        let color: Color = check == nil ? Theme.faint : ((check?.up ?? false) ? Theme.green : Theme.red)
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(d).foregroundStyle(Theme.text).lineLimit(1)
            if let check, check.up { Text(String(format: "%.1f с", check.time)).foregroundStyle(Theme.faint) }
            if let days { Text("SSL \(days) дн").foregroundStyle(days < 14 ? Theme.orange : Theme.faint) }
        }
        .help(check.map { "Ответ HTTP \($0.code)" } ?? "Проверяю…")
    }

    private func bar(_ title: String, _ pct: Int, _ text: String) -> some View {
        let c: Color = pct >= 90 ? Theme.red : (pct >= 75 ? Theme.orange : Theme.green)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                Text("\(pct)%").foregroundStyle(c)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(c).frame(width: g.size.width * CGFloat(min(100, max(0, pct))) / 100)
                }
            }
            .frame(height: 4)
            Text(text).foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.system(size: 9.5))
        .frame(maxWidth: .infinity)
    }

    private func procRow(_ s: ServerConfig, _ p: PM2Proc) -> some View {
        let calm = ["stopped", "exited", "inactive", "dead"].contains(p.status)
        let dot: Color = p.ok ? Theme.green : (calm ? Theme.orange : Theme.red)
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(p.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(p.cpu < 0 ? "—" : String(format: "%.0f%%", p.cpu))
                .frame(width: 34, alignment: .trailing)
            Text(p.memMB > 0.5 ? Self.mem(p.memMB) : "—")
                .frame(width: 56, alignment: .trailing)
            Text(p.kind == "pm2" ? "pm2" : (p.kind == "docker" ? "docker" : "служба"))
                .font(.system(size: 9))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(Theme.faint)
            Text(p.ok ? (p.kind == "pm2" ? Self.uptime(p.uptime) : "работает") : ServersService.statusRu(p.status))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(p.ok ? Theme.dim : dot)
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.text)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.04)))
        .help(p.kind == "pm2" ? "Перезапусков: \(p.restarts)" : p.status)
        .contextMenu {
            Button("Показать логи") { openLogs(s, p) }
            Button("Перезапустить \(p.name)") { svc.restart(s, p) }
        }
    }

    static func mem(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f ГБ", mb / 1024) : String(format: "%.0f МБ", mb)
    }

    static func gb(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }

    static func days(_ sec: Int) -> String {
        sec >= 86400 ? "\(sec / 86400) д \(sec % 86400 / 3600) ч" : "\(sec / 3600) ч \(sec % 3600 / 60) мин"
    }

    static func uptime(_ d: Date?) -> String {
        guard let d else { return "—" }
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s >= 86400 { return "\(s / 86400)д \(s % 86400 / 3600)ч" }
        if s >= 3600 { return "\(s / 3600)ч \(s % 3600 / 60)м" }
        return "\(s / 60)м"
    }
}
