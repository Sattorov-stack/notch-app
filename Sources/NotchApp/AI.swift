import CryptoKit
import Foundation

/// Локальные нейросети через Ollama (http://127.0.0.1:11434). Ничего не уходит в интернет.
/// Если Ollama не запущена — функции возвращают nil, и чёлка работает без ИИ.
enum Ollama {
    static let base = "http://127.0.0.1:11434"

    static func models() async -> [String] {
        guard let url = URL(string: base + "/api/tags"),
              let result = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    /// Текстовая модель: qwen2.5:7b, иначе любая не-embed/не-vision.
    static func textModel() async -> String? {
        let names = await models().filter { !$0.contains("embed") && !$0.contains("vl") && !$0.contains("llava") }
        if names.contains("qwen2.5:7b") { return "qwen2.5:7b" }
        return names.first { $0.hasPrefix("qwen") } ?? names.first
    }

    static func visionModel() async -> String? {
        await models().first { $0.contains("vl") || $0.contains("llava") || $0.contains("vision") }
    }

    /// Модель для поиска по смыслу: многоязычные (bge-m3) понимают русский намного лучше nomic.
    static func embedModel() async -> String? {
        let all = await models()
        return all.first { $0.hasPrefix("bge-m3") }
            ?? all.first { $0.contains("multilingual") }
            ?? all.first { $0.contains("embed") }
    }

    /// nomic требует префиксы «search_document:/search_query:», остальным они не нужны.
    static func docPrefix(_ model: String) -> String { model.contains("nomic") ? "search_document: " : "" }
    static func queryPrefix(_ model: String) -> String { model.contains("nomic") ? "search_query: " : "" }

    static func chat(model: String, system: String, user: String, images: [Data] = [],
                     timeout: TimeInterval = 60) async -> String? {
        var userMsg: [String: Any] = ["role": "user", "content": user]
        if !images.isEmpty { userMsg["images"] = images.map { $0.base64EncodedString() } }
        let body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "1h",
            "options": ["temperature": 0, "num_predict": 700],
            "messages": [["role": "system", "content": system], userMsg],
        ]
        guard let url = URL(string: base + "/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let result = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let text = (json["message"] as? [String: Any])?["content"] as? String else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Векторы смысла для текстов (nomic-embed-text).
    static func embed(model: String, texts: [String]) async -> [[Float]]? {
        guard !texts.isEmpty, let url = URL(string: base + "/api/embed"),
              let data = try? JSONSerialization.data(withJSONObject: ["model": model, "input": texts, "keep_alive": "1h"])
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let result = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let vecs = json["embeddings"] as? [[Double]], vecs.count == texts.count else { return nil }
        return vecs.map { $0.map(Float.init) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}

/// «Объясни скриншот»: текст распознаёт Vision, объясняет qwen2.5:7b.
/// Если на картинке нет текста — смотрит vision-модель (медленнее и слабее).
enum AIExplain {
    static let system = """
    Ты помощник разработчика. Тебе дают текст, распознанный со скриншота. Коротко ответь по-русски \
    (2–5 предложений): что это. Если это ошибка — назови причину и как исправить (с командой, если уместно). \
    Если текст на другом языке — переведи главное на русский. Не выдумывай того, чего нет в тексте; \
    числа, порты, имена файлов переписывай точно.
    """
    static let visionPrompt = """
    Коротко по-русски (2–4 предложения) опиши, что на скриншоте. Если это ошибка — причина и как исправить.
    """

    static func explain(text: String, image: Data?) async -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, let model = await Ollama.textModel() {
            return await Ollama.chat(model: model, system: system, user: String(clean.prefix(6000)), timeout: 60)
        }
        if let image, let vmodel = await Ollama.visionModel() {
            return await Ollama.chat(model: vmodel, system: "", user: visionPrompt, images: [image], timeout: 120)
        }
        return nil
    }
}

// MARK: - Поиск по смыслу в заметках (nomic-embed-text + qwen2.5:7b для ответа)


final class NotesSearch: ObservableObject {
    static let shared = NotesSearch()

    struct Hit: Identifiable {
        let id = UUID()
        let noteID: UUID
        let title: String
        let snippet: String
        let score: Float
    }

    @Published var query = ""
    @Published var hits: [Hit] = []
    @Published var busy = false
    @Published var status = ""
    @Published var answer = ""

    private var vectors: [String: [Float]] = Disk.load("notes_vectors.json", as: [String: [Float]].self) ?? [:]
    private var vectorsModel = UserDefaults.standard.string(forKey: "notesVectorsModel") ?? ""
    private var context: [String] = []

    private struct Chunk { let noteID: UUID; let title: String; let text: String; let key: String }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Режем заметки на куски ~600 символов по абзацам.
    static func split(_ text: String) -> [String] {
        let paras = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        var out: [String] = []
        var cur = ""
        for p in paras {
            if !cur.isEmpty && cur.count + p.count > 600 { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + p
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func chunks() -> [Chunk] {
        NotesStore.shared.notes.flatMap { note in
            Self.split(note.text).map { Chunk(noteID: note.id, title: note.title, text: $0, key: Self.hash($0)) }
        }
    }

    /// Порядок документов по близости к запросу (для поиска и самопроверки).
    static func rank(query: String, docs: [String], model: String) async -> [(Int, Float)]? {
        guard let dv = await Ollama.embed(model: model, texts: docs.map { Ollama.docPrefix(model) + $0 }),
              let qv = await Ollama.embed(model: model, texts: [Ollama.queryPrefix(model) + query])?.first else { return nil }
        return dv.enumerated().map { ($0.offset, Ollama.cosine(qv, $0.element)) }.sorted { $0.1 > $1.1 }
    }

    func clear() {
        query = ""; hits = []; answer = ""; status = ""; context = []
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clear(); return }
        busy = true
        answer = ""
        status = "Ищу по смыслу…"
        let all = chunks()
        Task {
            guard let model = await Ollama.embedModel() else {
                await MainActor.run { self.busy = false; self.status = "Нужна Ollama с моделью nomic-embed-text" }
                return
            }
            if model != self.vectorsModel {          // сменилась модель — старые векторы не годятся
                await MainActor.run {
                    self.vectors = [:]
                    self.vectorsModel = model
                    UserDefaults.standard.set(model, forKey: "notesVectorsModel")
                }
            }
            let missing = all.filter { self.vectors[$0.key] == nil }
            var fresh: [String: [Float]] = [:]
            var start = 0
            while start < missing.count {
                let part = Array(missing[start..<min(start + 32, missing.count)])
                if let v = await Ollama.embed(model: model, texts: part.map { Ollama.docPrefix(model) + $0.text }) {
                    for (c, vec) in zip(part, v) { fresh[c.key] = vec }
                }
                start += 32
            }
            let qv = await Ollama.embed(model: model, texts: [Ollama.queryPrefix(model) + q])?.first
            await MainActor.run {
                self.busy = false
                guard let qv else { self.status = "Ollama не ответила"; return }
                for (k, v) in fresh { self.vectors[k] = v }
                let keys = Set(all.map(\.key))
                self.vectors = self.vectors.filter { keys.contains($0.key) }
                Disk.save(self.vectors, "notes_vectors.json")

                let scored = all.compactMap { c -> (Chunk, Float)? in
                    guard let v = self.vectors[c.key] else { return nil }
                    return (c, Ollama.cosine(qv, v))
                }.sorted { $0.1 > $1.1 }
                self.context = scored.prefix(4).map { $0.0.text }
                var seen = Set<UUID>()
                self.hits = scored.filter { seen.insert($0.0.noteID).inserted }.prefix(6).map {
                    Hit(noteID: $0.0.noteID, title: $0.0.title, snippet: String($0.0.text.prefix(140)), score: $0.1)
                }
                self.status = self.hits.isEmpty ? "Ничего не нашлось" : ""
            }
        }
    }

    /// Ответ на вопрос только по найденным заметкам.
    func ask() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !context.isEmpty else { return }
        busy = true
        status = "✨ Читаю заметки…"
        let ctx = context.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
        Task {
            var a: String?
            if let model = await Ollama.textModel() {
                a = await Ollama.chat(model: model,
                                      system: "Отвечай по-русски коротко (1–3 предложения) ТОЛЬКО по приведённым заметкам. Если ответа в них нет — так и скажи.",
                                      user: "Заметки:\n\(ctx)\n\nВопрос: \(q)")
            }
            await MainActor.run {
                self.answer = a ?? "ИИ недоступен — запусти Ollama"
                self.busy = false
                self.status = ""
            }
        }
    }
}

// MARK: - Самопроверка ИИ: NotchApp --selftest-ai

enum AISelfTest {
    static func run() async -> Bool {
        var failed = 0
        func check(_ ok: Bool, _ title: String, _ detail: String) {
            if !ok { failed += 1 }
            print("  \(ok ? "PASS" : "FAIL")  \(title)\n        \(detail.replacingOccurrences(of: "\n", with: " "))")
        }

        print("== Объясни скриншот (текст → qwen)")
        let errText = """
        $ npm run start
        > karavan-api@1.0.0 start
        Error: listen EADDRINUSE: address already in use :::3000
            at Server.setupListenHandle [as _listen2] (node:net:1872:16)
        """
        var t0 = Date()
        let a1 = await AIExplain.explain(text: errText, image: nil) ?? ""
        check(a1.contains("3000") && a1.lowercased().contains("порт") && !a1.contains("30000"),
              String(format: "ошибка EADDRINUSE (%.1f с)", Date().timeIntervalSince(t0)), a1)

        t0 = Date()
        let a2 = await AIExplain.explain(text: "Meeting moved to Thursday 3 PM. Please bring the signed contract.", image: nil) ?? ""
        let a2l = a2.lowercased()
        check(a2l.contains("четверг") && ["контракт", "договор", "соглашен"].contains { a2l.contains($0) },
              String(format: "английский текст → перевод (%.1f с)", Date().timeIntervalSince(t0)), a2)

        guard let em = await Ollama.embedModel() else {
            print("  FAIL  нет модели nomic-embed-text"); return false
        }
        let docs = [
            "Обновил ключи VPN на сервере 46, outline перезапущен через pm2",
            "Рецепт плова: рис, морковь, баранина, зира",
            "Купить молоко и хлеб",
            "Экзамен по базам данных в пятницу, аудитория 305",
        ]
        print("== Поиск по смыслу (модель: \(em))")
        let cases: [(String, Int)] = [("как я настраивал впн", 0), ("что приготовить на ужин", 1),
                                      ("когда сессия по БД", 3), ("продукты в магазин", 2)]
        for (q, expected) in cases {
            t0 = Date()
            let r = await NotesSearch.rank(query: q, docs: docs, model: em)
            let top = r?.first?.0 ?? -1
            check(top == expected, String(format: "«%@» (%.2f с)", q, Date().timeIntervalSince(t0)),
                  "нашлось: \(top >= 0 ? docs[top] : "ничего")")
        }

        print("== Итог: \(failed == 0 ? "всё прошло" : "\(failed) упало")")
        return failed == 0
    }
}
