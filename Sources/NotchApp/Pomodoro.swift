import SwiftUI
import AppKit

// MARK: - Помодоро

final class PomodoroService: ObservableObject {
    static let shared = PomodoroService()
    enum Phase { case work, shortBreak, longBreak }

    private let d = UserDefaults.standard
    @Published var phase: Phase = .work
    @Published var remaining = 25 * 60
    @Published var running = false
    @Published var completedToday = 0
    @Published var workMin: Int { didSet { d.set(workMin, forKey: "pomoWork"); resetIfIdle() } }
    @Published var shortMin: Int { didSet { d.set(shortMin, forKey: "pomoShort"); resetIfIdle() } }
    @Published var longMin: Int { didSet { d.set(longMin, forKey: "pomoLong"); resetIfIdle() } }
    @Published var autoContinue: Bool { didSet { d.set(autoContinue, forKey: "pomoAuto") } }

    private var endDate: Date?
    private var timer: Timer?

    init() {
        let ud = UserDefaults.standard
        let w = ud.integer(forKey: "pomoWork"), s = ud.integer(forKey: "pomoShort"), l = ud.integer(forKey: "pomoLong")
        workMin = w > 0 ? w : 25
        shortMin = s > 0 ? s : 5
        longMin = l > 0 ? l : 15
        autoContinue = ud.object(forKey: "pomoAuto") as? Bool ?? true
        remaining = workMin * 60
        completedToday = ud.string(forKey: "pomoDay") == Self.today() ? ud.integer(forKey: "pomoCount") : 0
    }

    func duration(_ p: Phase) -> Int {
        switch p {
        case .work: return workMin * 60
        case .shortBreak: return shortMin * 60
        case .longBreak: return longMin * 60
        }
    }

    var title: String {
        switch phase {
        case .work: return "Работа"
        case .shortBreak: return "Короткий перерыв"
        case .longBreak: return "Длинный перерыв"
        }
    }

    var emoji: String {
        switch phase {
        case .work: return "🍅"
        case .shortBreak: return "☕️"
        case .longBreak: return "🌴"
        }
    }

    var display: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }

    func toggle() { running ? pause() : start() }

    func start() {
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        running = true
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        running = false
        timer?.invalidate()
        timer = nil
        endDate = nil
    }

    func reset() {
        pause()
        phase = .work
        remaining = duration(.work)
    }

    func skip() { advance(finished: false) }

    private func resetIfIdle() { if !running { remaining = duration(phase) } }

    /// Время считается от момента окончания, а не счётчиком — таймер не отстаёт после сна Mac.
    private func tick() {
        guard let end = endDate else { return }
        let left = max(0, Int(ceil(end.timeIntervalSinceNow)))
        if left != remaining { remaining = left }
        if left <= 0 { advance(finished: true) }
    }

    private func advance(finished: Bool) {
        let wasRunning = running
        pause()
        if phase == .work {
            if finished {
                let ud = UserDefaults.standard
                if ud.string(forKey: "pomoDay") != Self.today() { completedToday = 0 }
                completedToday += 1
                ud.set(Self.today(), forKey: "pomoDay")
                ud.set(completedToday, forKey: "pomoCount")
            }
            phase = finished && completedToday % 4 == 0 ? .longBreak : .shortBreak
        } else {
            phase = .work
        }
        remaining = duration(phase)

        if finished {
            NSSound(named: "Glass")?.play()
            let text = phase == .work
                ? "Перерыв окончен — за работу!"
                : "Помидор готов, сегодня \(completedToday). Отдохни."
            NotchState.shared.showAlert(AlertItem(emoji: emoji, title: "Помодоро", text: text, kind: .done))
        }
        if wasRunning && (autoContinue || !finished) { start() }
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

struct PomodoroView: View {
    @ObservedObject var p = PomodoroService.shared
    @Environment(\.compactNotch) private var compact

    private var progress: CGFloat {
        let total = Double(p.duration(p.phase))
        return total > 0 ? CGFloat(Double(p.remaining) / total) : 0
    }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 18 : 30) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(p.phase == .work ? Theme.red : Theme.green,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                VStack(spacing: 1) {
                    Text(p.emoji).font(.system(size: compact ? 18 : 24))
                    Text(p.display)
                        .font(.system(size: compact ? 24 : 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text(p.title).font(.system(size: 9.5)).foregroundStyle(Theme.dim)
                }
            }
            .frame(width: compact ? 128 : 180, height: compact ? 128 : 180)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Button(p.running ? "Пауза" : "Старт") { p.toggle() }
                    Button("Пропустить") { p.skip() }
                    Button("Сброс") { p.reset() }
                }
                Text("Сегодня: \(String(repeating: "🍅", count: min(p.completedToday, 8))) \(p.completedToday)")
                    .foregroundStyle(Theme.dim)
                Stepper("Работа: \(p.workMin) мин", value: $p.workMin, in: 5...90, step: 5)
                Stepper("Перерыв: \(p.shortMin) мин", value: $p.shortMin, in: 1...30)
                Stepper("Длинный: \(p.longMin) мин (после 4-го)", value: $p.longMin, in: 5...60, step: 5)
                Toggle("Сразу запускать следующий этап", isOn: $p.autoContinue)
                    .toggleStyle(.checkbox)
                Text("⌃⌥P — старт/пауза из любого приложения")
                    .font(.system(size: 9)).foregroundStyle(Theme.faint)
            }
            .font(.system(size: 10.5))
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}
