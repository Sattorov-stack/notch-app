import SwiftUI
import AppKit
import AVFoundation

/// «Зеркало»: круглое окошко с камерой прямо под чёлкой.
/// Открывается кнопкой 📷 в шапке или ⌃⌥M, закрывается кликом по кружку или той же кнопкой.
/// Не видно при демонстрации и записи экрана.
final class CameraMirror: ObservableObject {
    static let shared = CameraMirror()
    @Published var visible = false

    private var session: AVCaptureSession?
    private var panel: NSPanel?

    func toggle() { visible ? close() : open() }

    func open() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.start() : self.denied() }
            }
        default:
            denied()
        }
    }

    private func denied() {
        NotchState.shared.showAlert(AlertItem(emoji: "📷", title: "Камера",
            text: "нет доступа — Настройки → Конфиденциальность → Камера → NotchApp", kind: .error))
    }

    private func start() {
        guard panel == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            NotchState.shared.showAlert(AlertItem(emoji: "📷", title: "Камера", text: "камера не найдена", kind: .error))
            return
        }
        let s = AVCaptureSession()
        s.sessionPreset = .high
        guard s.canAddInput(input) else { return }
        s.addInput(input)
        session = s

        // Меню чёлки сворачиваем, кружок появляется сразу под чёлкой
        NotchState.shared.onExpandRequest?(false)

        let size: CGFloat = 220
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 24
        let rect = NSRect(x: screen.frame.midX - size / 2, y: screen.frame.maxY - top - size - 10,
                          width: size, height: size)

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = MirrorView(frame: NSRect(origin: .zero, size: rect.size), session: s) { [weak self] in
            self?.close()
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        panel = p
        visible = true
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    func close() {
        let s = session
        session = nil
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }   // камера сразу гаснет
        if let p = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        panel = nil
        visible = false
    }
}

/// Круг с изображением камеры, отражённым как в зеркале. Клик — закрыть.
final class MirrorView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let onClose: () -> Void

    init(frame: NSRect, session: AVCaptureSession, onClose: @escaping () -> Void) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        self.onClose = onClose
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))   // зеркально
        layer?.addSublayer(preview)
        toolTip = "Нажми, чтобы закрыть"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) { onClose() }
}

/// Кнопка камеры в шапке чёлки
struct MirrorButton: View {
    @ObservedObject var mirror = CameraMirror.shared
    var body: some View {
        GlassIconButton(icon: mirror.visible ? "camera.fill" : "camera",
                        help: "Зеркало: камера кружочком (⌃⌥M)") {
            mirror.toggle()
        }
    }
}
