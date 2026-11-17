import AppKit
import Carbon.HIToolbox

/// ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z в окнах чёлки.
/// У фонового приложения (без иконки в Dock) нет меню «Правка», а именно оно в macOS
/// доставляет эти сочетания до полей ввода — поэтому ⌘V «не работал».
/// Клавиши берём по физическому месту (keyCode), а не по букве: в русской раскладке
/// ⌘V приходит как «⌘м», и проверка по символу его бы пропустила.
enum EditShortcuts {
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        var action: Selector?

        if flags == .command {
            switch key {
            case kVK_ANSI_X: action = #selector(NSText.cut(_:))
            case kVK_ANSI_C: action = #selector(NSText.copy(_:))
            case kVK_ANSI_V: action = #selector(NSText.paste(_:))
            case kVK_ANSI_A: action = #selector(NSText.selectAll(_:))
            case kVK_ANSI_Z: action = Selector(("undo:"))
            default: break
            }
        } else if flags == [.command, .shift] && key == kVK_ANSI_Z {
            action = Selector(("redo:"))
        } else if flags == [.command, .shift, .option] && key == kVK_ANSI_V {
            action = #selector(NSTextView.pasteAsPlainText(_:))
        }

        guard let action, let responder = window.firstResponder else { return false }
        return responder.tryToPerform(action, with: window)
    }
}

/// Обычное окно раздела, в котором работают ⌘C/⌘V и остальные сочетания правки.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditShortcuts.handle(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
