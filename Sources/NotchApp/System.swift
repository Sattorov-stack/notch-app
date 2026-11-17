import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import Darwin

struct BatteryInfo {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
    var cycles: Int?
    var health: Int?
}

struct ProcInfo: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double
}

/// Процессор, память, батарея (с износом), диск, нагрев и самые «тяжёлые» процессы.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    @Published var cpu: Double = 0
    @Published var memUsed: Double = 0
    @Published var memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var battery: BatteryInfo?
    @Published var diskFree: Double = 0
    @Published var diskTotal: Double = 0
    @Published var top: [ProcInfo] = []
    @Published var thermal = ""

    private let host = mach_host_self()
    private var prevBusy: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var timer: Timer?
    private var tickCount = 0
    private var lowWarned = false

    func start() {
        sampleCPU()
        sampleBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func refreshNow() {
        sampleCPU(); sampleMemory(); sampleDisk(); sampleThermal(); sampleTop(); sampleBattery()
    }

    private func tick() {
        tickCount += 1
        sampleCPU()                                   // дёшево — держим цифру готовой
        let s = NotchState.shared
        let visible = (s.expanded && (s.tab == .system || s.tab == .home)) || SectionWindows.shared.isOpen(.system)
        if visible { sampleMemory(); sampleDisk(); sampleThermal(); sampleTop() }
        if visible || tickCount % 15 == 0 { sampleBattery() }    // в фоне раз в 30 с — для предупреждения
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let h = host
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(h, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice
        let total = busy + idle
        if prevTotal > 0, total > prevTotal, busy >= prevBusy {
            cpu = Double(busy - prevBusy) / Double(total - prevTotal)
        }
        prevBusy = busy
        prevTotal = total
    }

    /// Как «Использовано памяти» в Мониторинге системы: приложения + связанная + сжатая.
    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let h = host
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(h, HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(getpagesize())
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count))
        memUsed = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        if let a = v.volumeAvailableCapacityForImportantUsage { diskFree = Double(a) }
        if let t = v.volumeTotalCapacity { diskTotal = Double(t) }
    }

    private func sampleThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "в норме"
        case .fair: thermal = "тёплый"
        case .serious: thermal = "горячий, частота снижена"
        case .critical: thermal = "перегрев!"
        @unknown default: thermal = "—"
        }
    }

    private func sampleTop() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Aceo", "pcpu,comm", "-r"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().prefix(5)
            let list: [ProcInfo] = lines.compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " ") else { return nil }
                let cpu = Double(t[..<sp].replacingOccurrences(of: ",", with: ".")) ?? 0
                let name = t[sp...].trimmingCharacters(in: .whitespaces)
                return ProcInfo(name: name, cpu: cpu)
            }
            DispatchQueue.main.async { self.top = list }
        }
    }

    private func sampleBattery() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let cfList = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() else {
            battery = nil
            return
        }
        var info: BatteryInfo?
        for ps in (cfList as NSArray as [AnyObject]) {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery" else { continue }
            let cur = desc["Current Capacity"] as? Int ?? 0
            let mx = desc["Max Capacity"] as? Int ?? 100
            let tte = desc["Time to Empty"] as? Int ?? -1
            info = BatteryInfo(percent: mx > 0 ? cur * 100 / mx : cur,
                               charging: desc["Is Charging"] as? Bool ?? false,
                               onAC: (desc["Power Source State"] as? String) == "AC Power",
                               minutesLeft: tte > 0 ? tte : nil,
                               cycles: nil, health: nil)
        }

        // Износ: число циклов и реальная ёмкость относительно заводской
        if info != nil {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if svc != 0 {
                func prop(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Int
                }
                info?.cycles = prop("CycleCount")
                if let design = prop("DesignCapacity"), let raw = prop("AppleRawMaxCapacity"), design > 0 {
                    info?.health = min(100, raw * 100 / design)
                }
                IOObjectRelease(svc)
            }
        }
        battery = info

        // Питомец предупредит о разряде
        if let b = info, !b.onAC, b.percent <= 15 {
            if !lowWarned {
                lowWarned = true
                NotchState.shared.showAlert(AlertItem(emoji: "🪫", title: "Батарея",
                                                      text: "\(b.percent)% — подключи зарядку", kind: .error))
            }
        } else if let b = info, b.onAC || b.percent > 20 {
            lowWarned = false
        }
    }
}

struct RingView: View {
    let title: String
    let value: Double          // 0...1
    let text: String
    var invert = false         // для батареи: мало — плохо
    var size: CGFloat = 84

    private var tint: Color {
        let v = invert ? 1 - value : value
        return v < 0.6 ? Theme.green : (v < 0.85 ? Theme.orange : Theme.red)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, value))))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: value)
                Text(text)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Theme.text)
                    .padding(6)
            }
            .frame(width: size, height: size)
            Text(title).font(.system(size: 9.5)).foregroundStyle(Theme.dim)
        }
    }
}

struct SystemView: View {
    @ObservedObject var m = SystemMonitor.shared
    @Environment(\.compactNotch) private var compact

    private func gb(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                RingView(title: "Процессор", value: m.cpu, text: "\(Int(m.cpu * 100))%",
                         size: compact ? 78 : 104)
                RingView(title: "Память",
                         value: m.memTotal > 0 ? m.memUsed / m.memTotal : 0,
                         text: "\(gb(m.memUsed))\nиз \(gb(m.memTotal)) ГБ",
                         size: compact ? 78 : 104)
                if let b = m.battery {
                    RingView(title: b.charging ? "Заряжается" : (b.onAC ? "От сети" : "Батарея"),
                             value: Double(b.percent) / 100, text: "\(b.percent)%", invert: true,
                             size: compact ? 78 : 104)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let b = m.battery {
                    if let mins = b.minutesLeft, !b.onAC {
                        Text("Осталось ≈ \(mins / 60) ч \(mins % 60) мин")
                    }
                    if let h = b.health {
                        Text("Здоровье батареи \(h)%" + (b.cycles.map { ", циклов \($0)" } ?? ""))
                    }
                }
                if m.diskTotal > 0 {
                    Text("Диск: свободно \(gb(m.diskFree)) из \(gb(m.diskTotal)) ГБ")
                }
                if !m.thermal.isEmpty { Text("Нагрев: \(m.thermal)") }
                Text("Больше всего грузят процессор:")
                    .foregroundStyle(Theme.dim).padding(.top, 3)
                ForEach(m.top) { p in
                    HStack {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu)).monospacedDigit()
                    }
                    .foregroundStyle(Theme.text)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { m.refreshNow() }
    }
}
