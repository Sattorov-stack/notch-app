import SwiftUI
import AppKit

struct BackupEntry {
    let name: String
    let ok: Bool
    let time: Date
    let size: Int
    let file: String
    let error: String
}

/// Следит за ночными резервными копиями (~/.notchapp/backup.sh → backups.json):
/// показывает их в «Серверах», делает копию по кнопке, предупреждает о сбое или долгом перерыве.
final class BackupMonitor: ObservableObject {
    static let shared = BackupMonitor()
    @Published var entries: [String: BackupEntry] = [:]     // хост → последняя копия
    @Published var running = false
    private var timer: Timer?
    private var warned: Set<String> = []
    private let statusURL = Disk.dir.appendingPathComponent("backups.json")
    static let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".notchapp/backup.sh").path

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.load() }
    }

    func load() {
        guard let d = try? Data(contentsOf: statusURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] else { return }
        var out: [String: BackupEntry] = [:]
        for (host, v) in o {
            out[host] = BackupEntry(name: v["name"] as? String ?? host,
                                    ok: v["ok"] as? Bool ?? false,
                                    time: Date(timeIntervalSince1970: (v["time"] as? NSNumber)?.doubleValue ?? 0),
                                    size: (v["size"] as? NSNumber)?.intValue ?? 0,
                                    file: v["file"] as? String ?? "",
                                    error: v["error"] as? String ?? "")
        }
        entries = out
        check()
    }

    private func check() {
        for (host, e) in entries {
            let stale = Date().timeIntervalSince(e.time) > 36 * 3600
            let bad = !e.ok || stale
            if bad && !warned.contains(host) {
                warned.insert(host)
                let text = !e.ok ? "резервная копия не удалась: \(e.error)" : "резервной копии нет больше полутора суток"
                NotchState.shared.showAlert(AlertItem(emoji: "💾", title: e.name, text: text, kind: .error, channel: .servers))
            } else if !bad {
                warned.remove(host)
            }
        }
    }

    /// Ищет копию по адресу сервера: «root@1.2.3.4» → «1.2.3.4»
    func entry(for target: String) -> BackupEntry? {
        let host = target.split(separator: "@").last.map(String.init) ?? target
        return entries[host]
    }

    func runNow() {
        guard !running, FileManager.default.fileExists(atPath: Self.script) else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Self.script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch {}
            DispatchQueue.main.async {
                self.running = false
                self.load()
                let ok = !self.entries.isEmpty && self.entries.values.allSatisfy { $0.ok }
                NotchState.shared.showAlert(AlertItem(emoji: "💾", title: "Резервные копии",
                    text: ok ? "готово, все серверы скопированы" : "есть ошибки — смотри «Серверы»",
                    kind: ok ? .done : .error))
            }
        }
    }

    func reveal(_ e: BackupEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.file)])
    }

    static func ago(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "'сегодня' HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "'вчера' HH:mm" }
        else { f.dateFormat = "d MMM HH:mm" }
        return f.string(from: d)
    }
}

/// Мини-график за сутки
struct Sparkline: View {
    let values: [Int]
    let color: Color

    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                let w = g.size.width, h = g.size.height
                for (i, v) in values.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(values.count - 1)
                    let y = h - h * CGFloat(min(100, max(0, v))) / 100
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }

    /// Не больше 120 точек на график
    static func thin(_ v: [Int]) -> [Int] {
        guard v.count > 120 else { return v }
        let step = Double(v.count) / 120
        return (0..<120).map { v[min(v.count - 1, Int(Double($0) * step))] }
    }
}
