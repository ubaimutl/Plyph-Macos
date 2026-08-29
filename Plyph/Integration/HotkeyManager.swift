import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers and unregisters the global shortcuts (Correct, Rewrite, Open
/// actions) with Carbon's `RegisterEventHotKey`, re-registering automatically
/// when the user changes them in settings. Shortcuts are not hardcoded: any
/// combination can be recorded in Settings › Shortcuts, and none are set by
/// default (matching the GNOME extension).
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Identifier: UInt32 {
        case correct = 1
        case rewrite = 2
        case actions = 3
    }

    var onHotKey: ((Identifier) -> Void)?

    private var registered: [Identifier: EventHotKeyRef?] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x5050_5354  // "PPST"

    private init() {}

    /// Installs the Carbon handler once and (re)registers the current shortcuts.
    func refresh() {
        installHandlerIfNeeded()
        unregisterAll()

        let settings = SettingsStore.shared
        register(combo: settings.correctShortcut, id: .correct)
        register(combo: settings.rewriteShortcut, id: .rewrite)
        register(combo: settings.actionsShortcut, id: .actions)
    }

    private func register(combo: HotKeyCombo, id: Identifier) {
        guard !combo.isEmpty, !registered.keys.contains(id) else { return }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: HotkeyManager.signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref)
        if status == noErr {
            registered[id] = ref
        }
    }

    private func unregisterAll() {
        for (_, ref) in registered {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        registered.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let parameterError = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard parameterError == noErr else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData).takeUnretainedValue()
                let identifier = Identifier(rawValue: hotKeyID.id)
                DispatchQueue.main.async {
                    if let identifier {
                        manager.onHotKey?(identifier)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            context,
            nil)
        handlerInstalled = (status == noErr)
    }
}
