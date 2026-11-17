import Foundation
import Translation

/// `NotchApp --selftest-translate`: Apple-перевод + ИИ-шлифовка на наборе фраз.
/// Печатает время и результат, проверяет, что смысл сохранён (ключевые слова) и нет мусора.
enum TranslateSelfTest {
    struct Case { let src: String; let tgt: String; let text: String; let must: [String] }

    static let cases: [Case] = [
        Case(src: "ru", tgt: "en", text: "привет как дела", must: ["how"]),
        Case(src: "ru", tgt: "en", text: "спасибо брат выручил", must: ["thank"]),
        Case(src: "ru", tgt: "en", text: "я седня не смогу прийти давай завтра", must: ["today", "tomorrow"]),
        Case(src: "ru", tgt: "en", text: "короче я хз че делать с этим багом он вылезает только на проде", must: ["bug", "prod"]),
        Case(src: "ru", tgt: "en", text: "скинь пожалуйста отчёт до пятницы", must: ["report", "friday"]),
        Case(src: "en", tgt: "ru", text: "The deployment failed again because of the database migration.", must: ["миграц", "баз"]),
        Case(src: "en", tgt: "ru", text: "Hey, how's it going?", must: ["как"]),
    ]

    static func run() async -> Bool {
        guard #available(macOS 26.0, *) else { print("нужна macOS 26+"); return false }
        var failed = 0
        let hasAI = await AIPolish.pickModel() != nil
        print("== Переводчик чёлки (ИИ-шлифовка: \(hasAI ? "есть" : "нет Ollama"))")
        for c in cases {
            do {
                let session = try TranslationSession(installedSource: Locale.Language(identifier: c.src),
                                                     target: Locale.Language(identifier: c.tgt))
                let t0 = Date()
                let apple = try await session.translate(c.text).targetText
                let t1 = Date()
                let ai = hasAI ? await AIPolish.polish(original: c.text, draft: apple, target: c.tgt) : nil
                let t2 = Date()
                let final = ai ?? apple
                let low = final.lowercased()
                let missing = c.must.filter { !low.contains($0) }
                let addedQuestion = final.contains("?") && !c.text.contains("?") && !apple.contains("?")
                let ok = missing.isEmpty && !final.contains(":)") && !addedQuestion
                if !ok { failed += 1 }
                print(String(format: "  %@  %@\n        Apple %.2fс: %@\n        ИИ    %.2fс: %@%@",
                             ok ? "PASS" : "FAIL", c.text, t1.timeIntervalSince(t0), apple,
                             t2.timeIntervalSince(t1), ai ?? "(оставлен Apple)",
                             missing.isEmpty ? "" : "   нет: \(missing.joined(separator: ", "))"))
            } catch {
                failed += 1
                print("  FAIL  \(c.text): \(error.localizedDescription)")
            }
        }
        print("== Итог: \(cases.count - failed) из \(cases.count)")
        return failed == 0
    }
}
