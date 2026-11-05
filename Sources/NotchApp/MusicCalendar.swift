import SwiftUI
import AppKit
import EventKit
import ApplicationServices
import Combine

/// Проверка разрешения на автоматизацию без системного диалога —
/// чтобы не ждать таймаут AppleScript каждый раз.
enum Automation {
    private static var asked = Set<String>()

    static func requestOnce(_ bundleID: String) {
        guard !asked.contains(bundleID) else { return }
        asked.insert(bundleID)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let address = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return }
            _ = AEDeterminePermissionToAutomateTarget(address,
                                                      AEEventClass(0x2A2A2A2A),
                                                      AEEventID(0x2A2A2A2A),
                                                      true)
        }
    }

    static func allowed(_ bundleID: String) -> Bool {
        guard let address = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(address,
                                                          AEEventClass(0x2A2A2A2A),
                                                          AEEventID(0x2A2A2A2A),
                                                          false)
        return status == noErr
    }
}

/// Управление браузером клавишами YouTube (k — пауза, j/l — ±10 с).
/// Нужен «Универсальный доступ»; фокус кратко уходит в браузер и возвращается.
enum MediaKeys {
    static func send(bundleID: String, key: CGKeyCode) -> Bool {
        guard AXWindow.trusted else {
            AXWindow.requestOnce()
            return false
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        let previous = NSWorkspace.shared.frontmostApplication
        app.activate(options: [.activateIgnoringOtherApps])
        usleep(160_000)

        // Если фокус в адресной строке/поле — не печатаем туда "k/j/l"
        if focusIsText() {
            if let previous, previous.bundleIdentifier != bundleID {
                previous.activate(options: [.activateIgnoringOtherApps])
            }
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(110_000)
        if let previous, previous.bundleIdentifier != bundleID {
            previous.activate(options: [.activateIgnoringOtherApps])
        }
        return true
    }

    private static func focusIsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
            return false
        }
        let name = (role as? String) ?? ""
        return name == "AXTextField" || name == "AXTextArea" || name == "AXComboBox"
    }

    static func key(for command: String) -> CGKeyCode {
        switch command {
        case "playpause": return 40   // k
        case "previous track": return 38 // j
        default: return 37            // l
        }
    }
}

/// Чтение заголовка окна браузера через Accessibility — нужно для Firefox,
/// у которого нет AppleScript-доступа к вкладкам.
enum AXWindow {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func title(bundleID: String) -> String? {
        guard trusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = windows.first else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }
        return titleValue as? String
    }

    private static var asked = false

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestOnce() {
        guard !trusted, !asked else { return }
        asked = true
        DispatchQueue.main.async { request() }
    }
}

// MARK: - Музыка: Music, Spotify и то, что играет в системе

/// Запуск AppleScript отдельным процессом: можно прервать по таймауту и увидеть ошибку
/// (например, отказ в доступе к автоматизации), а не зависнуть внутри приложения.
enum AppleScriptRunner {
    static func run(_ source: String, timeout: TimeInterval = 3) -> (out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return ("", "launch failed") }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            usleep(150_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return ("", "timeout")
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out.trimmingCharacters(in: .whitespacesAndNewlines),
                err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct MusicTrack {
    var title: String
    var artist: String
    var playing: Bool
    var position: Double
    var duration: Double
    var app: String
    var system: Bool
    var artwork: NSImage?
    var browser = false
    var browserBundle: String? = nil
}

/// Доступ к системному «Сейчас играет» через MediaRemote:
/// так видны видео из браузера и любые плееры, которые публикуют трек.
final class SystemNowPlaying {
    typealias InfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    typealias SendFn = @convention(c) (Int32, NSDictionary?) -> Bool

    static let shared = SystemNowPlaying()
    private var infoFn: InfoFn?
    private var sendFn: SendFn?

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                             RTLD_LAZY) else { return }
        if let s = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
            infoFn = unsafeBitCast(s, to: InfoFn.self)
        }
        if let s = dlsym(h, "MRMediaRemoteSendCommand") {
            sendFn = unsafeBitCast(s, to: SendFn.self)
        }
    }

    func command(_ c: Int32) {
        _ = sendFn?(c, nil)
    }

    func fetch(_ done: @escaping (MusicTrack?) -> Void) {
        guard let fn = infoFn else { done(nil); return }
        var finished = false
        let lock = NSLock()
        let finish: (MusicTrack?) -> Void = { track in
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            lock.unlock()
            DispatchQueue.main.async { done(track) }
        }
        fn(DispatchQueue.global(qos: .utility)) { info in
            guard !info.isEmpty else { finish(nil); return }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            guard !title.isEmpty else { finish(nil); return }
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
            let elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
            let bundle = info["kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"] as? String ?? ""
            var art: NSImage?
            if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                art = NSImage(data: data)
            }
            let appName: String = {
                switch bundle {
                case "com.apple.Music": return "Music"
                case "com.spotify.client": return "Spotify"
                case "com.google.Chrome": return "Chrome"
                case "com.apple.Safari": return "Safari"
                case "com.microsoft.edgemac": return "Edge"
                case "org.mozilla.firefox": return "Firefox"
                case "com.apple.QuickTimePlayerX": return "QuickTime"
                case "io.videolan.VLC": return "VLC"
                default: return bundle.isEmpty ? "Система" : bundle
                }
            }()
            finish(MusicTrack(title: title, artist: artist, playing: rate > 0,
                              position: elapsed, duration: duration,
                              app: appName, system: true, artwork: art))
        }
        // MediaRemote иногда отвечает медленно на холодную — даём ему время
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { finish(nil) }
    }
}

final class MusicService: ObservableObject {
    static let shared = MusicService()
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var app = ""
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var artwork: NSImage?
    @Published var system = false
    @Published var browser = false
    @Published var browserBundle: String? = nil
    @Published var hint: String?
    @Published var debug = ""

    private var timer: Timer?
    private var updating = false
    private var misses = 0
    private var lastBrowserCheck = Date.distantPast
    private var cachedBrowser: MusicTrack?
    private var lastYandexCheck = Date.distantPast
    @Published var yandexDebug = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let s = NotchState.shared
            if s.expanded && (s.tab == .music || s.tab == .home) { self?.update() }
        }
    }

    /// Через отдельный процесс с таймаутом: NSAppleScript может зависнуть на запросе
    /// доступа к автоматизации, и тогда обновление музыки залипает навсегда.
    private func osa(_ src: String) -> String? {
        let result = AppleScriptRunner.run(src, timeout: 2)
        if !result.err.isEmpty { return nil }
        return result.out
    }

    func update() {
        guard !updating else { return }
        updating = true
        debug = "start"
        // AppleScript и MediaRemote не должны блокировать интерфейс чёлки
        DispatchQueue.global(qos: .utility).async {
            let appTrack = self.appTrack()
            DispatchQueue.main.async {
                self.debug += " | app=\(appTrack?.title ?? "nil")"

                // Играющий Music/Spotify/QuickTime — приоритет
                if let appTrack, appTrack.playing {
                    self.updating = false
                    self.misses = 0
                    self.apply(appTrack)
                    return
                }

                // Дальше — YouTube во вкладке, он тоже быстрый
                self.browserTrack { browserTrack in
                    if let browserTrack {
                        self.debug += " | browser=\(browserTrack.title)"
                        self.updating = false
                        self.misses = 0
                        self.apply(browserTrack)
                        return
                    }
                    self.debug += " | browser=nil"

                    // И последний шанс — системное «Сейчас играет»
                    SystemNowPlaying.shared.fetch { [weak self] systemTrack in
                        guard let self else { return }
                        self.updating = false
                        if let systemTrack {
                            self.debug += " | system=\(systemTrack.title)"
                            self.misses = 0
                            self.apply(systemTrack)
                        } else if let appTrack {
                            // Пауза в Music/QuickTime — показываем, если ничего не играет
                            self.misses = 0
                            self.apply(appTrack)
                        } else {
                            self.misses += 1
                            if self.misses >= 3 { self.clear() }
                        }
                    }
                }
            }
        }
    }

    private func appTrack() -> MusicTrack? {
        var paused: MusicTrack?
        let apps = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]
        for (bid, name) in apps where !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            guard Automation.allowed(bid) else {
                Automation.requestOnce(bid)
                let text = "Разреши управление " + name + " в Настройках → Конфиденциальность → Автоматизация"
                DispatchQueue.main.async { self.hint = text }
                continue
            }
            let script = """
            tell application "\(name)"
                set s to (player state as string)
                if s is "stopped" then return "stopped"
                return s & "||" & (name of current track) & "||" & (artist of current track) & "||" & (duration of current track as string) & "||" & (player position as string)
            end tell
            """
            guard let out = osa(script) else {
                let text = "Разреши управление " + name + " в Настройках → Конфиденциальность → Автоматизация"
                DispatchQueue.main.async { self.hint = text }
                continue
            }
            DispatchQueue.main.async { self.hint = nil }
            guard out != "stopped" else { continue }
            let p = out.components(separatedBy: "||")
            guard p.count >= 5 else { continue }
            var d = Double(p[3]) ?? 0
            if d > 10_000 { d /= 1000 }     // Spotify иногда отдаёт миллисекунды
            let track = MusicTrack(title: p[1], artist: p[2], playing: p[0] == "playing",
                                   position: Double(p[4]) ?? 0, duration: d,
                                   app: name, system: false, artwork: nil)
            if track.playing { return track }
            if paused == nil { paused = track }
        }

        // Локальное видео в QuickTime: имя документа, время и управление
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.QuickTimePlayerX").isEmpty,
           !Automation.allowed("com.apple.QuickTimePlayerX") {
            Automation.requestOnce("com.apple.QuickTimePlayerX")
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.QuickTimePlayerX").isEmpty,
           Automation.allowed("com.apple.QuickTimePlayerX") {
            let script = """
            tell application "QuickTime Player"
                if (count of documents) is 0 then return ""
                set d to document 1
                return (name of d) & "||" & ((playing of d) as string) & "||" & ((duration of d) as string) & "||" & ((current time of d) as string)
            end tell
            """
            if let out = osa(script), !out.isEmpty {
                let p = out.components(separatedBy: "||")
                if p.count >= 4 {
                    let qt = MusicTrack(title: p[0], artist: "", playing: p[1] == "true",
                                        position: Double(p[3]) ?? 0, duration: Double(p[2]) ?? 0,
                                        app: "QuickTime Player", system: false, artwork: nil)
                    if qt.playing { return qt }
                    if paused == nil { paused = qt }
                }
            }
        }
        return paused
    }

    private func mediaSite(host: String) -> String? {
        if host.contains("youtube.com") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("music.yandex") { return "Яндекс Музыка" }
        if host.contains("open.spotify") { return "Spotify" }
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("music.apple") { return "Apple Music" }
        return nil
    }

    private func mediaTrack(rawTitle: String, app: String, bundle: String) -> MusicTrack? {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" - YouTube Music", " - YouTube", " — YouTube", " | YouTube",
                        " — Яндекс Музыка", " - Яндекс Музыка", " | Яндекс Музыка",
                        " | Spotify", " - Spotify", " | SoundCloud", " - SoundCloud",
                        " | Apple Music", " - Apple Music"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            break
        }
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            let rest = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { title = rest }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        let lower = title.lowercased()
        guard !title.isEmpty,
              lower != app.lowercased(),
              !lower.hasPrefix("яндекс музыка"),
              !lower.contains("слушать музыку"),
              !lower.contains("web player") else { return nil }

        var artist = ""
        if app != "YouTube" {
            for separator in [" — ", " – ", " - "] where title.contains(separator) {
                let parts = title.components(separatedBy: separator)
                if parts.count >= 2 {
                    title = parts[0].trimmingCharacters(in: .whitespaces)
                    artist = parts.dropFirst().joined(separator: separator)
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        guard !title.isEmpty else { return nil }
        return MusicTrack(title: title, artist: artist, playing: true, position: 0, duration: 0,
                          app: app, system: false, artwork: nil, browser: true,
                          browserBundle: bundle)
    }

    private func youtubeTitle(_ raw: String) -> String? {
        let markers = [" - YouTube Music", " - YouTube", " — YouTube", " | YouTube"]
        guard let marker = markers.first(where: { raw.hasSuffix($0) }) else { return nil }
        var title = String(raw.dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            let rest = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { title = rest }
        }
        return title.isEmpty ? nil : title
    }

    /// YouTube во вкладке браузера: у него нет AppleScript-плеера, зато есть заголовок вкладки.
    private func browserTrack(_ done: @escaping (MusicTrack?) -> Void) {
        // Не дёргаем AppleScript каждые 1,5 с: браузерные вкладки проверяем реже
        // Между проверками показываем последний найденный трек, а не мигаем пустотой
        guard Date().timeIntervalSince(lastBrowserCheck) > 4 else { done(cachedBrowser); return }
        lastBrowserCheck = Date()
        let browsers = [("com.google.Chrome", "Google Chrome", false),
                        ("com.apple.Safari", "Safari", true),
                        ("com.microsoft.edgemac", "Microsoft Edge", false),
                        ("com.brave.Browser", "Brave Browser", false)]
        DispatchQueue.global(qos: .utility).async {
            for (bid, name, isSafari) in browsers {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty else { continue }
                guard Automation.allowed(bid) else { continue }
                let script: String
                if isSafari {
                    script = """
                    tell application "Safari"
                        if (count of windows) is 0 then return ""
                        set t to name of current tab of front window
                        set u to URL of current tab of front window
                        return t & "||" & u
                    end tell
                    """
                } else {
                    // без интерполяции: подставляем имя приложения заменой
                    script = """
                    tell application "@APP@"
                        if (count of windows) is 0 then return ""
                        set t to title of active tab of front window
                        set u to URL of active tab of front window
                        return t & "||" & u
                    end tell
                    """.replacingOccurrences(of: "@APP@", with: name)
                }
                let result = AppleScriptRunner.run(script)
                let out = result.out
                guard !out.isEmpty else {
                    if !result.err.isEmpty {
                        DispatchQueue.main.async {
                            self.hint = "Браузер не отдаёт вкладку: разреши автоматизацию в Настройках → Конфиденциальность → Автоматизация"
                        }
                    }
                    continue
                }
                let parts = out.components(separatedBy: "||")
                guard parts.count >= 2, let url = URL(string: parts[1]) else { continue }
                let host = (url.host ?? "").lowercased()
                guard let app = self.mediaSite(host: host) else { continue }
                let appName = (app == "YouTube" && host.contains("music.youtube")) ? "YouTube Music" : app
                guard let track = self.mediaTrack(rawTitle: parts[0], app: appName, bundle: bid) else { continue }
                self.cachedBrowser = track
                DispatchQueue.main.async { done(track) }
                return
            }
            // Яндекс Музыка: берём заголовок окна (Electron часто пишет туда трек)
            if let yandex = self.yandexTrack() {
                self.cachedBrowser = yandex
                DispatchQueue.main.async { done(yandex) }
                return
            }

            // Firefox: вкладок не отдаёт, но отдаёт заголовки окон
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "org.mozilla.firefox").isEmpty {
                if Automation.allowed("org.mozilla.firefox") {
                    let script = """
                    tell application "Firefox"
                        repeat with w in windows
                            set n to name of w
                            if n contains "YouTube" or n contains "Яндекс Музыка" or n contains "Spotify" then return n
                        end repeat
                        return ""
                    end tell
                    """
                    let out = AppleScriptRunner.run(script, timeout: 3).out
                    if !out.isEmpty {
                        let app = out.contains("Яндекс Музыка") ? "Яндекс Музыка"
                            : (out.contains("Spotify") ? "Spotify" : "YouTube")
                        if let track = self.mediaTrack(rawTitle: out, app: app,
                                                       bundle: "org.mozilla.firefox") {
                            self.cachedBrowser = track
                            DispatchQueue.main.async { done(track) }
                            return
                        }
                    }
                } else {
                    Automation.requestOnce("org.mozilla.firefox")
                }
            }

            if let title = AXWindow.title(bundleID: "org.mozilla.firefox"),
               let clean = self.youtubeTitle(title) {
                let track = MusicTrack(title: clean, artist: "", playing: true,
                                       position: 0, duration: 0, app: "Firefox",
                                       system: false, artwork: nil, browser: true,
                                       browserBundle: "org.mozilla.firefox")
                DispatchQueue.main.async { done(track) }
                return
            }
            self.cachedBrowser = nil
            DispatchQueue.main.async { done(nil) }
        }
    }

    private func yandexTrack() -> MusicTrack? {
        let bundle = "ru.yandex.desktop.music"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
            yandexDebug = "not running"
            return nil
        }
        guard Date().timeIntervalSince(lastYandexCheck) > 4 else { return nil }
        lastYandexCheck = Date()

        let script = """
        tell application "Яндекс Музыка"
            if (count of windows) is 0 then return ""
            return name of window 1
        end tell
        """
        let out = AppleScriptRunner.run(script, timeout: 2).out
        yandexDebug = out.isEmpty ? "no window title" : out

        var title = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.lowercased().hasPrefix("яндекс музыка") {
            // Название трека Яндекс наружу не отдаёт, но в логе есть PLAYER_STATE.
            // Показываем хотя бы факт воспроизведения, чтобы раздел не пустовал.
            if self.yandexPlayingFromLog() {
                return MusicTrack(title: "Яндекс Музыка", artist: "играет",
                                  playing: true, position: 0, duration: 0,
                                  app: "Яндекс Музыка", system: false, artwork: nil,
                                  browser: true, browserBundle: bundle)
            }
            return nil
        }
        let lower = title.lowercased()
        guard !lower.hasPrefix("яндекс музыка"), lower != "yandex music" else { return nil }

        var artist = ""
        for separator in [" — ", " – ", " - ", " · "] where title.contains(separator) {
            let parts = title.components(separatedBy: separator)
            if parts.count >= 2 {
                title = parts[0].trimmingCharacters(in: .whitespaces)
                artist = parts.dropFirst().joined(separator: separator)
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !title.isEmpty else { return nil }
        return MusicTrack(title: title, artist: artist, playing: true,
                          position: 0, duration: 0, app: "Яндекс Музыка",
                          system: false, artwork: nil, browser: true,
                          browserBundle: bundle)
    }

    /// PLAYER_STATE в логе Яндекса: true — играет, false — пауза.
    private func yandexPlayingFromLog() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/YandexMusic/main.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > 16_384 ? size - 16_384 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.contains("PLAYER_STATE") }) else {
            return false
        }
        yandexDebug = String(line.suffix(80))
        return line.contains("true")
    }

    private func apply(_ t: MusicTrack) {
        title = t.title
        artist = t.artist
        playing = t.playing
        app = t.app
        position = t.position
        duration = t.duration
        artwork = t.artwork
        system = t.system
        browser = t.browser
        browserBundle = t.browserBundle
    }

    private func clear() {
        misses = 0
        if title.isEmpty { return }
        title = ""; artist = ""; playing = false; app = ""
        position = 0; duration = 0; artwork = nil; system = false; browser = false
        browserBundle = nil
    }

    func command(_ cmd: String) {
        if browser {
            // Firefox не даёт управлять видео снаружи: любые клавиши требуют
            // активации браузера, а этого делать нельзя — фокус остаётся у тебя.
            if browserBundle == "org.mozilla.firefox" || browserBundle == "ru.yandex.desktop.music" {
                hint = "Управление — в самом плеере"
                return
            }
            let js: String
            switch cmd {
            case "playpause":
                js = "var v=document.querySelector('video'); if(v){ if(v.paused){v.play()}else{v.pause()} }"
            case "next track":
                js = "var v=document.querySelector('video'); if(v){ v.currentTime=Math.min(v.duration||1e9,v.currentTime+10) }"
            case "previous track":
                js = "var v=document.querySelector('video'); if(v){ v.currentTime=Math.max(0,v.currentTime-10) }"
            default:
                return
            }
            if !runBrowserJS(js) {
                hint = "Для кнопок включи «Allow JavaScript from Apple Events» в браузере"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.update() }
            return
        }

        if app == "QuickTime Player" {
            let script: String
            switch cmd {
            case "playpause":
                script = playing
                    ? "tell application \"QuickTime Player\" to pause document 1"
                    : "tell application \"QuickTime Player\" to play document 1"
            case "next track":
                script = "tell application \"QuickTime Player\" to step forward 5"
            case "previous track":
                script = "tell application \"QuickTime Player\" to step backward 5"
            default:
                return
            }
            _ = osa(script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.update() }
            return
        }

        if system || app.isEmpty {
            switch cmd {
            case "next track": SystemNowPlaying.shared.command(4)
            case "previous track": SystemNowPlaying.shared.command(5)
            default: SystemNowPlaying.shared.command(2)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.update() }
            return
        }
        _ = osa("tell application \"" + app + "\" to " + cmd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.update() }
    }

    /// Управление видео в активной вкладке Chrome/Safari через JavaScript.
    private func runBrowserJS(_ js: String) -> Bool {
        guard let bundle = browserBundle else { return false }
        // Firefox не умеет JavaScript через AppleScript — и уж точно не надо
        // в этом случае дёргать Chrome (иначе он запускается и перехватывает экран).
        let chromium = bundle.contains("Chrome") || bundle.contains("edgemac") || bundle.contains("brave")
        guard bundle == "com.apple.Safari" || chromium else { return false }
        let q = String(UnicodeScalar(34))
        let script: String
        if bundle == "com.apple.Safari" {
            script = "tell application " + q + "Safari" + q
                + " to do JavaScript " + q + js + q + " in current tab of front window"
        } else {
            let name = bundle.contains("edgemac") ? "Microsoft Edge"
                : (bundle.contains("brave") ? "Brave Browser" : "Google Chrome")
            script = "tell application " + q + name + q
                + " to execute active tab of front window javascript " + q + js + q
        }
        return AppleScriptRunner.run(script, timeout: 2).err.isEmpty
    }

    func open(_ name: String) {
        let url = URL(fileURLWithPath: "/Applications/\(name).app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Музыка (вкладка и окно)

struct MusicView: View {
    @ObservedObject var m = MusicService.shared

    var body: some View {
        GlassCard(padding: 16) {
            Group {
                if m.title.isEmpty { emptyState } else { player }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { m.update() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            m.update()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("Ничего не играет")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Music, Spotify или видео в браузере — включи и вернись, трек подхватится сам")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                Button("Music") { m.open("Music") }
                Button("Spotify") { m.open("Spotify") }
                Button("Яндекс Музыка") { m.open("Яндекс Музыка") }
                Button("Обновить") { m.update() }
            }
            .controlSize(.small)
            Text("YouTube берётся из активной вкладки Chrome/Safari. Нет видео? Настройки → Конфиденциальность → Автоматизация → NotchApp")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let hint = m.hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var player: some View {
        HStack(alignment: .top, spacing: 16) {
            artworkTile
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(m.app)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    Spacer()
                    if m.browser {
                        Text("из вкладки браузера")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                    } else if m.system {
                        Text("из системы")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                    }
                }
                Text(m.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(m.artist.isEmpty ? (m.browser ? "вкладка браузера" : "—") : m.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                if let hint = m.hint {
                    Text(hint)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.orange)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if m.duration > 0 {
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(Theme.accentSoft)
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(timeText(m.position)).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
                            Spacer()
                            Text(timeText(m.duration)).font(.system(size: 9.5)).foregroundStyle(Theme.faint)
                        }
                    }
                }

                if m.browserBundle == "org.mozilla.firefox" || m.browserBundle == "ru.yandex.desktop.music" {
                    Text("Управление — в самом плеере")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                } else {
                    HStack(spacing: 24) {
                        Spacer()
                        Button { m.command("previous track") } label: {
                            Image(systemName: m.browser ? "gobackward.10" : "backward.fill")
                                .font(.system(size: 16))
                        }
                        Button { m.command("playpause") } label: {
                            Image(systemName: m.browser ? "playpause.fill"
                                  : (m.playing ? "pause.circle.fill" : "play.circle.fill"))
                                .font(.system(size: m.browser ? 26 : 34))
                                .foregroundStyle(Theme.text)
                        }
                        Button { m.command("next track") } label: {
                            Image(systemName: m.browser ? "goforward.10" : "forward.fill")
                                .font(.system(size: 16))
                        }
                        Spacer()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)

                    if m.browser {
                        Text("±10 с и пауза — через вкладку " + m.app)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var artworkTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.6), Color.purple.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let art = m.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: m.playing ? "waveform" : "music.note")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private var progress: CGFloat {
        guard m.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, m.position / m.duration)))
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Календарь (EventKit)

final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    private let store = EKEventStore()
    @Published var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var events: [EKEvent] = []

    func request() {
        store.requestFullAccessToEvents { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.authorized = ok
                if ok { self?.load(month: Date()) }
            }
        }
    }

    func load(month: Date) {
        guard authorized else { return }
        let c = Calendar.current
        guard let start = c.date(from: c.dateComponents([.year, .month], from: month)),
              let end = c.date(byAdding: .month, value: 1, to: start) else { return }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
    }

    func events(on day: Date) -> [EKEvent] {
        events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }
}

struct CalendarView: View {
    @ObservedObject var cal = CalendarService.shared
    @State private var month = Date()
    @State private var selected = Date()

    private var c: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var gridDays: [Date?] {
        guard let start = c.date(from: c.dateComponents([.year, .month], from: month)),
              let range = c.range(of: .day, in: .month, for: start) else { return [] }
        let weekday = c.component(.weekday, from: start)
        let lead = (weekday - c.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in range { out.append(c.date(byAdding: .day, value: d - 1, to: start)) }
        return out
    }

    private var weekdaySymbols: [String] {
        let s = c.veryShortStandaloneWeekdaySymbols
        return Array(s[1...]) + [s[0]]
    }

    var body: some View {
        if !cal.authorized {
            GlassCard {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.faint)
                    Text("Нужен доступ к Календарю").foregroundStyle(Theme.dim)
                    Button("Разрешить") { cal.request() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GlassCard(padding: 14) {
                HStack(alignment: .top, spacing: 18) {
                    calendarGrid
                        .frame(width: 250)
                    Divider().overlay(Theme.stroke)
                    dayList
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear { cal.load(month: month) }
            .onChange(of: month) { _, m in cal.load(month: m) }
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: 6) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7), spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 9)).foregroundStyle(Theme.faint)
                }
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 28) }
                }
            }
        }
    }

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selected.formatted(.dateTime.day().month(.wide).weekday(.wide)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            let list = cal.events(on: selected)
            if list.isEmpty {
                Text("Событий нет").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(list, id: \.self) { e in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: e.calendar.color))
                                    .frame(width: 2.5, height: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.isAllDay ? "весь день"
                                         : e.startDate.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9)).foregroundStyle(Theme.faint)
                                    Text(e.title ?? "").font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shift(_ by: Int) {
        if let m = c.date(byAdding: .month, value: by, to: month) { month = m }
    }

    private func dayCell(_ d: Date) -> some View {
        let isSel = c.isDate(d, inSameDayAs: selected)
        let isToday = c.isDateInToday(d)
        let has = !cal.events(on: d).isEmpty
        return Button { selected = d } label: {
            VStack(spacing: 1) {
                Text("\(c.component(.day, from: d))")
                    .font(.system(size: 11))
                    .foregroundStyle(isSel ? Color.black : Theme.text)
                Circle().fill(has ? Theme.orange : Color.clear).frame(width: 3.5, height: 3.5)
            }
            .frame(width: 32, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSel ? Color.white.opacity(0.9)
                            : (isToday ? Theme.accent.opacity(0.25) : Color.clear)))
        }
        .buttonStyle(.plain)
    }
}
