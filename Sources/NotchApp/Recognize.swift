import SwiftUI
import AppKit
import Vision
import Speech
import AVFoundation
import UniformTypeIdentifiers

/// Собирает все готовые фрагменты длинной записи и отдаёт текст целиком в конце
final class SpeechCollector: NSObject, SFSpeechRecognitionTaskDelegate {
    private var parts: [String] = []
    private let done: (String, Error?) -> Void

    init(done: @escaping (String, Error?) -> Void) { self.done = done }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask,
                               didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        parts.append(recognitionResult.bestTranscription.formattedString)
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        let text = parts.joined(separator: " ")
        let err = successfully ? nil : task.error
        DispatchQueue.main.async { self.done(text, err) }
    }
}

/// Скриншот, картинка, голос и видео → текст. Всё на устройстве.
final class RecognizeService: ObservableObject {
    static let shared = RecognizeService()
    @Published var result = ""
    @Published var status = ""
    @Published var busy = false
    @Published var recording = false
    @Published var lang = "ru-RU"
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()

    private var recorder: AVAudioRecorder?
    private var recURL: URL?
    private var task: SFSpeechRecognitionTask?
    private var collector: SpeechCollector?

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notch_\(UUID().uuidString).\(ext)")
    }

    private func finish(_ text: String, _ msg: String) {
        result = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        status = msg
        busy = false
    }

    // MARK: Скриншот → текст

    func screenshot(delay: Int = 0) {
        screenAllowed = CGPreflightScreenCaptureAccess()
        if !screenAllowed {
            status = "Нужно разрешение «Запись экрана»: Настройки → Конфиденциальность → Запись экрана"
            CGRequestScreenCaptureAccess()
            screenAllowed = CGPreflightScreenCaptureAccess()
        }
        let run = { [weak self] in
            guard let self else { return }
            let path = self.tempURL("png").path
            self.busy = true
            self.status = "Выдели область экрана (Esc — отмена)"
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-x", path]
                do { try p.run(); p.waitUntilExit() } catch {}

                var text = ""
                if let img = NSImage(contentsOfFile: path),
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = self.ocr(cg)
                }
                try? FileManager.default.removeItem(atPath: path)
                DispatchQueue.main.async {
                    if text.isEmpty {
                        self.busy = false
                        self.status = "Текст не найден или снимок отменён"
                    } else {
                        self.finish(text, "Текст со скриншота скопирован в буфер")
                    }
                }
            }
        }
        if delay > 0 {
            status = "Скриншот через \(delay) с — переключись на нужное окно"
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: run)
        } else {
            run()
        }
    }

    // MARK: Картинка из буфера / файла

    func ocrPasteboard() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .tiff) ?? pb.data(forType: .png) ?? pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
              let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            status = "В буфере обмена нет картинки"
            return
        }
        busy = true
        status = "Распознаю картинку из буфера…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = self.ocr(cg)
            DispatchQueue.main.async {
                if text.isEmpty {
                    self.busy = false
                    self.status = "На картинке не нашлось текста"
                } else {
                    self.finish(text, "Текст с картинки скопирован в буфер")
                }
            }
        }
    }

    func recognizeImage(_ url: URL) {
        busy = true
        status = "Распознаю «\(url.lastPathComponent)»…"
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            if let img = NSImage(contentsOf: url),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                text = self.ocr(cg)
            }
            DispatchQueue.main.async {
                if text.isEmpty {
                    self.busy = false
                    self.status = "Не удалось прочитать картинку"
                } else {
                    self.finish(text, "Текст с картинки скопирован в буфер")
                }
            }
        }
    }

    private func ocr(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["ru-RU", "en-US"]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    // MARK: Голос → текст

    func toggleRecording() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    self.status = "Нет доступа к микрофону: Настройки → Конфиденциальность → Микрофон"
                    return
                }
                let url = self.tempURL("m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16000.0,
                    AVNumberOfChannelsKey: 1
                ]
                do {
                    let r = try AVAudioRecorder(url: url, settings: settings)
                    r.record()
                    self.recorder = r
                    self.recURL = url
                    self.recording = true
                    self.status = "Идёт запись… нажми «Стоп», чтобы получить текст"
                } catch {
                    self.status = "Не удалось начать запись"
                }
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        recording = false
        guard let url = recURL else { return }
        recURL = nil
        busy = true
        withSpeechAccess { self.recognize(url) }
    }

    // MARK: Файл (аудио, видео, голосовые) → текст

    func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Выбери картинку, аудио, видео или голосовое сообщение"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { transcribeFile(url) }
    }

    private func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "webp", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    func transcribeFile(_ url: URL) {
        if isImage(url) { recognizeImage(url); return }
        busy = true
        status = "Готовлю аудио из «\(url.lastPathComponent)»…"
        withSpeechAccess {
            self.prepareAudio(url) { audio in
                guard let audio else {
                    self.busy = false
                    self.status = "Не удалось прочитать файл. Для .ogg/.opus/.webm установи ffmpeg: brew install ffmpeg"
                    return
                }
                self.recognize(audio)
            }
        }
    }

    private func withSpeechAccess(_ then: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                if st == .authorized {
                    then()
                } else {
                    self.busy = false
                    self.status = "Нет доступа к распознаванию речи: Настройки → Конфиденциальность → Распознавание речи"
                }
            }
        }
    }

    /// Достаём звуковую дорожку в m4a. Форматы, которые macOS не читает (ogg из Telegram и т.п.), — через ffmpeg.
    private func prepareAudio(_ src: URL, _ done: @escaping (URL?) -> Void) {
        let exotic = ["ogg", "oga", "opus", "webm", "mkv"].contains(src.pathExtension.lowercased())
        if exotic { ffmpegConvert(src, done); return }

        let out = tempURL("m4a")
        guard let ex = AVAssetExportSession(asset: AVURLAsset(url: src),
                                            presetName: AVAssetExportPresetAppleM4A) else {
            ffmpegConvert(src, done)
            return
        }
        ex.outputURL = out
        ex.outputFileType = .m4a
        ex.exportAsynchronously {
            let ok = ex.status == .completed
            DispatchQueue.main.async {
                if ok { done(out) } else { self.ffmpegConvert(src, done) }
            }
        }
    }

    private func ffmpegConvert(_ src: URL, _ done: @escaping (URL?) -> Void) {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ff = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            done(nil)
            return
        }
        let out = tempURL("wav")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ff)
            p.arguments = ["-y", "-i", src.path, "-vn", "-ac", "1", "-ar", "16000", out.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            DispatchQueue.main.async { done(ok ? out : nil) }
        }
    }

    private func recognize(_ audio: URL) {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: lang)), rec.isAvailable else {
            busy = false
            status = "Распознавание речи для этого языка сейчас недоступно"
            return
        }
        let req = SFSpeechURLRecognitionRequest(url: audio)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        status = rec.supportsOnDeviceRecognition
            ? "Распознаю речь на устройстве…"
            : "Распознаю через сервер Apple (длинные записи могут обрезаться)…"

        let c = SpeechCollector { [weak self] text, error in
            guard let self else { return }
            self.collector = nil
            self.task = nil
            try? FileManager.default.removeItem(at: audio)
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                self.busy = false
                self.status = "Речь не распознана" + (error.map { ": \($0.localizedDescription)" } ?? "")
            } else {
                self.finish(t, "Текст распознан и скопирован в буфер")
            }
        }
        collector = c
        task = rec.recognitionTask(with: req, delegate: c)
    }
}

// MARK: - Экран

struct RecognizeView: View {
    @ObservedObject var r = RecognizeService.shared
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            actions
                .frame(width: 210)
            resultPanel
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            actionRow("Скриншот → текст", icon: "text.viewfinder", tint: Theme.accent) {
                r.screenshot()
            } trailing: {
                Menu {
                    Button("Сразу") { r.screenshot() }
                    Button("Через 3 секунды") { r.screenshot(delay: 3) }
                    Button("Через 5 секунд") { r.screenshot(delay: 5) }
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }

            actionRow("Картинка из буфера", icon: "photo.on.rectangle", tint: Theme.green) {
                r.ocrPasteboard()
            } trailing: { EmptyView() }

            actionRow(r.recording ? "Стоп и распознать" : "Голос → текст",
                      icon: r.recording ? "stop.circle.fill" : "mic.fill",
                      tint: r.recording ? Theme.red : Theme.orange) {
                r.toggleRecording()
            } trailing: { EmptyView() }

            actionRow("Файл → текст", icon: "film", tint: Color.purple.opacity(0.9)) {
                r.pickFile()
            } trailing: { EmptyView() }

            HStack(spacing: 6) {
                Text("Язык речи")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.faint)
                Picker("", selection: $r.lang) {
                    Text("Русский").tag("ru-RU")
                    Text("English").tag("en-US")
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 110)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(targeted ? Theme.accent : Theme.stroke,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [5]))
                VStack(spacing: 2) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    Text("Перетащи картинку,\nвидео или голосовое")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 40)
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { obj, _ in
                    var url: URL?
                    if let d = obj as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = obj as? URL { url = u }
                    if let url {
                        DispatchQueue.main.async { RecognizeService.shared.transcribeFile(url) }
                    }
                }
                return true
            }

            if !r.screenAllowed {
                Text("Нужно разрешение «Запись экрана»")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .disabled(r.busy && !r.recording)
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if r.busy { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                Text(r.status.isEmpty ? "Результат появится здесь и сразу скопируется" : r.status)
                    .font(.system(size: 10))
                    .foregroundStyle(r.status.isEmpty ? Theme.faint : Theme.dim)
                    .lineLimit(2)
                Spacer()
                if r.recording {
                    Circle().fill(Theme.red).frame(width: 6, height: 6)
                    Text("запись")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.red)
                }
            }
            ScrollView {
                Text(r.result)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.8))

            HStack(spacing: 5) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.result, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Копировать")
                Button {
                    TranslateModel.shared.input = r.result
                    NotchState.shared.tab = .translate
                } label: {
                    Image(systemName: "character.bubble")
                }
                .help("Перевести")
                Button {
                    NotesStore.shared.append(r.result)
                } label: {
                    Image(systemName: "note.text")
                }
                .help("В заметки")
                Spacer()
                Text("\(r.result.count) симв.")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
            }
            .controlSize(.mini)
            .disabled(r.result.isEmpty)
        }
    }

    private func actionRow<Trailing: View>(_ title: String, icon: String, tint: Color,
                                           action: @escaping () -> Void,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
    }
}
