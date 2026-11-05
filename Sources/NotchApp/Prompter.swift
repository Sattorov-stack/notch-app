import SwiftUI
import AppKit

/// Суфлёр: отдельное окно, скрытое от записи и демонстрации экрана (sharingType = .none)
final class PrompterService: ObservableObject {
    static let shared = PrompterService()

    @Published var text: String = UserDefaults.standard.string(forKey: "prompterText") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "prompterText") }
    }
    @Published var speed: Double = 30
    @Published var fontSize: Double = 28
    @Published var opacity: Double = 0.8
    @Published var pauseOnHover = true
    @Published var running = false
    @Published var visible = false

    private var window: NSPanel?
    private var scroll: NSScrollView?
    private var textView: NSTextView?
    private var timer: Timer?

    func toggleWindow() { visible ? hide() : show() }

    func show() {
        if window == nil { build() }
        window?.orderFrontRegardless()
        visible = true
        refresh()
    }

    func hide() {
        running = false
        timer?.invalidate()
        window?.orderOut(nil)
        visible = false
    }

    func toggleRun() {
        if !visible { show() }
        running.toggle()
        timer?.invalidate()
        guard running else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func rewind() {
        guard let scroll else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func refresh() {
        guard let tv = textView else { return }
        tv.string = text
        tv.font = .systemFont(ofSize: CGFloat(fontSize), weight: .medium)
        tv.textColor = .white
        tv.alignment = .center
        scroll?.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity)).cgColor
    }

    private func tick() {
        guard let scroll, let doc = scroll.documentView else { return }
        // Навёл мышь на суфлёр — текст стоит, убрал — едет дальше
        if pauseOnHover, let w = window, w.frame.contains(NSEvent.mouseLocation) { return }
        let maxY = max(0, doc.frame.height - scroll.contentView.bounds.height)
        var y = scroll.contentView.bounds.origin.y + CGFloat(speed) / 60
        if y >= maxY {
            y = maxY
            running = false
            timer?.invalidate()
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func build() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let w: CGFloat = 640, h: CGFloat = 180
        // Сразу под чёлкой — рядом с камерой, взгляд почти в объектив
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.visibleFrame.maxY - h - 6, width: w, height: h)

        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.sharingType = .none            // не попадает в запись и демонстрацию экрана
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 28, height: 60)
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 14
        scroll.layer?.masksToBounds = true

        panel.contentView = scroll
        window = panel
        self.scroll = scroll
        textView = tv
    }
}

struct ScriptView: View {
    @ObservedObject var p = PrompterService.shared

    var body: some View {
        HStack(spacing: 10) {
            PlainTextEditor(text: $p.text)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Button(p.visible ? "Скрыть" : "Показать") { p.toggleWindow() }
                    Button(p.running ? "Пауза" : "Старт") { p.toggleRun() }
                    Button { p.rewind() } label: { Image(systemName: "backward.end.fill") }
                        .help("В начало")
                }
                slider("Скорость", $p.speed, 5...120)
                slider("Шрифт", $p.fontSize, 16...60)
                slider("Фон", $p.opacity, 0.2...1)
                Toggle("Пауза при наведении мыши", isOn: $p.pauseOnHover)
                    .toggleStyle(.checkbox)
                Text("Окно суфлёра скрыто от записи и показа экрана")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .font(.caption)
            .frame(width: 215)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: p.text) { _, _ in p.refresh() }
        .onChange(of: p.fontSize) { _, _ in p.refresh() }
        .onChange(of: p.opacity) { _, _ in p.refresh() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}
