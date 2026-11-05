import SwiftUI
import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Блокировка клавиатуры (для протирания)

fileprivate var kbTap: CFMachPort?

/// Глушит все события из маски. Если система отключила перехват по таймауту — включаем обратно.
private let kbCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = kbTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return nil
}

final class KeyboardLock: ObservableObject {
    static let shared = KeyboardLock()
    @Published var locked = false
    @Published var remaining = 0
    @Published var duration = 60
    @Published var includePointer = false
    @Published var message: String?

    private var timer: Timer?
    private var source: CFRunLoopSource?

    func lock() {
        message = nil
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            message = "Разреши NotchApp: Настройки → Конфиденциальность и безопасность → Универсальный доступ, потом нажми ещё раз"
            return
        }

        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        if includePointer {
            types += [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                      .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                      .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        }
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        mask |= CGEventMask(1) << 14   // системные клавиши: громкость, яркость, медиа

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: kbCallback,
                                          userInfo: nil) else {
            message = "Не удалось перехватить клавиатуру"
            return
        }
        kbTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        remaining = duration
        locked = true
        // Аварийный выход: блокировка снимается сама по таймеру
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.unlock() }
        }
    }

    func unlock() {
        if let t = kbTap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
        }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        kbTap = nil
        source = nil
        timer?.invalidate()
        timer = nil
        locked = false
        remaining = 0
    }
}

// MARK: - Не засыпать (в том числе с закрытой крышкой)

final class SleepGuard: ObservableObject {
    static let shared = SleepGuard()
    @Published var awake = false
    @Published var lidMode = false
    @Published var working = false
    @Published var message: String?
    private var assertionID: IOPMAssertionID = 0

    /// Обычный режим: Mac не засыпает от бездействия (крышка открыта)
    func setAwake(_ on: Bool) {
        if on {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "NotchApp: не засыпать" as CFString, &id)
            if r == kIOReturnSuccess {
                assertionID = id
                awake = true
            }
        } else {
            if assertionID != 0 { IOPMAssertionRelease(assertionID) }
            assertionID = 0
            awake = false
        }
    }

    /// Режим «крышка закрыта»: системный pmset disablesleep, нужен пароль администратора
    func setLidMode(_ on: Bool) {
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.runAdmin("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)")
            DispatchQueue.main.async {
                self.working = false
                if ok { self.lidMode = on } else { self.message = "Не применилось: нужен пароль администратора" }
            }
        }
    }

    /// Узнаём текущее состояние при запуске
    func refresh() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        lidMode = out.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
    }

    /// При выходе возвращаем нормальный сон, чтобы ноутбук не грелся в сумке
    func cleanupOnQuit() {
        setAwake(false)
        if lidMode { _ = Self.runAdmin("/usr/bin/pmset -a disablesleep 0") }
    }

    private static func runAdmin(_ cmd: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(cmd)\" with administrator privileges"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Автозапуск

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var message: String?

    func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "Автозапуск работает только у собранного NotchApp.app"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Вкладка «Инструменты»

struct ToolsView: View {
    @ObservedObject var kb = KeyboardLock.shared
    @ObservedObject var sleep = SleepGuard.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            keyboardCard
            VStack(alignment: .leading, spacing: 8) {
                sleepCard
                systemCard
            }
        }
        .controlSize(.small)
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Протереть клавиатуру", systemImage: "keyboard").font(.system(size: 12, weight: .semibold))
            if kb.locked {
                Text("Клавиатура выключена. Осталось \(kb.remaining) с")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                if kb.includePointer {
                    Text("Трекпад тоже выключен, всё включится само по таймеру")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Включить клавиатуру") { kb.unlock() }
                }
            } else {
                HStack {
                    Picker("", selection: $kb.duration) {
                        Text("30 с").tag(30)
                        Text("1 мин").tag(60)
                        Text("2 мин").tag(120)
                        Text("5 мин").tag(300)
                    }
                    .labelsHidden().frame(width: 90)
                    Button("Выключить клавиатуру") { kb.lock() }
                }
                Toggle("Выключить и трекпад (до конца таймера)", isOn: $kb.includePointer)
                    .toggleStyle(.checkbox).font(.caption)
                Text("Кнопку питания и Touch ID программно отключить нельзя")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let m = kb.message { Text(m).font(.caption2).foregroundStyle(.orange) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private var sleepCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Не засыпать", systemImage: "moon.zzz").font(.system(size: 12, weight: .semibold))
            Toggle("Крышка открыта: не засыпать от бездействия",
                   isOn: Binding(get: { sleep.awake }, set: { sleep.setAwake($0) }))
                .toggleStyle(.switch).font(.caption)
            Toggle("Работать с закрытой крышкой (загрузки не оборвутся)",
                   isOn: Binding(get: { sleep.lidMode }, set: { sleep.setLidMode($0) }))
                .toggleStyle(.switch).font(.caption)
                .disabled(sleep.working)
            Text(sleep.lidMode
                 ? "Включено. Не клади ноутбук в сумку: он будет греться. При выходе из приложения сон вернётся."
                 : "Попросит пароль администратора один раз при включении и при выключении")
                .font(.caption2).foregroundStyle(sleep.lidMode ? Color.orange : Color.secondary)
            if let m = sleep.message { Text(m).font(.caption2).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var systemCard: some View {
        HStack {
            Toggle("Запускать при входе", isOn: Binding(get: { settings.launchAtLogin },
                                                        set: { settings.setLaunch($0) }))
                .toggleStyle(.checkbox).font(.caption)
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
        }
        .overlay(alignment: .bottomLeading) {
            if let m = settings.message {
                Text(m).font(.caption2).foregroundStyle(.orange).offset(y: 14)
            }
        }
        .card()
    }
}
