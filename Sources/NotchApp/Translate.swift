import SwiftUI
import Translation
import NaturalLanguage
import AppKit

// MARK: - Модель перевода

/// Офлайн-перевод Apple. Источник языка определяем сами (NaturalLanguage),
/// иначе Translation показывает системный запрос «выберите язык» — из-за него
/// переводчик и казался «тупым».
final class TranslateModel: ObservableObject {
    static let shared = TranslateModel()

    @Published var input = ""
    @Published var output = ""
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var sourceCode = "auto"
    @Published var targetCode = "auto"
    @Published var needDownload = false
    @Published var config: TranslationSession.Configuration?
    @Published var prepareDownload = false

    private var pending = ""
    private var pendingSource = "en"
    private var pendingTarget = "ru"
    private var requestID = UUID()
    private var work: DispatchWorkItem?

    let languages: [(String, String)] = [
        ("auto", "Авто"), ("ru", "Русский"), ("en", "English"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
        ("it", "Italiano"), ("pt", "Português"), ("tr", "Türkçe"),
        ("uk", "Українська"), ("ar", "العربية"), ("zh-Hans", "中文"),
        ("ja", "日本語"), ("ko", "한국어")
    ]

    func name(_ code: String) -> String {
        languages.first { $0.0 == code }?.1 ?? code
    }

    // MARK: Автоперевод

    func scheduleAuto(enabled: Bool) {
        work?.cancel()
        guard enabled else { return }
        let item = DispatchWorkItem { [weak self] in self?.translate() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    func translate() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output = ""; status = ""; error = nil; busy = false
            return
        }
        resolveLanguages(text)
        pending = text
        requestID = UUID()
        error = nil
        needDownload = false
        busy = true
        status = "Перевожу на устройстве…"

        if #available(macOS 26.0, *) {
            runDirect(id: requestID)
        } else {
            runViaTask()
        }
    }

    private func resolveLanguages(_ text: String) {
        let detected = sourceCode == "auto" ? Self.detect(text) : sourceCode
        var target = targetCode == "auto" ? (detected == "ru" ? "en" : "ru") : targetCode
        if target == detected { target = detected == "ru" ? "en" : "ru" }
        pendingSource = detected
        pendingTarget = target
    }

    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        if let raw = recognizer.dominantLanguage?.rawValue {
            let code = raw.lowercased()
            if code.hasPrefix("zh") { return "zh-Hans" }
            if code.count == 2 { return code }
        }
        if text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil { return "ru" }
        if text.range(of: "\\p{Han}", options: .regularExpression) != nil { return "zh-Hans" }
        return "en"
    }

    // MARK: macOS 26+: прямой сеанс без системных диалогов

    @available(macOS 26.0, *)
    private func runDirect(id: UUID) {
        let source = pendingSource
        let target = pendingTarget
        let text = pending
        Task {
            do {
                let session = try TranslationSession(
                    installedSource: Locale.Language(identifier: source),
                    target: Locale.Language(identifier: target))
                let response = try await session.translate(text)
                await MainActor.run { self.finish(response.targetText, id: id) }
            } catch {
                await MainActor.run { self.fail(error, id: id) }
            }
        }
    }

    // MARK: macOS 15–25 и загрузка языков

    func runViaTask() {
        let source = Locale.Language(identifier: pendingSource)
        let target = Locale.Language(identifier: pendingTarget)
        let new = TranslationSession.Configuration(source: source, target: target)
        if config == nil {
            config = new
        } else {
            config?.invalidate()
        }
    }

    /// Кнопка «Скачать языки»: готовим пару через системный запрос и переводим.
    func download() {
        guard !pending.isEmpty else { return }
        prepareDownload = true
        busy = true
        error = nil
        requestID = UUID()
        config = TranslationSession.Configuration(source: Locale.Language(identifier: pendingSource),
                                                  target: Locale.Language(identifier: pendingTarget))
    }

    func handleTaskSession(_ session: TranslationSession) async {
        let id = requestID
        do {
            if prepareDownload { try await session.prepareTranslation() }
            let response = try await session.translate(pending)
            await MainActor.run {
                self.prepareDownload = false
                self.config = nil
                self.finish(response.targetText, id: id)
            }
        } catch {
            await MainActor.run {
                self.prepareDownload = false
                self.config = nil
                self.fail(error, id: id)
            }
        }
    }

    func swap() {
        resolveLanguages(input.isEmpty ? "text" : input)
        let oldSource = pendingSource
        let oldTarget = pendingTarget
        sourceCode = oldTarget
        targetCode = oldSource
        if !output.isEmpty {
            input = output
            output = ""
        }
        translate()
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        status = "Перевод скопирован"
    }

    private func finish(_ text: String, id: UUID) {
        guard id == requestID else { return }
        output = text
        busy = false
        error = nil
        status = "\(name(pendingSource)) → \(name(pendingTarget))"
    }

    private func fail(_ error: Error, id: UUID) {
        guard id == requestID else { return }
        busy = false
        needDownload = true
        self.error = friendly(error)
        status = ""
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("install") || text.lowercased().contains("download")
            || text.lowercased().contains("not available") {
            return "Языковая пара не скачана. Нажми «Скачать языки» — macOS спросит разрешение."
        }
        return text
    }
}

// MARK: - Экран переводчика

struct TranslateView: View {
    @ObservedObject var model = TranslateModel.shared
    @AppStorage("autoTranslate") private var auto = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            controls

            HStack(spacing: 8) {
                inputCard
                outputCard
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .onChange(of: model.input) { _, _ in model.scheduleAuto(enabled: auto) }
        .onChange(of: model.targetCode) { _, _ in model.translate() }
        .onChange(of: model.sourceCode) { _, _ in model.translate() }
        .translationTask(model.config) { session in
            await model.handleTaskSession(session)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Picker("", selection: $model.sourceCode) {
                ForEach(model.languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 116)

            Button {
                model.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .help("Поменять языки местами")

            Picker("", selection: $model.targetCode) {
                ForEach(model.languages.filter { $0.0 != "auto" }, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 116)

            Button(model.busy ? "Перевожу…" : "Перевести") { model.translate() }
                .controlSize(.small)
                .disabled(model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Toggle("На лету", isOn: $auto)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))

            Spacer()

            if let e = model.error {
                Text(e)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.red)
                    .lineLimit(2)
                    .frame(maxWidth: 250, alignment: .trailing)
                Button("Скачать языки") { model.download() }
                    .controlSize(.mini)
            } else if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.faint)
            }
        }
        .controlSize(.small)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("ТЕКСТ") {
                Button("Вставить") { pasteIntoInput() }
                    .controlSize(.mini)
                Button("Очистить") { model.input = "" }
                    .controlSize(.mini)
            }
            PlainTextEditor(text: $model.input)
                .padding(6)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.8))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("ПЕРЕВОД") {
                if model.busy {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                }
                Button(copied ? "Скопировано" : "Копировать") {
                    model.copyOutput()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .controlSize(.mini)
                .disabled(model.output.isEmpty)
                Button("В заметки") {
                    NotesStore.shared.append(model.output)
                }
                .controlSize(.mini)
                .disabled(model.output.isEmpty)
            }
            ScrollView {
                Text(model.output.isEmpty ? placeholder : model.output)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.output.isEmpty ? Theme.faint : Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.075)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.8))
    }

    private var placeholder: String {
        model.busy ? "Перевожу…" : "Перевод появится здесь"
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
                .font(.system(size: 8))
            Text("Перевод идёт на этом Mac, текст никуда не отправляется")
                .font(.system(size: 9))
            Spacer()
            if model.needDownload {
                Text("Пара языков скачивается через системные настройки перевода")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.orange)
            }
        }
        .foregroundStyle(Theme.faint)
    }

    private func header<Actions: View>(_ title: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
            Spacer()
            actions()
        }
        .padding(.bottom, 4)
    }

    private func pasteIntoInput() {
        if let s = NSPasteboard.general.string(forType: .string) { model.input = s }
    }
}
