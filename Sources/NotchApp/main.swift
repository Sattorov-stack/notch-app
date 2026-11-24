import AppKit
import SwiftUI
import Combine
import QuartzCore
import CoreGraphics
import Carbon.HIToolbox

final class NotchPanel: NSPanel {
    // Нужно, чтобы в панели работали поля ввода
    override var canBecomeKey: Bool { true }

    // ⌘C/⌘V/⌘X/⌘A/⌘Z — у фонового приложения нет меню «Правка», доставляем сами
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditShortcuts.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // Клик делает окно ключевым ДО обработки нажатия: иначе первое нажатие
    // в текстовое поле теряется и ⌘V/ввод не работают.
    override func mouseDown(with event: NSEvent) {
        // nonactivating-панель становится key без захвата меню-бара —
        // так в поля можно печатать и вставлять ⌘V, не уводя фокус из чужого приложения.
        makeKey()
        if !isKeyWindow {
            // страховка на случай, если система не отдала key неактивному приложению
            NSApp.activate()
            makeKey()
        }
        super.mouseDown(with: event)
    }
}

final class NotchController: NSObject {
    let state = NotchState.shared
    let panel: NotchPanel

    private var collapsedRect = NSRect.zero
    private var expandedRect = NSRect.zero
    private var alertRect = NSRect.zero
    private var outsideSince: Date?
    private var insideSince: Date?
    private var seenDragCount = NSPasteboard(name: .drag).changeCount
    private var timer: Timer?
    private var wasDown = false
    private var bag = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var openedByKeyboard = false
    static weak var current: NotchController?

    /// Открывает панель на нужном разделе, снимает её как есть и закрывает обратно
    /// Снимок уведомления — для проверки вида
    func captureAlert() {
        if state.expanded { setExpanded(false) }
        state.showAlert(AlertItem(emoji: "🖥️", title: "my", text: "n8n — остановлен", kind: .error))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let v = self.panel.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notch-live-alert.png"))
            }
            self.state.dismissAlert()
        }
    }

    func captureLive(_ tab: Tab) {
        state.tab = tab
        openedByKeyboard = true
        if !state.expanded { setExpanded(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let v = self.panel.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notch-live-\(tab.rawValue).png")
                try? png.write(to: url)
            }
            self.setExpanded(false)
        }
    }
    private var monitors: [Any] = []

    override init() {
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none          // чёлка и суфлёр не видны в записи и на демонстрации
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false

        let host = NSHostingView(rootView: NotchView())
        host.sizingOptions = []            // размер окна задаём сами, SwiftUI его не тянет
        panel.contentView = host

        layout()
        panel.setFrame(collapsedRect, display: true)
        panel.orderFrontRegardless()

        state.onExpandRequest = { [weak self] v in self?.setExpanded(v) }
        state.$alert
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.alertChanged() }
            .store(in: &bag)

        // У каждого раздела своя высота — пересчитываем рамку при переключении
        state.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in
                guard let self else { return }
                self.layout()
                if self.state.expanded { self.applyFrame(animate: true) }
            }
            .store(in: &bag)

        // Подключили/отключили монитор или поменяли разрешение — пересчитываем положение
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.layout()
            self?.applyFrame(animate: false)
        }

        // Опрос мыши вместо mouseExited: событие выхода теряется при быстром движении,
        // из-за этого меню «залипает».
        let t = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        setupStatusItem()
        setupHotKeys()
        NotchController.current = self
        setupMonitors()
    }

    private func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        var w: CGFloat = 220, h: CGFloat = 32
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            h = screen.safeAreaInsets.top
            w = f.width - l.width - r.width
        }
        if h < 24 { h = 32 }
        state.notchH = h
        state.notchW = w
        collapsedRect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)

        let ew = NotchLayout.expandedWidth, eh = state.tab.panelHeight
        expandedRect = NSRect(x: f.midX - ew / 2, y: f.maxY - eh, width: ew, height: eh)

        // Уведомление — только полоса по бокам от чёлки, ниже чёлки не опускается
        let aw = w + 2 * 170, ah = h
        alertRect = NSRect(x: f.midX - aw / 2, y: f.maxY - ah, width: aw, height: ah)
    }

    private func fileDragActive(_ leftDown: Bool) -> Bool {
        guard leftDown else { return false }
        let pb = NSPasteboard(name: .drag)
        return pb.changeCount != seenDragCount && (pb.types?.contains(.fileURL) ?? false)
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        let leftDown = NSEvent.pressedMouseButtons & 1 == 1

        // Клик по панели делает приложение активным — иначе поле ввода
        // не получает клавиатуру (⌘V, стрелки, ввод) на неактивном приложении.
        if leftDown && !wasDown && !fileDragActive(true) {
            let area = state.expanded ? expandedRect : (state.alert != nil ? alertRect : collapsedRect)
            if area.contains(m) && !panel.isKeyWindow {
                panel.makeKey()
            }
        }
        wasDown = leftDown

        if !leftDown { seenDragCount = NSPasteboard(name: .drag).changeCount }

        if !state.expanded {
            let base = state.alert != nil ? alertRect : collapsedRect
            let hot = NSRect(x: base.minX - 10, y: base.minY - 5,
                             width: base.width + 20, height: base.height + 10)
            guard hot.contains(m) else { insideSince = nil; return }

            let fileDrag = fileDragActive(leftDown)
            if fileDrag {
                state.tab = .shelf
                setExpanded(true)
                return
            }
            if leftDown { insideSince = nil; return }      // тащат окно или выделяют — не мешаем

            // Небольшая задержка, чтобы меню не выскакивало, когда мышь просто проходит мимо
            let start = insideSince ?? Date()
            insideSince = start
            if Date().timeIntervalSince(start) >= 0.10 { setExpanded(true) }
            return
        }

        insideSince = nil
        if state.pinned || leftDown { outsideSince = nil; return }

        let keep = expandedRect.insetBy(dx: -6, dy: -4)
        if keep.contains(m) { openedByKeyboard = false; outsideSince = nil; return }
        // Открыто горячей клавишей: не закрываем, пока мышь не побывала в меню.
        // Закрыть: Esc, ⌃⌥N или клик мимо.
        if openedByKeyboard { outsideSince = nil; return }

        // Если курсор в поле ввода — даём чуть больше времени, но меню всё равно закроется
        let typing = panel.isKeyWindow && panel.firstResponder is NSTextView
        let grace: TimeInterval = typing ? 1.0 : 0.22
        let start = outsideSince ?? Date()
        outsideSince = start
        if Date().timeIntervalSince(start) > grace { setExpanded(false) }
    }

    func setExpanded(_ v: Bool) {
        outsideSince = nil
        insideSince = nil
        if !v {
            openedByKeyboard = false
            panel.makeFirstResponder(nil)
        }
        state.expanded = v
        if v { MusicService.shared.update() }
        applyFrame(animate: true)
    }

    private func alertChanged() {
        guard !state.expanded else { return }
        applyFrame(animate: true)
    }

    private func applyFrame(animate: Bool) {
        let target = state.expanded ? expandedRect : (state.alert != nil ? alertRect : collapsedRect)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// ⌃⌥N: открыть меню с клавиатуры (и сразу печатать в поле) или закрыть его.
    func toggleByHotkey() {
        if state.expanded { setExpanded(false); return }
        openedByKeyboard = true
        setExpanded(true)
        panel.makeKey()
    }

    private func setupHotKeys() {
        let mods = controlKey | optionKey
        HotKeys.shared.register(id: 1, keyCode: kVK_ANSI_N, modifiers: mods) { [weak self] in
            self?.toggleByHotkey()
        }
        HotKeys.shared.register(id: 2, keyCode: kVK_ANSI_T, modifiers: mods) {
            RecognizeService.shared.screenshot()
        }
        HotKeys.shared.register(id: 3, keyCode: kVK_ANSI_C, modifiers: mods) {
            ColorPickService.shared.pick()
        }
        HotKeys.shared.register(id: 5, keyCode: kVK_ANSI_M, modifiers: mods) {
            CameraMirror.shared.toggle()
        }
        // Раскладки активного окна: ⌃⌥← левая половина, ⌃⌥→ правая, ⌃⌥↑ весь экран, ⌃⌥↓ по центру
        let snaps: [(UInt32, Int, Int, Int)] = [(6, kVK_LeftArrow, 1, 0), (7, kVK_RightArrow, 1, 1),
                                                 (8, kVK_UpArrow, 0, 0), (9, kVK_DownArrow, 7, 0)]
        for (id, key, layout, zone) in snaps {
            HotKeys.shared.register(id: id, keyCode: key, modifiers: mods) {
                SnapController.shared.snapFrontmost(layout: layout, zone: zone, assist: false)
            }
        }
    }

    private func setupMonitors() {
        // Клик мимо меню в другом приложении — меню сразу закрывается
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.state.expanded, !self.state.pinned else { return }
            if !self.expandedRect.contains(NSEvent.mouseLocation) { self.setExpanded(false) }
        }) { monitors.append(g) }

        // Esc — закрыть меню; ⌘1…⌘0 — первые десять разделов
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.state.expanded, e.window === self.panel else { return e }
            if EditShortcuts.handle(e, in: self.panel) { return nil }   // ⌘V и др. в любой раскладке
            if e.keyCode == UInt16(kVK_Escape) { self.setExpanded(false); return nil }
            if e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers, let n = Int(ch) {
                let tabs = Tab.allCases
                let i = n == 0 ? 9 : n - 1
                if i < tabs.count { self.state.tab = tabs[i]; return nil }
            }
            return e
        }) { monitors.append(l) }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "Чёлка")
        let menu = NSMenu()

        let open = NSMenuItem(title: "Показать меню   ⌃⌥N", action: #selector(showMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        for tab in [Tab.home, .music, .notes, .clipboard, .pets] {
            let mi = NSMenuItem(title: "\(tab.title) в окне", action: #selector(openWindow(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = tab.rawValue
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из NotchApp",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    @objc private func showMenu() {
        state.tab = .home
        setExpanded(true)
    }

    @objc private func openWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = Tab(rawValue: raw) else { return }
        SectionWindows.shared.open(tab)
    }
}

// MARK: - Запуск

// Самопроверка проверки интернета: NotchApp --selftest-net [--live]
if CommandLine.arguments.contains("--selftest-net") {
    exit(NetSelfTest.run() ? 0 : 1)
}

// Диагностика разрешения «Запись экрана»: NotchApp --selftest-screen
if CommandLine.arguments.contains("--selftest-screen") || CommandLine.arguments.contains("--request-screen") {
    if CommandLine.arguments.contains("--request-screen") { CGRequestScreenCaptureAccess() }
    print(CGPreflightScreenCaptureAccess() ? "Запись экрана: разрешена" : "Запись экрана: НЕ разрешена")
    exit(0)
}

// Самопроверка переводчика: NotchApp --selftest-translate
if CommandLine.arguments.contains("--selftest-translate") || CommandLine.arguments.contains("--selftest-ai") {
    Task {
        let ok = CommandLine.arguments.contains("--selftest-ai") ? await AISelfTest.run() : await TranslateSelfTest.run()
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)    // без иконки в Dock

// Запись в закрытый канал помощника не должна ронять приложение
signal(SIGPIPE, SIG_IGN)

// Вторая копия не нужна: если уже запущена — тихо выходим (код 0, launchd её не перезапустит)
if let bid = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bid)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

ClipboardStore.shared.start()
MusicService.shared.start()
AgentHub.shared.start()
SleepGuard.shared.refresh()
SystemNowPlaying.shared.start()
SystemMonitor.shared.start()
InternetWatch.shared.start()
ServersService.shared.start()
SnapController.shared.start()
BackupMonitor.shared.start()

let controller = NotchController()

_ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                           object: nil, queue: .main) { _ in
    KeyboardLock.shared.unlock()
    SleepGuard.shared.cleanupOnQuit()
}

app.run()
