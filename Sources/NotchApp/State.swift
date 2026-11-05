import SwiftUI
import Combine

// MARK: - Хранилище на диске

enum Disk {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchApp")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Вкладки

enum Tab: String, CaseIterable, Identifiable {
    case home, music, notes, script, translate, recognize, clipboard, shelf, calendar, pets, tools
    var id: String { rawValue }

    /// Разделы разложены по двум рейлам, чтобы панель была ниже.
    static let leftRail: [Tab] = [.home, .music, .notes, .script, .translate]
    static let rightRail: [Tab] = [.recognize, .clipboard, .shelf, .calendar, .pets, .tools]

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .music: return "music.note"
        case .notes: return "note.text"
        case .script: return "text.alignleft"
        case .translate: return "character.bubble"
        case .recognize: return "text.viewfinder"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full"
        case .calendar: return "calendar"
        case .pets: return "pawprint"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .music: return "Музыка"
        case .notes: return "Заметки"
        case .script: return "Сценарий"
        case .translate: return "Переводчик"
        case .recognize: return "Распознать текст"
        case .clipboard: return "Буфер обмена"
        case .shelf: return "Полка"
        case .calendar: return "Календарь"
        case .pets: return "Питомцы и лимиты"
        case .tools: return "Инструменты"
        }
    }

    var subtitle: String {
        switch self {
        case .home: return "Главное под рукой — музыка, календарь, ИИ и буфер"
        case .music: return "Music, Spotify и то, что играет в системе"
        case .notes: return "Без автоисправлений, подчёркиваний и умных кавычек"
        case .script: return "Суфлёр, скрытый от записи и демонстрации экрана"
        case .translate: return "Офлайн-перевод Apple, без запросов к серверу"
        case .recognize: return "Скриншот, голос и видео → текст на устройстве"
        case .clipboard: return "История копирований с поиском и закреплением"
        case .shelf: return "Перетащи файл в чёлку — он останется здесь"
        case .calendar: return "События из Календаря macOS"
        case .pets: return "Питомцы ИИ-агентов и остатки лимитов"
        case .tools: return "Клавиатура, сон, автозапуск"
        }
    }

    /// Высота панели под конкретный раздел: не держим большую панель там, где хватает маленькой.
    var panelHeight: CGFloat {
        switch self {
        case .home: return 320
        case .music: return 280
        case .notes: return 310
        case .script: return 292
        case .translate: return 296
        case .recognize: return 320
        case .clipboard: return 310
        case .shelf: return 278
        case .calendar: return 340
        case .pets: return 340
        case .tools: return 302
        }
    }

    var windowSize: CGSize {
        switch self {
        case .home: return CGSize(width: 820, height: 560)
        case .music: return CGSize(width: 460, height: 340)
        case .notes: return CGSize(width: 620, height: 560)
        case .script: return CGSize(width: 820, height: 560)
        case .translate: return CGSize(width: 620, height: 400)
        case .recognize: return CGSize(width: 780, height: 540)
        case .clipboard: return CGSize(width: 520, height: 620)
        case .shelf: return CGSize(width: 640, height: 440)
        case .calendar: return CGSize(width: 680, height: 540)
        case .pets: return CGSize(width: 700, height: 560)
        case .tools: return CGSize(width: 620, height: 500)
        }
    }
}

// MARK: - Всплывающее уведомление питомца

enum AlertKind: String, Codable { case done, permission, error, info }

struct AlertItem: Identifiable {
    let id = UUID()
    let emoji: String
    let title: String
    let text: String
    let kind: AlertKind
}

// MARK: - Общее состояние чёлки

final class NotchState: ObservableObject {
    static let shared = NotchState()

    @Published var expanded = false
    @Published var tab: Tab = .home
    @Published var pinned = false
    @Published var alert: AlertItem?

    var notchH: CGFloat = 32
    var onExpandRequest: ((Bool) -> Void)?
    private var alertTimer: Timer?

    func showAlert(_ a: AlertItem) {
        alert = a
        alertTimer?.invalidate()
        let secs: TimeInterval = a.kind == .permission ? 14 : 7
        alertTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            self?.alert = nil
        }
    }

    func dismissAlert() {
        alertTimer?.invalidate()
        alert = nil
    }
}

extension View {
    func card() -> some View {
        self.padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.8))
    }
}
