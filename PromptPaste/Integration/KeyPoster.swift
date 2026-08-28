import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

/// Lightweight persistent diagnostics for replacement/capture problems.
/// The log intentionally records metadata (apps, AX roles, result codes and
/// text lengths) rather than the user's actual selected/generated text.
enum PromptPasteDebug {
    private static let queue = DispatchQueue(label: "com.ubaimutl.PromptPaste.debug-log")

    static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PromptPaste", isDirectory: true)
        .appendingPathComponent("debug.log", isDirectory: false)

    static func newSession() -> String {
        String(UUID().uuidString.prefix(8))
    }

    static func log(_ message: String, session: String? = nil) {
        guard SettingsStore.shared.enableDebugLogging else { return }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let sessionPart = session.map { " [\($0)]" } ?? ""
        let line = "\(timestamp)\(sessionPart) \(message)\n"

        NSLog("[PromptPasteDebug]%@ %@", sessionPart, message)

        queue.async {
            do {
                let directory = logURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)

                guard let data = line.data(using: .utf8) else { return }
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                NSLog("[PromptPasteDebug] Failed to write debug log: %@", error.localizedDescription)
            }
        }
    }

    static func appSummary(_ app: NSRunningApplication?) -> String {
        guard let app else { return "<nil app>" }
        return "name=\(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) active=\(app.isActive)"
    }

    static func frontmostSummary() -> String {
        appSummary(NSWorkspace.shared.frontmostApplication)
    }

    static func elementSummary(_ element: AXUIElement?) -> String {
        guard let element else { return "<nil element>" }

        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)

        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? "?"
        let description = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? "?"
        let selectedLength = stringAttribute(element, kAXSelectedTextAttribute as CFString)?.count

        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable)

        var markerRange: CFTypeRef?
        let markerError = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange)

        return "pid=\(pid) role=\(role) subrole=\(subrole) desc=\(description) selectedLen=\(selectedLength.map(String.init) ?? "nil") selectedSettable=\(settableError == .success && settable.boolValue) markerRange=\(markerError)"
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

/// Posts keyboard events to the system (Cmd+C / Cmd+V / Cmd+Z) and waits for
/// the user to release modifier keys before doing so.
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

    @discardableResult
    static func postCopy(
        to app: NSRunningApplication? = nil,
        debugSession: String? = nil
    ) -> Bool {
        let useAppleScript = shouldUseAppleScript(for: app)
        PromptPasteDebug.log(
            "postCopy route=\(useAppleScript ? "SystemEvents" : "CGEvent") target={\(PromptPasteDebug.appSummary(app))} frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)
        if useAppleScript {
            return postAppleScriptCommandKey(keyChar: "c", debugSession: debugSession)
        }
        return postCommandKey(key: UInt16(kVK_ANSI_C), debugSession: debugSession)
    }

    @discardableResult
    static func postPaste(
        to app: NSRunningApplication? = nil,
        debugSession: String? = nil
    ) -> Bool {
        let useAppleScript = shouldUseAppleScript(for: app)
        PromptPasteDebug.log(
            "postPaste route=\(useAppleScript ? "SystemEvents" : "CGEvent") target={\(PromptPasteDebug.appSummary(app))} frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)
        if useAppleScript {
            return postAppleScriptCommandKey(keyChar: "v", debugSession: debugSession)
        }
        return postCommandKey(key: UInt16(kVK_ANSI_V), debugSession: debugSession)
    }

    /// Forces a normal System Events Cmd+V regardless of the target bundle.
    /// This is used for browser/web-content editors because several browser AX
    /// bridges report successful direct text writes without changing the DOM.
    @discardableResult
    static func postPasteUsingSystemEvents(debugSession: String? = nil) -> Bool {
        PromptPasteDebug.log(
            "postPaste route=SystemEvents(forced) frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)
        return postAppleScriptCommandKey(keyChar: "v", debugSession: debugSession)
    }

    @discardableResult
    static func postUndo(
        to app: NSRunningApplication? = nil,
        debugSession: String? = nil
    ) -> Bool {
        let useAppleScript = shouldUseAppleScript(for: app)
        if useAppleScript {
            return postAppleScriptCommandKey(keyChar: "z", debugSession: debugSession)
        }
        return postCommandKey(key: UInt16(kVK_ANSI_Z), debugSession: debugSession)
    }

    private static func shouldUseAppleScript(for app: NSRunningApplication?) -> Bool {
        guard let bundleID = app?.bundleIdentifier?.lowercased() else { return false }
        return bundleID.contains("safari") || bundleID.contains("webkit")
    }

    @discardableResult
    private static func postAppleScriptCommandKey(
        keyChar: String,
        debugSession: String?
    ) -> Bool {
        let script = """
        tell application "System Events"
            keystroke "\(keyChar)" using command down
        end tell
        """

        PromptPasteDebug.log(
            "System Events AppleScript BEGIN key=\(keyChar) frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            PromptPasteDebug.log(
                "System Events AppleScript FAILED: NSAppleScript(source:) returned nil",
                session: debugSession)
            return false
        }

        let result = appleScript.executeAndReturnError(&error)
        if let error {
            PromptPasteDebug.log(
                "System Events AppleScript FAILED error=\(String(describing: error)) frontmost={\(PromptPasteDebug.frontmostSummary())}",
                session: debugSession)
            return false
        }

        PromptPasteDebug.log(
            "System Events AppleScript SUCCESS descriptor=\(result.stringValue ?? "<no string result>") frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)
        return true
    }

    @discardableResult
    private static func postCommandKey(
        key: UInt16,
        debugSession: String?
    ) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let targetKeyCode = CGKeyCode(key)
        let cmdFlag = CGEventFlags.maskCommand

        guard
            let keyCharDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: targetKeyCode,
                keyDown: true),
            let keyCharUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: targetKeyCode,
                keyDown: false)
        else {
            PromptPasteDebug.log(
                "CGEvent FAILED to create key events keyCode=\(key)",
                session: debugSession)
            return false
        }

        keyCharDown.flags = cmdFlag
        keyCharUp.flags = cmdFlag
        keyCharDown.post(tap: .cghidEventTap)
        usleep(40_000)
        keyCharUp.post(tap: .cghidEventTap)

        PromptPasteDebug.log(
            "CGEvent POSTED keyCode=\(key) frontmost={\(PromptPasteDebug.frontmostSummary())}",
            session: debugSession)
        return true
    }
}
