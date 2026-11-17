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
        if let n = w.sameChannel, n >= 2 { hints.append("на канале \(w.channel) ещё \(n) чужих сетей — смени канал в роутере") }
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
