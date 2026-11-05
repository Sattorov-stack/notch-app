import AppKit
import SwiftUI
import Combine
import QuartzCore

final class NotchPanel: NSPanel {
    // Нужно, чтобы в панели работали поля ввода
    override var canBecomeKey: Bool { true }

    // Клик делает окно ключевым ДО обработки нажатия: иначе первое нажатие
    // в текстовое поле теряется и ⌘V/ввод не работают.
    override func mouseDown(with event: NSEvent) {
        // nonactivating-панель становится key без захвата меню-бара —
        // так в поля можно печатать и вставлять ⌘V, не уводя фокус из чужого приложения.
        makeKey()
        if !isKeyWindow {
            // страховка на случай, если система не отдала key неактивному приложению
            NSApp.activate(ignoringOtherApps: true)
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
            .sink { [weak self] _ in
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
        collapsedRect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)

        let ew = NotchLayout.expandedWidth, eh = state.tab.panelHeight
        expandedRect = NSRect(x: f.midX - ew / 2, y: f.maxY - eh, width: ew, height: eh)

        let aw = max(w + 300, 560), ah = h + 58
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
        if keep.contains(m) { outsideSince = nil; return }

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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "Чёлка")
        let menu = NSMenu()

        let open = NSMenuItem(title: "Показать меню", action: #selector(showMenu), keyEquivalent: "")
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)    // без иконки в Dock

ClipboardStore.shared.start()
MusicService.shared.start()
AgentHub.shared.start()
SleepGuard.shared.refresh()

let controller = NotchController()

_ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                           object: nil, queue: .main) { _ in
    KeyboardLock.shared.unlock()
    SleepGuard.shared.cleanupOnQuit()
}

app.run()
