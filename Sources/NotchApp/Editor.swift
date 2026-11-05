import SwiftUI
import AppKit

/// Текстовое поле без автоисправлений, подчёркиваний ошибок, умных кавычек и подсказок.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.backgroundColor = .clear

        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }

        tv.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ p: PlainTextEditor) { parent = p }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
