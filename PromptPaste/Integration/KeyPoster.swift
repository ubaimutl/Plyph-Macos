import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Posts keyboard events to the system (Cmd+C / Cmd+V / Cmd+Z) and waits for
/// the user to release modifier keys before doing so, mirroring the GNOME
/// extension's virtual keyboard behavior. Requires Accessibility permission.
enum KeyPoster {
    /// Whether any of the user-facing modifiers is currently held down.
    static func modifiersHeld() -> Bool {
        // Read on the main thread; NSEvent modifier state is main-thread state.
        if Thread.isMainThread {
            return held(NSEvent.modifierFlags)
        }
        return DispatchQueue.main.sync { held(NSEvent.modifierFlags) }
    }

    private static func held(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return !flags.intersection(relevant).isEmpty
    }

    /// Polls until all modifier keys are released (the GNOME version does the
    /// same before simulating keys). Returns false on timeout.
    static func waitModifiersReleased(timeout: TimeInterval = 1.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !modifiersHeld() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Posts Cmd+C.
    static func postCopy() {
        postCommand(UInt16(kVK_ANSI_C))
    }

    /// Posts Cmd+V.
    static func postPaste() {
        postCommand(UInt16(kVK_ANSI_V))
    }

    /// Posts Cmd+Z.
    static func postUndo() {
        postCommand(UInt16(kVK_ANSI_Z))
    }

    private static func postCommand(_ key: UInt16) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)
        down?.flags = [.maskCommand]
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
        up?.flags = [.maskCommand]
        up?.post(tap: .cghidEventTap)
    }
}
