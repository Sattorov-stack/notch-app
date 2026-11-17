import SwiftUI
import CoreWLAN
import Darwin

// MARK: - Данные

struct WiFiInfo: Equatable {
    var ssid: String?
    var rssi: Int              // dBm
    var noise: Int             // dBm
    var rate: Double           // Мбит/с, текущая скорость связи с роутером
    var phy: String            // «Wi‑Fi 5 (802.11ac)»
    var phyKey: String         // n / ac / ax / be / a / b / g
    var band: String           // «5 ГГц»
    var channel: Int
    var width: Int             // МГц
    var security: String
    var macSupportsAX: Bool
    var sameChannel: Int?      // сколько чужих сетей на том же канале (после сканирования)

    var snr: Int { rssi - noise }

    /// Максимум одного потока для режима и ширины канала (короткий GI, лучшая модуляция).
    var perStreamMax: Double {
        NetEval.perStreamMax(phy: phyKey, width: width)
    }
    /// Сколько потоков реально задействовано (оценка по скорости).
    var streams: Int {
        guard perStreamMax > 0 else { return 1 }
        return max(1, Int((rate / perStreamMax - 0.05).rounded(.up)))
    }
    var linkMax: Double { perStreamMax * Double(streams) }
    var linkRatio: Double { linkMax > 0 ? min(1, rate / linkMax) : 0 }
}

struct SpeedResult: Equatable {
    var down: Double           // Мбит/с
    var up: Double
    var rttMs: Double
    var rpm: Double            // отзывчивость под нагрузкой
    var iface: String
    var date: Date
    var viaVPN: Bool { NetEval.isTunnel(iface) }
}

// MARK: - Оценки (вынесены отдельно, чтобы проверять самотестом)

enum NetEval {
    static func perStreamMax(phy: String, width: Int) -> Double {
        let w = [20, 40, 80, 160, 320].contains(width) ? width : 20
        switch phy {
        case "be": return [20: 172.1, 40: 344.1, 80: 720.6, 160: 1441.2, 320: 2882.4][w] ?? 172.1
        case "ax": return [20: 143.4, 40: 286.8, 80: 600.4, 160: 1201.0, 320: 1201.0][w] ?? 143.4
        case "ac": return [20: 86.7, 40: 200.0, 80: 433.3, 160: 866.7, 320: 866.7][w] ?? 86.7
        case "n":  return w >= 40 ? 150.0 : 72.2
        case "a", "g": return 54
        case "b": return 11
        default: return 0
        }
    }

    static func nets(_ n: Int) -> String {
        let a = n % 100, b = n % 10
        if (11...14).contains(a) || b == 0 || b >= 5 { return "чужих сетей" }
        return b == 1 ? "чужая сеть" : "чужие сети"
    }

    static func isTunnel(_ iface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { iface.hasPrefix($0) }
    }

    static func signalText(_ rssi: Int) -> (String, Color) {
        switch rssi {
        case (-55)...: return ("отличный", Theme.green)
        case (-67)...: return ("хороший", Theme.green)
        case (-75)...: return ("средний", Theme.orange)
        default: return ("слабый", Theme.red)
        }
    }

    /// Вердикт по Wi‑Fi: на максимуме или нет и почему.
    static func wifiVerdict(_ w: WiFiInfo) -> (String, Color) {
        let mode = "\(w.phy.components(separatedBy: " ").prefix(2).joined(separator: " ")), \(w.width) МГц"
        let pct = Int((w.linkRatio * 100).rounded())
        var s: String
        var c: Color
        if w.linkRatio >= 0.93 {
            s = "На максимуме для режима: \(mode), потоков \(w.streams)."
            c = Theme.green
        } else if w.linkRatio >= 0.6 {
            s = "\(pct)% от максимума (\(Int(w.linkMax)) Мбит/с) — мешают расстояние или помехи."
            c = Theme.orange
        } else {
            s = "Только \(pct)% от возможного — подойди ближе к роутеру или смени канал."
            c = Theme.red
        }
        var hints: [String] = []
        if w.streams == 1 && w.perStreamMax >= 200 { hints.append("подключено одним потоком") }
        if w.macSupportsAX && (w.phyKey == "ac" || w.phyKey == "n") { hints.append("Мак умеет Wi‑Fi 6 — с роутером Wi‑Fi 6 было бы быстрее") }
        if w.band == "2,4 ГГц" { hints.append("лучше подключиться к сети 5 ГГц") }
        if let n = w.sameChannel, n >= 2 { hints.append("на канале \(w.channel) ещё \(n) \(NetEval.nets(n)) — смени канал в роутере") }
        if !hints.isEmpty {
            let h = hints.joined(separator: "; ")
            s += " " + h.prefix(1).uppercased() + h.dropFirst() + "."
        }
        return (s, c)
    }

    /// Вердикт по интернету: где узкое место.
    static func speedVerdict(_ r: SpeedResult, wifi: WiFiInfo?) -> (String, Color) {
        var parts: [String] = []
        var c = Theme.green
        // Реальная пропускная способность Wi‑Fi — около 60% от скорости связи
        if let w = wifi, w.rate > 0 {
            let wifiReal = w.rate * 0.6
            if r.down < wifiReal * 0.5 {
                parts.append("Wi‑Fi пропускает ≈\(Int(wifiReal)) Мбит/с, а интернет даёт \(Int(r.down)) — тормозит не Wi‑Fi, а " + (r.viaVPN ? "VPN или провайдер." : "провайдер/тариф."))
                c = Theme.orange
            } else {
                parts.append("Скорость упирается в Wi‑Fi — роутер ближе или кабель дадут больше.")
                c = Theme.orange
            }
        }
        if r.viaVPN { parts.append("Трафик идёт через VPN (\(r.iface)) — выключи его и проверь ещё раз для сравнения.") }
        if r.rttMs >= 120 { parts.append("Задержка \(Int(r.rttMs)) мс — высокая."); c = Theme.red }
        else if r.rttMs >= 60 { parts.append("Задержка \(Int(r.rttMs)) мс — терпимая.") }
        return (parts.joined(separator: " "), c)
    }

    static func rpmText(_ rpm: Double) -> String {
        rpm >= 800 ? "высокая" : (rpm >= 200 ? "средняя" : "низкая")
    }

    /// Разбор JSON от `networkQuality -c`.
    static func parse(_ data: Data) -> SpeedResult? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (d["dl_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let ul = (d["ul_throughput"] as? NSNumber)?.doubleValue ?? 0
        return SpeedResult(down: dl / 1_000_000, up: ul / 1_000_000,
                           rttMs: (d["base_rtt"] as? NSNumber)?.doubleValue ?? 0,
                           rpm: (d["responsiveness"] as? NSNumber)?.doubleValue ?? 0,
                           iface: d["interface_name"] as? String ?? "?",
                           date: Date())
    }
}

// MARK: - Монитор: Wi‑Fi раз в 2 с, пока раздел открыт; замер скорости — по кнопке

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var wifi: WiFiInfo?
    @Published var wifiOff = false
    @Published var speed: SpeedResult?
    @Published var testing = false
    @Published var testStarted: Date?
    @Published var error: String?

    private var timer: Timer?
    private var users = 0
    private var macAX: Bool?
    private var lastScanChannel: Int?
    private var sameChannel: Int?
    private var proc: Process?

    func appear() {
        users += 1
        refreshWiFi()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshWiFi() }
        }
        if macAX == nil { detectMacAX() }
        if lastScanChannel == nil { scanNeighbours() }
    }

    func disappear() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

    func refreshWiFi() {
        wifi = Self.readWiFi(macAX: macAX ?? false, sameChannel: sameChannel)
        wifiOff = wifi == nil
        if let w = wifi, lastScanChannel != nil, lastScanChannel != w.channel { scanNeighbours() }
    }

    static func readWiFi(macAX: Bool, sameChannel: Int?) -> WiFiInfo? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn(),
              let ch = i.wlanChannel(), i.rssiValue() != 0 else { return nil }
        let phyKey: String
        switch i.activePHYMode().rawValue {
        case 1: phyKey = "a"
        case 2: phyKey = "b"
        case 3: phyKey = "g"
        case 4: phyKey = "n"
        case 5: phyKey = "ac"
        case 6: phyKey = "ax"
        case 7: phyKey = "be"
        default: phyKey = "?"
        }
        let phy: String = [
            "n": "Wi‑Fi 4 (802.11n)", "ac": "Wi‑Fi 5 (802.11ac)", "ax": "Wi‑Fi 6 (802.11ax)",
            "be": "Wi‑Fi 7 (802.11be)", "a": "802.11a", "b": "802.11b", "g": "802.11g",
        ][phyKey] ?? "неизвестно"
        let width: Int = [1: 20, 2: 40, 3: 80, 4: 160, 5: 320][ch.channelWidth.rawValue] ?? 20
        let band: String = [1: "2,4 ГГц", 2: "5 ГГц", 3: "6 ГГц"][ch.channelBand.rawValue] ?? "?"
        let sec: String
        switch i.security() {
        case .none: sec = "без пароля"
        case .wpa2Personal, .personal: sec = "WPA2"
        case .wpa3Personal, .wpa3Transition: sec = "WPA3"
        case .wpaPersonal, .wpaPersonalMixed: sec = "WPA"
        case .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .enterprise: sec = "корпоративная"
        default: sec = "—"
        }
        return WiFiInfo(ssid: i.ssid(), rssi: i.rssiValue(), noise: i.noiseMeasurement(),
                        rate: i.transmitRate(), phy: phy, phyKey: phyKey, band: band,
                        channel: ch.channelNumber, width: width, security: sec,
                        macSupportsAX: macAX, sameChannel: sameChannel)
    }

    /// Умеет ли сам Мак Wi‑Fi 6 — один раз из system_profiler.
    private func detectMacAX() {
        macAX = false
        DispatchQueue.global(qos: .utility).async {
            let out = Self.run("/usr/sbin/system_profiler", ["SPAirPortDataType"])
            let line = out.split(separator: "\n").first { $0.contains("Supported PHY Modes") } ?? ""
            let ax = line.contains("ax") || line.contains("be")
            DispatchQueue.main.async { self.macAX = ax; self.refreshWiFi() }
        }
    }

    /// Сколько чужих сетей на нашем канале (помехи).
    func scanNeighbours() {
        guard let i = CWWiFiClient.shared().interface(), let my = i.wlanChannel() else { return }
        lastScanChannel = my.channelNumber
        let myBSSID = i.bssid()
        DispatchQueue.global(qos: .utility).async {
            guard let nets = try? i.scanForNetworks(withSSID: nil) else { return }
            let n = nets.filter { $0.wlanChannel?.channelNumber == my.channelNumber
                                  && ($0.bssid == nil || $0.bssid != myBSSID) }.count
            // свою сеть сканирование тоже находит — если BSSID скрыт, вычитаем её
            let others = myBSSID == nil ? max(0, n - 1) : n
            DispatchQueue.main.async { self.sameChannel = others; self.refreshWiFi() }
        }
    }

    // MARK: Замер скорости через встроенный networkQuality

    func runSpeedTest() {
        guard !testing else { return }
        testing = true
        testStarted = Date()
        error = nil
        scanNeighbours()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        p.arguments = ["-c", "-M", "15"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let r = NetEval.parse(data)
            DispatchQueue.main.async {
                guard let self else { return }
                self.testing = false
                self.proc = nil
                if let r { self.speed = r } else { self.error = "Нет связи с сервером проверки — интернета нет?" }
            }
        }
        do { try p.run(); proc = p } catch {
            testing = false
            self.error = "Не удалось запустить networkQuality"
        }
    }

    func cancelTest() { proc?.terminate() }

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Вид «Интернет»

struct InternetView: View {
    @ObservedObject var n = NetworkMonitor.shared
    @Environment(\.compactNotch) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top, spacing: 8) {
                wifiCard
                speedCard
            }
            if let r = n.speed {
                let v = NetEval.speedVerdict(r, wifi: n.wifi)
                Text(v.0)
                    .font(.system(size: compact ? 9.5 : 11))
                    .foregroundStyle(v.1)
                    .lineLimit(compact ? 3 : 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { n.appear() }
        .onDisappear { n.disappear() }
    }

    private var fs: CGFloat { compact ? 9.5 : 11 }

    private var wifiCard: some View {
        GlassCard(padding: compact ? 8 : 12, corner: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "wifi").foregroundStyle(Theme.accent)
                    Text(n.wifi?.ssid ?? "Wi‑Fi")
                        .font(.system(size: fs + 1.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let w = n.wifi {
                        Text("\(Int(w.rate)) Мбит/с")
                            .font(.system(size: fs + 1.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                if let w = n.wifi {
                    let sig = NetEval.signalText(w.rssi)
                    Text("\(w.phy) · \(w.band) · канал \(w.channel) · \(w.width) МГц · \(w.security)")
                        .foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 4) {
                        Text("Сигнал \(w.rssi) dBm —")
                        Text(sig.0).foregroundStyle(sig.1)
                        Text("· шум \(w.noise) · запас \(w.snr) дБ").foregroundStyle(Theme.dim)
                    }
                    .lineLimit(1).minimumScaleFactor(0.8)
                    ProgressView(value: w.linkRatio)
                        .tint(NetEval.wifiVerdict(w).1)
                        .controlSize(.mini)
                    let v = NetEval.wifiVerdict(w)
                    Text(v.0).foregroundStyle(v.1)
                        .lineLimit(compact ? 4 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(n.wifiOff ? "Wi‑Fi выключен или не подключён (возможно, кабель)" : "Читаю…")
                        .foregroundStyle(Theme.dim)
                }
            }
            .font(.system(size: fs))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speedCard: some View {
        GlassCard(padding: compact ? 8 : 12, corner: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "globe").foregroundStyle(Theme.accent)
                    Text("Интернет").font(.system(size: fs + 1.5, weight: .semibold))
                    Spacer(minLength: 0)
                }
                if n.testing {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(n.testStarted ?? ctx.date))
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Замер… \(s) с из ~15").foregroundStyle(Theme.dim)
                        }
                    }
                    Button("Отменить") { n.cancelTest() }
                } else {
                    if let r = n.speed {
                        HStack(spacing: 10) {
                            metric("↓", r.down, "загрузка")
                            metric("↑", r.up, "отдача")
                        }
                        Text("Задержка \(Int(r.rttMs)) мс · отзывчивость \(NetEval.rpmText(r.rpm))")
                            .foregroundStyle(r.rttMs >= 120 ? Theme.red : Theme.dim)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(r.viaVPN ? "Через VPN (\(r.iface)) · \(r.date.formatted(date: .omitted, time: .shortened))"
                                      : "Напрямую (\(r.iface)) · \(r.date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(r.viaVPN ? Theme.orange : Theme.dim)
                            .lineLimit(1)
                    } else if let e = n.error {
                        Text(e).foregroundStyle(Theme.red)
                    } else {
                        Text("Проверю реальную скорость и задержку через сервер Apple (~15 с, около 30–100 МБ трафика).")
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(n.speed == nil ? "Проверить скорость" : "Проверить ещё раз") { n.runSpeedTest() }
                }
            }
            .font(.system(size: fs))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: compact ? 190 : 250)
    }

    private func metric(_ arrow: String, _ v: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(arrow) \(v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded())))")
                .font(.system(size: compact ? 17 : 22, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("Мбит/с, \(label)").font(.system(size: fs - 1)).foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - Самопроверка: NotchApp --selftest-net

enum NetSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool) { print((cond ? "✅ " : "❌ ") + name); if !cond { ok = false } }

        // Расчёт максимума и потоков
        var w = WiFiInfo(ssid: "test", rssi: -54, noise: -92, rate: 433, phy: "Wi‑Fi 5 (802.11ac)", phyKey: "ac",
                         band: "5 ГГц", channel: 36, width: 80, security: "WPA2", macSupportsAX: true, sameChannel: 3)
        check("ac 80 МГц 433 → 1 поток, на максимуме", w.streams == 1 && w.linkRatio > 0.99)
        w.rate = 866; check("ac 80 МГц 866 → 2 потока", w.streams == 2)
        w.rate = 650; check("ac 80 МГц 650 → 2 потока, не максимум", w.streams == 2 && w.linkRatio < 0.8)
        w.phyKey = "ax"; w.rate = 1201; check("ax 80 МГц 1201 → 2 потока", w.streams == 2 && w.linkRatio > 0.99)
        w.phyKey = "ac"; w.rate = 433
        let v = NetEval.wifiVerdict(w).0
        check("вердикт упоминает один поток, Wi‑Fi 6 и канал", v.contains("одним потоком") && v.contains("Wi‑Fi 6") && v.contains("канале 36"))
        print("   «\(v)»")
        check("VPN по интерфейсу", NetEval.isTunnel("utun4") && !NetEval.isTunnel("en0"))

        // Разбор JSON networkQuality
        let json = #"{"dl_throughput":35530000,"ul_throughput":28378000,"base_rtt":199.6,"responsiveness":73,"interface_name":"utun4"}"#
        if let r = NetEval.parse(Data(json.utf8)) {
            check("разбор JSON", abs(r.down - 35.53) < 0.01 && r.viaVPN && Int(r.rttMs) == 199)
            let sv = NetEval.speedVerdict(r, wifi: w).0
            check("вердикт: тормозит не Wi‑Fi, VPN", sv.contains("не Wi‑Fi") && sv.contains("VPN"))
            print("   «\(sv)»")
        } else { check("разбор JSON", false) }

        // Живое чтение Wi‑Fi этого Мака
        if let live = NetworkMonitor.readWiFi(macAX: true, sameChannel: nil) {
            print("ℹ️ Сейчас: \(live.phy), \(live.band), канал \(live.channel), \(live.width) МГц, \(Int(live.rate)) Мбит/с, сигнал \(live.rssi) dBm, потоков \(live.streams), \(Int(live.linkRatio * 100))% от максимума")
            check("живые данные Wi‑Fi правдоподобны", live.rate > 0 && live.rssi < 0 && live.channel > 0)
            if let i = CWWiFiClient.shared().interface(), let nets = try? i.scanForNetworks(withSSID: nil) {
                let same = nets.filter { $0.wlanChannel?.channelNumber == live.channel }.count
                print("ℹ️ Сканирование: сетей рядом \(nets.count), на канале \(live.channel) — \(same) (включая свою)")
                check("сканирование соседних сетей", nets.count > 0)
            } else { check("сканирование соседних сетей", false) }
        } else {
            print("ℹ️ Wi‑Fi не подключён — живую часть пропускаю")
        }

        // Сторож интернета: тот же запрос, что раз в 20 с
        let sem = DispatchSemaphore(value: 0)
        var watchOK = false
        URLSession.shared.dataTask(with: URL(string: "https://captive.apple.com/hotspot-detect.html")!) { d, r, _ in
            watchOK = (r as? HTTPURLResponse)?.statusCode == 200 && String(decoding: d ?? Data(), as: UTF8.self).contains("Success")
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        check("сторож видит интернет", watchOK)

        // Живой замер (короткий), если попросили
        if CommandLine.arguments.contains("--live") {
            let out = NetworkMonitor.run("/usr/bin/networkQuality", ["-c", "-M", "10"])
            if let r = NetEval.parse(Data(out.utf8)) {
                print("ℹ️ Замер: ↓\(Int(r.down)) ↑\(Int(r.up)) Мбит/с, задержка \(Int(r.rttMs)) мс, через \(r.iface)")
                check("живой замер", r.down > 0)
            } else { check("живой замер", false) }
        }
        print(ok ? "Итог: всё верно" : "Итог: есть ошибки")
        return ok
    }
}

// MARK: - Сторож: раз в 20 с проверяет, есть ли интернет, и предупреждает в чёлке

final class InternetWatch: ObservableObject {
    static let shared = InternetWatch()
    @Published var online: Bool?          // nil — ещё не проверяли
    @Published var pingMs: Int?
    @Published var downSince: Date?

    private var fails = 0
    private var timer: Timer?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        var req = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        req.httpMethod = "GET"
        let t0 = Date()
        session.dataTask(with: req) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                && String(decoding: data ?? Data(), as: UTF8.self).contains("Success")
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async { self?.apply(ok: ok, ms: ms) }
        }.resume()
    }

    private func apply(ok: Bool, ms: Int) {
        if ok {
            pingMs = ms
            if online == false, let since = downSince {
                let mins = max(1, Int(Date().timeIntervalSince(since) / 60))
                NotchState.shared.showAlert(AlertItem(emoji: "🌐", title: "Интернет",
                                                      text: "снова есть (не было ≈\(mins) мин)", kind: .done))
            }
            online = true
            fails = 0
            downSince = nil
        } else {
            fails += 1
            pingMs = nil
            // Два провала подряд (~20 с) — значит, правда пропал, а не случайная потеря
            if fails == 2 {
                online = false
                downSince = Date().addingTimeInterval(-20)
                let wifi = NetworkMonitor.readWiFi(macAX: false, sameChannel: nil)
                NotchState.shared.showAlert(AlertItem(emoji: "📵", title: "Интернет",
                                                      text: wifi == nil ? "пропал — Wi‑Fi не подключён"
                                                                        : "пропал — Wi‑Fi есть, нет выхода в сеть",
                                                      kind: .error))
            }
        }
    }
}

// MARK: - Карточка на Главной

struct HomeInternetCard: View {
    @ObservedObject var n = NetworkMonitor.shared
    @ObservedObject var watch = InternetWatch.shared

    var body: some View {
        GlassCard(padding: 9) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: watch.online == false ? "wifi.exclamationmark" : "wifi")
                        .font(.system(size: 10))
                        .foregroundStyle(watch.online == false ? Theme.red : Theme.accent)
                    Text("ИНТЕРНЕТ")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    if let p = watch.pingMs {
                        Text("отклик \(p) мс").font(.system(size: 9))
                            .foregroundStyle(p >= 300 ? Theme.orange : Theme.faint)
                    }
                }
                if watch.online == false {
                    Text("Нет интернета").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.red)
                } else if let r = n.speed {
                    HStack(spacing: 8) {
                        Text("↓\(Int(r.down.rounded()))").font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("↑\(Int(r.up.rounded()))").font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.dim)
                        Text("Мбит/с").font(.system(size: 9)).foregroundStyle(Theme.faint)
                    }
                    .monospacedDigit().foregroundStyle(Theme.text)
                } else {
                    Text("Скорость ещё не замеряли").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                if let w = n.wifi {
                    let sig = NetEval.signalText(w.rssi)
                    HStack(spacing: 3) {
                        Text("Wi‑Fi \(Int(w.rate)) Мбит/с ·")
                        Text("сигнал \(sig.0)").foregroundStyle(sig.1)
                    }
                    .font(.system(size: 9.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(n.testing ? "Замер…" : "Проверить") { n.runSpeedTest() }
                        .disabled(n.testing)
                        .font(.system(size: 9.5))
                    Button {
                        UserDefaults.standard.set("net", forKey: "systemMode")
                        NotchState.shared.tab = .system
                    } label: {
                        HStack(spacing: 3) { Text("Подробно"); Image(systemName: "arrow.right") }
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { n.appear() }
        .onDisappear { n.disappear() }
    }
}
