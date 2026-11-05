import SwiftUI
import AppKit

/// Отдельное «стеклянное» окно для любого раздела.
final class SectionWindows: NSObject, NSWindowDelegate {
    static let shared = SectionWindows()
    private var windows: [String: NSWindow] = [:]

    func open(_ tab: Tab) {
        if let w = windows[tab.rawValue] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: tab.windowSize),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = tab.title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.minSize = NSSize(width: 440, height: 320)
        w.contentView = NSHostingView(rootView: SectionWindowRoot(tab: tab) { [weak self] in
            self?.close(tab)
        })
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[tab.rawValue] = w
        NSApp.activate(ignoringOtherApps: true)
        NotchState.shared.onExpandRequest?(false)
    }

    func close(_ tab: Tab) {
        windows[tab.rawValue]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }
}

struct SectionWindowRoot: View {
    let tab: Tab
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            LinearGradient(colors: [Color(white: 0.09).opacity(0.62),
                                    Color(white: 0.015).opacity(0.90)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    SectionHeader(title: tab.title, subtitle: tab.subtitle)
                    Spacer()
                    GlassIconButton(icon: "xmark", help: "Закрыть окно") { onClose() }
                }
                SectionBody(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.8))
        .environment(\.colorScheme, .dark)
        .environment(\.compactNotch, false)
        .buttonStyle(GlassButtonStyle())
    }
}

/// Один и тот же раздел показывается и в чёлке, и в отдельном окне.
struct SectionBody: View {
    let tab: Tab

    var body: some View {
        switch tab {
        case .home: HomeView()
        case .music: MusicView()
        case .notes: NotesView()
        case .script: ScriptView()
        case .translate: TranslateView()
        case .recognize: RecognizeView()
        case .clipboard: ClipboardView()
        case .shelf: ShelfView()
        case .calendar: CalendarView()
        case .pets: PetsView()
        case .tools: ToolsView()
        }
    }
}
