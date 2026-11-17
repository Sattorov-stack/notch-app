import SwiftUI

/// Человечек ИИ-агента. Поза показывает, что агент делает; у каждого агента свой цвет,
/// а в уголке — его питомец:
///   идёт — работает · машет — ждёт разрешения · руки вверх — готово ·
///   упал — сбой · медитирует — отдыхает
struct PetAvatar: View {
    let agent: String
    let size: CGFloat
    @ObservedObject var hub = AgentHub.shared
    @State private var phase = false

    private enum Mood { case working, waiting, done, failed, info, resting }

    private var mood: Mood {
        if let k = hub.status[agent] {
            switch k {
            case .permission: return .waiting
            case .done: return .done
            case .error: return .failed
            default: return .info
            }
        }
        return hub.running.contains(agent) ? .working : .resting
    }

    private var symbol: String {
        switch mood {
        case .working: return "figure.walk"
        case .waiting: return "figure.wave"
        case .done: return "figure.arms.open"
        case .failed: return "figure.fall"
        case .info: return "figure.stand"
        case .resting: return "figure.mind.and.body"
        }
    }

    /// Постоянный цвет агента — по его имени
    private var tint: Color {
        // Узнаваемые цвета для известных агентов, для остальных — свой оттенок по имени
        let known: [(String, Color)] = [
            ("harness", Color(red: 0.55, green: 0.4, blue: 1.0)), ("claude", Color(red: 0.85, green: 0.47, blue: 0.34)),
            ("codex", Color(red: 0.25, green: 0.8, blue: 0.6)), ("chatgpt", Color(red: 0.06, green: 0.64, blue: 0.5)),
            ("gemini", Color(red: 0.35, green: 0.55, blue: 1.0)), ("cursor", Color(red: 0.78, green: 0.78, blue: 0.84)),
            ("deepseek", Color(red: 0.3, green: 0.42, blue: 0.95)), ("opencode", Color(red: 0.95, green: 0.75, blue: 0.2)),
            ("koda", Color(red: 0.8, green: 0.55, blue: 0.3)), ("copilot", Color(red: 0.8, green: 0.35, blue: 0.9)),
            ("grok", Color(red: 0.92, green: 0.92, blue: 0.92)), ("kimi", Color(red: 1.0, green: 0.45, blue: 0.6)),
            ("manus", Color(red: 0.4, green: 0.85, blue: 0.95))
        ]
        let a = agent.lowercased()
        if let c = known.first(where: { a.contains($0.0) })?.1 { return c }
        let h = agent.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(h % 360) / 360, saturation: 0.6, brightness: 0.95)
    }

    private var animation: Animation {
        switch mood {
        case .working: return .easeInOut(duration: 0.42).repeatForever(autoreverses: true)
        case .waiting: return .easeInOut(duration: 0.28).repeatForever(autoreverses: true)
        case .done: return .easeOut(duration: 0.5).repeatForever(autoreverses: true)
        case .resting: return .easeInOut(duration: 2.2).repeatForever(autoreverses: true)
        default: return .default
        }
    }

    private var rotation: Double {
        switch mood {
        case .waiting: return phase ? 12 : -12
        case .working: return phase ? 5 : -5
        case .failed: return 16
        default: return 0
        }
    }

    private var lift: CGFloat {
        switch mood {
        case .working: return phase ? -size * 0.04 : size * 0.02
        case .done: return phase ? -size * 0.12 : 0
        case .waiting: return phase ? -size * 0.05 : 0
        default: return 0
        }
    }

    private var scale: CGFloat { mood == .resting ? (phase ? 1.05 : 0.94) : 1 }

    var body: some View {
        let ring = hub.statusColor(for: agent)
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Circle().strokeBorder(ring.opacity(0.6), lineWidth: max(0.8, size * 0.035))
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(rotation))
                .offset(y: lift)
                .scaleEffect(scale)
            Text(hub.pet(for: agent))
                .font(.system(size: max(7, size * 0.3)))
                .offset(x: size * 0.33, y: size * 0.33)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(animation) { phase = true } }
        .onChange(of: hub.statusText(for: agent)) { _, _ in
            phase = false
            withAnimation(animation) { phase = true }
        }
    }
}
