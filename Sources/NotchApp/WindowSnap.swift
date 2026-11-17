import AppKit
import SwiftUI

// MARK: - Раскладки окон

struct SnapLayout: Identifiable {
    let id: Int
    let name: String
    let zones: [CGRect]          // доли экрана, начало — левый верхний угол
}

enum SnapLayouts {
    static let all: [SnapLayout] = [
        SnapLayout(id: 0, name: "Весь экран", zones: [CGRect(x: 0, y: 0, width: 1, height: 1)]),
        SnapLayout(id: 1, name: "Половины", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]),
        SnapLayout(id: 2, name: "Три колонки", zones: [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1),
            CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)]),
        SnapLayout(id: 3, name: "2/3 + 1/3", zones: [
            CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1), CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)]),
        SnapLayout(id: 4, name: "1/3 + 2/3", zones: [
            CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1), CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)]),
        SnapLayout(id: 5, name: "Большое + два", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
        SnapLayout(id: 6, name: "Четверти", zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
        SnapLayout(id: 7, name: "По центру", zones: [CGRect(x: 0.15, y: 0.08, width: 0.7, height: 0.84)]),
    ]
}

struct WinInfo: Identifiable {
    let id = UUID()
    let element: AXUIElement
    let app: NSRunningApplication
    let title: String
}

// MARK: - Работа с окнами других приложений (через «Универсальный доступ»)

enum AXHelp {
    private static var primaryH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Координаты Cocoa (снизу вверх) → координаты окон (сверху вниз)
    static func toAX(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryH - p.y) }
    static func toCocoa(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func bool(_ e: AXUIElement, _ name: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(e, &p)
        return p
    }

    /// Окно под точкой (координаты окон)
    static func window(at p: CGPoint) -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, var e = el else { return nil }
        for _ in 0..<15 {
            if string(e, kAXRoleAttribute) == (kAXWindowRole as String) { return e }
            if let w = element(e, kAXWindowAttribute) { return w }
            guard let parent = element(e, kAXParentAttribute) else { break }
            e = parent
        }
        return nil
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Ставим позицию, размер и ещё раз позицию — иначе некоторые программы «отскакивают»
    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
    }

    static func focusedWindow(fallback: NSRunningApplication?) -> AXUIElement? {
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == getpid() { app = fallback }
        guard let app, app.processIdentifier != getpid() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        return element(ax, kAXFocusedWindowAttribute) ?? element(ax, kAXMainWindowAttribute)
    }

    /// Обычные открытые окна обычных программ (без свёрнутых и служебных)
    static func windows() -> [WinInfo] {
        var out: [WinInfo] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
                  let arr = v as? [AnyObject] else { continue }
            for obj in arr {
                let w = obj as! AXUIElement
                if bool(w, kAXMinimizedAttribute) == true { continue }
                if string(w, kAXSubroleAttribute) != (kAXStandardWindowSubrole as String) { continue }
                if let f = frame(w), f.width < 120 || f.height < 80 { continue }
                out.append(WinInfo(element: w, app: app, title: string(w, kAXTitleAttribute) ?? ""))
                if out.count >= 16 { return out }
            }
        }
        return out
    }

    static func raise(_ w: WinInfo) {
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        w.app.activate()
    }
}

// MARK: - Управление раскладками

final class SnapController: ObservableObject {
    static let shared = SnapController()

    @Published var hoveredLayout: Int?
    @Published var hoveredZone: Int?
    @Published var assistItems: [WinInfo] = []
    @Published var assistText = ""

    // размеры панели раскладок — по ним же определяем, над какой ячейкой курсор
    static let tileW: CGFloat = 92, tileH: CGFloat = 58, gap: CGFloat = 10, pad: CGFloat = 12, labelH: CGFloat = 16

    private var monitors: [Any] = []
    private var candidate: AXUIElement?
    private var startFrame: CGRect?
    private var moving = false
    private var downPoint = NSPoint.zero
    private var picker: NSPanel?
    private var preview: NSPanel?
    private var assist: NSPanel?
    private var pendingZones: [CGRect] = []
    private var assistScreen: NSScreen?
    private var placed: [AXUIElement] = []
    private var lastApp: NSRunningApplication?

    func start() {
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in self?.mouseDown() }),
            (.leftMouseDragged, { [weak self] _ in self?.mouseDragged() }),
            (.leftMouseUp, { [weak self] _ in self?.mouseUp() })
        ]
        for (mask, handler) in events {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
        }
        // Помним последнее «чужое» приложение — чтобы кнопки раскладок работали и из окна чёлки
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != getpid() { self?.lastApp = app }
        }
    }

    // MARK: Перетаскивание окна к чёлке

    private func mouseDown() {
        candidate = nil
        moving = false
        if let a = assist, !a.frame.contains(NSEvent.mouseLocation) { closeAssist() }
        guard AXIsProcessTrusted() else { return }
        let p = NSEvent.mouseLocation
        downPoint = p
        guard let w = AXHelp.window(at: AXHelp.toAX(p)), AXHelp.pid(w) != getpid() else { return }
        candidate = w
        startFrame = AXHelp.frame(w)
    }

    private func mouseDragged() {
        guard let w = candidate else { return }
        let p = NSEvent.mouseLocation
        if !moving {
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 8 else { return }
            // Окно действительно едет за мышью — значит, его тащат за заголовок, а не выделяют текст
            guard let f0 = startFrame, let f = AXHelp.frame(w), f.origin != f0.origin else { return }
            moving = true
        }
        let screen = Self.screen(at: p)
        if picker == nil {
            let nearNotch = p.y > screen.frame.maxY - 60 && abs(p.x - screen.frame.midX) < 320
            if nearNotch { showPicker(on: screen) }
            return
        }
        guard let pk = picker else { return }
        if p.y < pk.frame.minY - 160 { hidePicker(); return }       // увёл окно вниз — передумал
        let hit = hitTest(p, in: pk.frame)
        if hit?.0 != hoveredLayout || hit?.1 != hoveredZone {
            hoveredLayout = hit?.0
            hoveredZone = hit?.1
            updatePreview(on: screen)
        }
    }

    private func mouseUp() {
        defer { candidate = nil; moving = false }
        guard let w = candidate, picker != nil else { return }
        let li = hoveredLayout, zi = hoveredZone
        let screen = Self.screen(at: NSEvent.mouseLocation)
        hidePicker()
        guard let li, let zi else { return }
        let layout = SnapLayouts.all[li]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.place(w, layout.zones[zi], on: screen)
            self.beginAssist(layout: layout, used: zi, first: w, screen: screen)
        }
    }

    private func hitTest(_ p: NSPoint, in f: NSRect) -> (Int, Int)? {
        let lx = p.x - f.minX - Self.pad
        let ly = f.maxY - p.y - Self.pad
        guard lx >= 0, ly >= 0, ly <= Self.tileH else { return nil }
        let step = Self.tileW + Self.gap
        let i = Int(lx / step)
        let inX = lx - CGFloat(i) * step
        guard i < SnapLayouts.all.count, inX <= Self.tileW else { return nil }
        let pt = CGPoint(x: inX / Self.tileW, y: ly / Self.tileH)
        guard let z = SnapLayouts.all[i].zones.firstIndex(where: { $0.insetBy(dx: -0.001, dy: -0.001).contains(pt) })
        else { return nil }
        return (i, z)
    }

    private func showPicker(on screen: NSScreen) {
        let n = CGFloat(SnapLayouts.all.count)
        let w = Self.pad * 2 + n * Self.tileW + (n - 1) * Self.gap
        let h = Self.pad * 2 + Self.tileH + Self.labelH
        let top = screen.frame.maxY - max(NotchState.shared.notchH, 24) - 6
        let rect = NSRect(x: screen.frame.midX - w / 2, y: top - h, width: w, height: h)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: SnapPickerView())
        host.sizingOptions = []
        p.contentView = host
        p.orderFrontRegardless()
        hoveredLayout = nil
        hoveredZone = nil
        picker = p
    }

    private func hidePicker() {
        picker?.orderOut(nil)
        picker = nil
        preview?.orderOut(nil)
        hoveredLayout = nil
        hoveredZone = nil
    }

    /// Полупрозрачная подсказка: куда встанет окно
    private func updatePreview(on screen: NSScreen) {
        guard let li = hoveredLayout, let zi = hoveredZone else { preview?.orderOut(nil); return }
        showPreview(AXHelp.toCocoa(Self.axFrame(SnapLayouts.all[li].zones[zi], on: screen)))
    }

    private func showPreview(_ r: NSRect) {
        if preview == nil {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            v.layer?.borderWidth = 2
            v.layer?.cornerRadius = 12
            p.contentView = v
            preview = p
        }
        preview?.setFrame(r.insetBy(dx: 4, dy: 4), display: true)
        preview?.orderFrontRegardless()
    }

    // MARK: Заполнение остальных мест (как Snap Assist в Windows)

    func beginAssist(layout: SnapLayout, used: Int, first: AXUIElement, screen: NSScreen) {
        var rest = layout.zones
        rest.remove(at: used)
        guard !rest.isEmpty else { return }
        pendingZones = rest
        assistScreen = screen
        placed = [first]
        refreshAssist()
    }

    private func refreshAssist() {
        guard let screen = assistScreen, let zone = pendingZones.first else { closeAssist(); return }
        assistItems = AXHelp.windows().filter { info in !placed.contains { CFEqual($0, info.element) } }
        assistText = "Какое окно поставить сюда? Осталось мест: \(pendingZones.count)"
        if assistItems.isEmpty { closeAssist(); return }
        let z = AXHelp.toCocoa(Self.axFrame(zone, on: screen))
        let w = min(340, z.width - 20), h = min(300, z.height - 20)
        let rect = NSRect(x: z.midX - w / 2, y: z.midY - h / 2, width: w, height: h)
        if assist == nil {
            let p = KeyablePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: SnapAssistView())
            host.sizingOptions = []
            p.contentView = host
            assist = p
        }
        assist?.setFrame(rect, display: true)
        assist?.makeKeyAndOrderFront(nil)
        updateAssistPreview(zone, screen)
    }

    private func updateAssistPreview(_ zone: CGRect, _ screen: NSScreen) {
        showPreview(AXHelp.toCocoa(Self.axFrame(zone, on: screen)))
    }

    func assistPick(_ info: WinInfo) {
        guard let screen = assistScreen, !pendingZones.isEmpty else { closeAssist(); return }
        let z = pendingZones.removeFirst()
        place(info.element, z, on: screen)
        AXHelp.raise(info)
        placed.append(info.element)
        if pendingZones.isEmpty { closeAssist() } else { refreshAssist() }
    }

    func closeAssist() {
        assist?.orderOut(nil)
        assist = nil
        preview?.orderOut(nil)
        pendingZones = []
        assistItems = []
    }

    // MARK: Кнопки и горячие клавиши

    /// Активное окно — в ячейку раскладки, потом предложить окна для остальных мест
    func snapFrontmost(layout: Int, zone: Int, assist: Bool = true) {
        guard AXIsProcessTrusted() else {
            NotchState.shared.showAlert(AlertItem(emoji: "🪟", title: "Окна", text: "нужен «Универсальный доступ»", kind: .error))
            return
        }
        guard let w = AXHelp.focusedWindow(fallback: lastApp) else { return }
        let screen = Self.screen(of: w) ?? NSScreen.main ?? NSScreen.screens[0]
        let L = SnapLayouts.all[layout]
        place(w, L.zones[zone], on: screen)
        if assist { beginAssist(layout: L, used: zone, first: w, screen: screen) }
    }

    /// Разложить все окна по порядку: колонками или сеткой
    func arrangeAll(grid: Bool) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let wins = Array(AXHelp.windows().filter { (Self.screen(of: $0.element) ?? screen) == screen }.prefix(8))
        guard !wins.isEmpty else { return }
        let n = wins.count
        let cols = grid ? Int(ceil(sqrt(Double(n)))) : n
        let rows = grid ? Int(ceil(Double(n) / Double(cols))) : 1
        for (i, w) in wins.enumerated() {
            let r = i / cols, c = i % cols
            let inRow = r == rows - 1 ? n - cols * (rows - 1) : cols
            let width = 1.0 / CGFloat(inRow)
            let z = CGRect(x: CGFloat(c) * width, y: CGFloat(r) / CGFloat(rows), width: width, height: 1.0 / CGFloat(rows))
            place(w.element, z, on: screen)
        }
    }

    /// Ставит окно в ячейку. Если программа не даёт сделать окно меньше своего минимума —
    /// сдвигаем его так, чтобы оно целиком осталось на экране.
    func place(_ w: AXUIElement, _ zone: CGRect, on screen: NSScreen) {
        let target = Self.axFrame(zone, on: screen)
        AXHelp.setFrame(w, target)
        guard let f = AXHelp.frame(w), f.width > target.width + 2 || f.height > target.height + 2 else { return }
        let vis = Self.axFrame(CGRect(x: 0, y: 0, width: 1, height: 1), on: screen)
        var p = CGPoint(x: min(max(target.minX, vis.minX), vis.maxX - f.width),
                        y: min(max(target.minY, vis.minY), vis.maxY - f.height))
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
    }

    // MARK: Геометрия

    /// Доли экрана → рамка окна (координаты окон), в пределах экрана без строки меню и Dock
    static func axFrame(_ z: CGRect, on screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let x = vf.minX + z.minX * vf.width
        let top = vf.maxY - z.minY * vf.height
        let cocoa = NSRect(x: x, y: top - z.height * vf.height, width: z.width * vf.width, height: z.height * vf.height)
        let primaryH = NSScreen.screens.first?.frame.height ?? vf.maxY
        return CGRect(x: cocoa.minX.rounded(), y: (primaryH - cocoa.maxY).rounded(),
                      width: cocoa.width.rounded(), height: cocoa.height.rounded())
    }

    static func screen(at p: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func screen(of w: AXUIElement) -> NSScreen? {
        guard let f = AXHelp.frame(w) else { return nil }
        let c = AXHelp.toCocoa(f)
        return NSScreen.screens.first { $0.frame.contains(NSPoint(x: c.midX, y: c.midY)) }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Вид

/// Миниатюра раскладки; по нажатию на часть — onPick(номер части)
struct LayoutTile: View {
    let layout: SnapLayout
    var hovered: Int? = nil
    var size = CGSize(width: 92, height: 58)
    var onPick: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.zones.enumerated()), id: \.offset) { i, z in
                    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                    shape
                        .fill(hovered == i ? Color.accentColor : Color.white.opacity(0.16))
                        .overlay(shape.strokeBorder(Color.white.opacity(hovered == i ? 0.9 : 0.28), lineWidth: 1))
                        .frame(width: max(4, z.width * size.width - 3), height: max(4, z.height * size.height - 3))
                        .position(x: z.midX * size.width, y: z.midY * size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick?(i) }
                }
            }
            .frame(width: size.width, height: size.height)
            Text(layout.name)
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .frame(height: 12)
        }
    }
}

/// Панель раскладок под чёлкой во время перетаскивания окна
struct SnapPickerView: View {
    @ObservedObject var c = SnapController.shared

    var body: some View {
        HStack(alignment: .top, spacing: SnapController.gap) {
            ForEach(SnapLayouts.all) { L in
                LayoutTile(layout: L, hovered: c.hoveredLayout == L.id ? c.hoveredZone : nil,
                           size: CGSize(width: SnapController.tileW, height: SnapController.tileH))
            }
        }
        .padding(SnapController.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }
}

/// Выбор окна для следующего свободного места
struct SnapAssistView: View {
    @ObservedObject var c = SnapController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(c.assistText).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button { c.closeAssist() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .help("Не заполнять")
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(c.assistItems) { w in
                        Button { c.assistPick(w) } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: w.app.icon ?? NSImage()).resizable().frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(w.app.localizedName ?? "").font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(w.title.isEmpty ? "окно" : w.title).font(.system(size: 9.5))
                                        .foregroundStyle(Color.white.opacity(0.65)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }
}

/// Раздел «Окна» в чёлке
struct WindowsView: View {
    @ObservedObject var c = SnapController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Нажми на часть раскладки — туда встанет активное окно, а для остальных мест чёлка предложит другие окна.")
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 12), count: 4), alignment: .leading, spacing: 8) {
                ForEach(SnapLayouts.all) { L in
                    LayoutTile(layout: L, size: CGSize(width: 96, height: 56)) { zi in
                        NotchState.shared.onExpandRequest?(false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { c.snapFrontmost(layout: L.id, zone: zi) }
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Разложить все окна колонками") { c.arrangeAll(grid: false) }.buttonStyle(ChipButtonStyle())
                Button("Сеткой") { c.arrangeAll(grid: true) }.buttonStyle(ChipButtonStyle())
                Spacer(minLength: 0)
            }
            Text("Или потяни окно за заголовок к чёлке. ⌃⌥← и ⌃⌥→ — половины, ⌃⌥↑ — весь экран, ⌃⌥↓ — по центру.")
                .font(.system(size: 9)).foregroundStyle(Theme.faint)
        }
    }
}
