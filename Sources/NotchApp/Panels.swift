import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Заметки

struct NoteItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updated = Date()

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Без названия" : String(t.prefix(48))
    }

    var snippet: String {
        let rest = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: " ")
        let t = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Пустая заметка" : String(t.prefix(64))
    }
}

final class NotesStore: ObservableObject {
    static let shared = NotesStore()
    @Published var notes: [NoteItem]
    @Published var selected: UUID?
    private var work: DispatchWorkItem?

    init() {
        let saved = Disk.load("notes.json", as: [NoteItem].self) ?? []
        if !saved.isEmpty {
            notes = saved
        } else if let old = try? String(contentsOf: Disk.dir.appendingPathComponent("notes.txt"), encoding: .utf8),
                  !old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes = [NoteItem(text: old)]
        } else {
            notes = [NoteItem(text: "")]
        }

        if let raw = UserDefaults.standard.string(forKey: "selectedNote"),
           let id = UUID(uuidString: raw),
           notes.contains(where: { $0.id == id }) {
            selected = id
        } else {
            selected = notes.first?.id
        }
    }

    var current: NoteItem? { notes.first { $0.id == selected } }

    func select(_ id: UUID) {
        selected = id
        UserDefaults.standard.set(id.uuidString, forKey: "selectedNote")
    }

    func add() {
        let n = NoteItem(text: "")
        notes.insert(n, at: 0)
        select(n.id)
        Disk.save(notes, "notes.json")
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [NoteItem(text: "")] }
        if selected == id, let first = notes.first { select(first.id) }
        Disk.save(notes, "notes.json")
    }

    func update(_ text: String) {
        guard let id = selected, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].text = text
        notes[i].updated = Date()
        scheduleSave()
    }

    func append(_ s: String) {
        guard !s.isEmpty else { return }
        if let id = selected, let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].text += (notes[i].text.isEmpty ? "" : "\n\n") + s
            notes[i].updated = Date()
        } else {
            notes.append(NoteItem(text: s))
            if let last = notes.last { select(last.id) }
        }
        Disk.save(notes, "notes.json")
    }

    private func scheduleSave() {
        work?.cancel()
        let snapshot = notes
        let item = DispatchWorkItem { Disk.save(snapshot, "notes.json") }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}

struct NotesView: View {
    @ObservedObject var store = NotesStore.shared
    @Environment(\.compactNotch) private var compact

    private var text: Binding<String> {
        Binding(get: { store.current?.text ?? "" },
                set: { store.update($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            list
                .frame(width: compact ? 178 : 208)
            editor
        }
    }

    private var list: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("ЗАМЕТКИ")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                Text("\(store.notes.count)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
                Spacer()
                Button {
                    store.add()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Добавить заметку")
            }

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.notes) { note in
                        noteRow(note)
                    }
                }
            }

            Button {
                store.add()
            } label: {
                Label("Добавить заметку", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.mini)
        }
    }

    private func noteRow(_ note: NoteItem) -> some View {
        let isSel = note.id == store.selected
        return Button {
            store.select(note.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isSel ? Theme.text : Theme.dim)
                    .lineLimit(1)
                Text(note.snippet)
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSel ? Color.white.opacity(0.14) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSel ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Удалить заметку", role: .destructive) { store.delete(note.id) }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("ТЕКСТ")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                Text("автосохранение")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.faint)
                Spacer()
                Text("\(store.current?.text.count ?? 0) симв.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.current?.text ?? "", forType: .string)
                }
                Button {
                    if let id = store.selected { store.delete(id) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Удалить заметку")
            }
            .controlSize(.mini)

            PlainTextEditor(text: text)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.8))
        }
    }
}

// MARK: - Буфер обмена

enum ClipKind: String, Codable { case text, image }

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind = .text
    var text: String = ""
    var imageFile: String?
    var date = Date()
    var pinned = false

    enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFile, date, pinned
    }

    init(id: UUID = UUID(), kind: ClipKind = .text, text: String = "",
         imageFile: String? = nil, date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.date = date
        self.pinned = pinned
    }

    // Старые clips.json без kind/imageFile тоже читаются
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .text
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    static let limit = 40
    @Published var items: [ClipItem]
    private let imagesDir = Disk.dir.appendingPathComponent("clip-images", isDirectory: true)
    private var last = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var lastImageHash = 0
    @Published var debug = ""

    init() {
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        items = Disk.load("clips.json", as: [ClipItem].self) ?? []
        cleanupOrphans()
    }

    private func cleanupOrphans() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) else { return }
        let used = Set(items.compactMap { $0.imageFile })
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        let types = pb.types?.map { $0.rawValue } ?? []
        // Пароли и временные данные менеджеров паролей не сохраняем
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                    "org.nspasteboard.AutoGeneratedType"]
        if types.contains(where: { skip.contains($0) }) { return }

        // Картинка из буфера
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
           let image = NSImage(data: data) {
            debug = "image data " + String(data.count)
            guard data.hashValue != lastImageHash else { debug += " dup"; return }
            lastImageHash = data.hashValue
            addImage(image)
            return
        } else {
            debug = "no image; types " + String(types.count)
        }

        guard let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let i = items.firstIndex(where: { $0.kind == .text && $0.text == s }) {
            var old = items.remove(at: i)
            old.date = Date()
            items.insert(old, at: 0)
        } else {
            items.insert(ClipItem(kind: .text, text: s), at: 0)
        }
        trim()
        save()
    }

    private func addImage(_ image: NSImage) {
        guard let png = Self.png(image, maxSide: 480) else { debug += " | png nil"; return }
        debug += " | png " + String(png.count)
        let name = UUID().uuidString + ".png"
        let url = imagesDir.appendingPathComponent(name)
        guard (try? png.write(to: url)) != nil else { debug += " | write fail"; return }
        let size = image.size
        let item = ClipItem(kind: .image,
                            text: "Изображение \(Int(size.width))×\(Int(size.height))",
                            imageFile: name)
        items.insert(item, at: 0)
        trim()
        save()
    }

    static func png(_ image: NSImage, maxSide: CGFloat) -> Data? {
        let w = max(1, image.size.width)
        let h = max(1, image.size.height)
        let scale = min(1, maxSide / max(w, h))
        let target = NSSize(width: w * scale, height: h * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    func image(for item: ClipItem) -> NSImage? {
        guard let file = item.imageFile else { return nil }
        return NSImage(contentsOf: imagesDir.appendingPathComponent(file))
    }

    private func trim() {
        while items.count > Self.limit {
            if let idx = items.lastIndex(where: { !$0.pinned }) {
                let old = items.remove(at: idx)
                removeFile(old)
            } else {
                let old = items.removeLast()
                removeFile(old)
            }
        }
    }

    private func removeFile(_ item: ClipItem) {
        guard let file = item.imageFile else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.kind == .image, let img = image(for: item) {
            pb.writeObjects([img])
        } else {
            pb.setString(item.text, forType: .string)
        }
        last = pb.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            var it = items.remove(at: i)
            it.date = Date()
            items.insert(it, at: 0)
        }
        save()
    }

    func togglePin(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].pinned.toggle()
            save()
        }
    }

    func delete(_ item: ClipItem) {
        removeFile(item)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items where !item.pinned { removeFile(item) }
        items = items.filter { $0.pinned }
        save()
    }

    private func save() { Disk.save(items, "clips.json") }
}

struct ClipboardView: View {
    @ObservedObject var store = ClipboardStore.shared
    @State private var query = ""

    private var shown: [ClipItem] {
        let base = query.isEmpty ? store.items
            : store.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
        return base.filter { $0.pinned } + base.filter { !$0.pinned }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                    TextField("Поиск по буферу", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.07)))

                Text("\(store.items.count)/\(ClipboardStore.limit)")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
                Spacer()
                Button("Очистить") { store.clear() }
                    .controlSize(.mini)
                    .help("Удалить всё, кроме закреплённого")
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    if shown.isEmpty {
                        Text("Пока ничего не скопировано")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.faint)
                            .padding(.top, 10)
                    }
                    ForEach(shown) { item in
                        row(item)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        HStack(spacing: 8) {
            if item.kind == .image, let img = store.image(for: item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.7))
            } else {
                Image(systemName: item.text.hasPrefix("http") ? "link" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(item.pinned ? Theme.orange : Theme.faint)
                    .frame(width: 14)
            }
            Button { store.copy(item) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(2)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.kind == .image ? "картинка · " + item.date.formatted(date: .omitted, time: .shortened)
                         : item.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.faint)
                }
            }
            .buttonStyle(.plain)
            .help("Нажми, чтобы скопировать")

            Button { store.togglePin(item) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(item.pinned ? Theme.orange : Theme.faint)

            Button { store.delete(item) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 0.7))
    }
}

// MARK: - Полка

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
}

final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published var items: [ShelfItem]

    init() { items = Disk.load("shelf.json", as: [ShelfItem].self) ?? [] }

    func add(_ url: URL) {
        guard !items.contains(where: { $0.path == url.path }) else { return }
        items.append(ShelfItem(path: url.path))
        Disk.save(items, "shelf.json")
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        Disk.save(items, "shelf.json")
    }
}

struct ShelfView: View {
    @ObservedObject var shelf = ShelfStore.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("ПОЛКА")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.faint)
                Text("\(shelf.items.count) файлов")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.faint)
                Spacer()
                Button("Очистить") {
                    shelf.items.forEach { shelf.remove($0) }
                }
                .controlSize(.mini)
                .disabled(shelf.items.isEmpty)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(targeted ? Theme.accent.opacity(0.10) : Color.white.opacity(0.03))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(targeted ? Theme.accent : Theme.stroke,
                                  style: StrokeStyle(lineWidth: 1.3, dash: [6, 4]))

                if shelf.items.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.faint)
                        Text("Перетащи файлы в чёлку")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.dim)
                        Text("Они останутся здесь, пока не уберёшь")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { obj, _ in
                    var url: URL?
                    if let d = obj as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = obj as? URL { url = u }
                    if let url {
                        DispatchQueue.main.async { ShelfStore.shared.add(url) }
                    }
                }
            }
            return true
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @State private var hover = false

    var body: some View {
        let url = URL(fileURLWithPath: item.path)
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 42, height: 42)
            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(hover ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 0.7))
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Открыть") { NSWorkspace.shared.open(url) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Убрать с полки") { ShelfStore.shared.remove(item) }
        }
    }
}
