#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// Global shortcuts: Carbon hot keys, which need no permission and work while other apps are in front. All use
/// ⌃⌥⌘ so they stay clear of common window-manager shortcuts (Rectangle uses ⌃⌥).
@MainActor
final class Hotkeys {
    struct Key {
        let code: Int
        let symbol: String
        let title: String
        let action: () -> Void
    }

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let modifierSymbols = "⌃⌥⌘"

    /// The instance the C event handler forwards to.
    private static var current: Hotkeys?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    /// The shortcuts that are live, for the menu.
    private(set) var registered: [Key] = []

    init(_ keys: [Key]) {
        Hotkeys.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { Hotkeys.current?.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            Log.line("hotkeys: event handler not installed (\(status)); shortcuts off")
            return
        }
        for (n, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5852_4453), id: UInt32(n + 1))  // 'XRDS'
            let r = RegisterEventHotKey(UInt32(key.code), Hotkeys.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if r == noErr, let ref {
                refs.append(ref)
                actions[id.id] = key.action
                registered.append(key)
            } else {
                Log.line("hotkeys: \(Hotkeys.modifierSymbols)\(key.symbol) (\(key.title)) not available (\(r)): another app has it")
            }
        }
        Log.line("hotkeys: " + registered.map { "\(Hotkeys.modifierSymbols)\($0.symbol) \($0.title)" }.joined(separator: ", "))
    }
}
#endif
