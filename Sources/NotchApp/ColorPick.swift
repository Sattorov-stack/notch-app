import SwiftUI
import AppKit

/// Пипетка: берёт цвет любой точки экрана и сразу копирует HEX.
final class ColorPickService: ObservableObject {
    static let shared = ColorPickService()
    @Published var history: [String] = UserDefaults.standard.stringArray(forKey: "colorHistory") ?? [] {
        didSet { UserDefaults.standard.set(history, forKey: "colorHistory") }
    }
    private let sampler = NSColorSampler()

    func pick() {
        sampler.show { [weak self] color in
            guard let self, let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = Self.hex(c)
            self.copy(hex)
            self.history.removeAll { $0 == hex }
            self.history.insert(hex, at: 0)
            if self.history.count > 12 { self.history.removeLast(self.history.count - 12) }
            NotchState.shared.showAlert(AlertItem(emoji: "🎨", title: "Пипетка",
                                                  text: "\(hex) скопирован", kind: .info))
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X",
               Int(round(c.redComponent * 255)),
               Int(round(c.greenComponent * 255)),
               Int(round(c.blueComponent * 255)))
    }

    /// Варианты записи цвета: HEX, CSS rgb(), SwiftUI
    static func variants(_ hex: String) -> [String] {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = Int(h, radix: 16) else { return [hex] }
        let r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255
        return [
            hex,
            "rgb(\(r), \(g), \(b))",
            String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                   Double(r) / 255, Double(g) / 255, Double(b) / 255)
        ]
    }
}

/// Кнопка пипетки в шапке чёлки. Правый клик — история цветов в трёх форматах.
struct ColorPickButton: View {
    @ObservedObject var svc = ColorPickService.shared

    var body: some View {
        GlassIconButton(icon: "eyedropper", help: "Пипетка: цвет с экрана (⌃⌥C). Правый клик — история") {
            svc.pick()
        }
        .contextMenu {
            if svc.history.isEmpty { Text("История пуста") }
            ForEach(svc.history, id: \.self) { hex in
                Menu(hex) {
                    ForEach(ColorPickService.variants(hex), id: \.self) { v in
                        Button("Копировать \(v)") { svc.copy(v) }
                    }
                }
            }
        }
    }
}
