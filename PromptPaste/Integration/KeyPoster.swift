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

    static func postCopy(to app: NSRunningApplication? = nil) {
        if shouldUseAppleScript(for: app) {
            postAppleScriptCommandKey(keyChar: "c")
        } else {
            postCommandKey(key: UInt16(kVK_ANSI_C))
        }
    }

    static func postPaste(to app: NSRunningApplication? = nil) {
        if shouldUseAppleScript(for: app) {
            postAppleScriptCommandKey(keyChar: "v")
        } else {
            postCommandKey(key: UInt16(kVK_ANSI_V))
        }
    }

    static func postUndo(to app: NSRunningApplication? = nil) {
        if shouldUseAppleScript(for: app) {
            postAppleScriptCommandKey(keyChar: "z")
        } else {
            postCommandKey(key: UInt16(kVK_ANSI_Z))
        }
    }

    private static func shouldUseAppleScript(for app: NSRunningApplication?) -> Bool {
        guard let bundleID = app?.bundleIdentifier?.lowercased() else { return false }
        return bundleID.contains("safari") || bundleID.contains("webkit")
    }

    private static func postAppleScriptCommandKey(keyChar: String) {
        let script = """
        tell application "System Events"
            keystroke "\(keyChar)" using command down
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    private static func postCommandKey(key: UInt16) {
        // Use HIDSystemState. This is the critical difference for WebKit and VMs.
        // It injects the event at the lowest level of the window server, 
        // completely bypassing session-level virtualization quirks.
        let source = CGEventSource(stateID: .hidSystemState)
        
        let targetKeyCode = CGKeyCode(key)
        let cmdFlag = CGEventFlags.maskCommand
        
        guard let keyCharDown = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: true),
              let keyCharUp = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: false)
        else { return }
        
        keyCharDown.flags = cmdFlag
        keyCharUp.flags = cmdFlag
        
        // Post purely to the HID event tap.
        keyCharDown.post(tap: .cghidEventTap)
        usleep(40_000) // 40ms dwell
        keyCharUp.post(tap: .cghidEventTap)
    }

}
