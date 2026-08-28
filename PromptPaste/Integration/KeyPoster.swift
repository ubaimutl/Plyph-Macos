import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

/// Posts keyboard events to the system (Cmd+C / Cmd+V / Cmd+Z) and waits for
/// the user to release modifier keys before doing so. When a target process is
/// known, events are posted directly to that process; this is substantially
/// more reliable for Safari/WebKit and other apps when PromptPaste owns a menu
/// or floating panel at the time the action runs.
enum KeyPoster {
    /// Whether any of the user-facing modifiers is currently held down.
    static func modifiersHeld() -> Bool {
        if Thread.isMainThread {
            return held(NSEvent.modifierFlags)
        }
        return DispatchQueue.main.sync { held(NSEvent.modifierFlags) }
    }

    private static func held(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return !flags.intersection(relevant).isEmpty
    }

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

    static func postCopy(to processIdentifier: pid_t? = nil) {
        postCommandKey(key: UInt16(kVK_ANSI_C), to: processIdentifier)
    }

    static func postPaste(to processIdentifier: pid_t? = nil) {
        postCommandKey(key: UInt16(kVK_ANSI_V), to: processIdentifier)
    }

    static func postUndo(to processIdentifier: pid_t? = nil) {
        postCommandKey(key: UInt16(kVK_ANSI_Z), to: processIdentifier)
    }

    private static func postCommandKey(key: UInt16, to processIdentifier: pid_t?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let cmdKeyCode = CGKeyCode(kVK_Command)
        let targetKeyCode = CGKeyCode(key)

        let cmdFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true)
        let keyCharDown = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: true)
        let keyCharUp = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false)

        cmdDown?.flags = cmdFlag
        keyCharDown?.flags = cmdFlag
        keyCharUp?.flags = cmdFlag
        cmdUp?.flags = []

        post(cmdDown, to: processIdentifier)
        usleep(20_000)
        post(keyCharDown, to: processIdentifier)
        usleep(35_000)
        post(keyCharUp, to: processIdentifier)
        usleep(20_000)
        post(cmdUp, to: processIdentifier)
        usleep(20_000)
    }

    private static func post(_ event: CGEvent?, to processIdentifier: pid_t?) {
        guard let event else { return }
        if let processIdentifier {
            event.postToPid(processIdentifier)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }
}
