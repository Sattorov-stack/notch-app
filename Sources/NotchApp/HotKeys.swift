import AppKit
import Carbon.HIToolbox

/// Глобальные горячие клавиши через Carbon: работают из любого приложения
/// и не требуют «Универсального доступа».
///   ⌃⌥N — открыть/закрыть меню, ⌃⌥T — текст со скриншота,
///   ⌃⌥C — пипетка.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandler()
        actions[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4E54_4348), id: id)   // 'NTCH'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotKeys.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
