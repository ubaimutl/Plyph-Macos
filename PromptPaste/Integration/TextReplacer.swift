import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// Prefer the exact Accessibility element captured with the selection. When an
/// app (notably Safari/WebKit content) does not allow AXSelectedText writes,
/// reactivate the owning app and fall back to a normal Cmd+V event. Posting the
/// event globally is intentional: Safari, Chrome and other multi-process apps
/// host page editors in helper/content processes rather than the main app PID.
enum TextReplacer {
    @discardableResult
    static func replace(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        sourceElement: AXUIElement?
    ) async throws -> Bool {
        if let targetApp {
            targetApp.activate(options: [.activateIgnoringOtherApps])
            await waitForApp(targetApp, timeout: 1.5)
            // Settle time for WebKit / Chromium DOM focus re-activation
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms
        }

        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }

        // Tier 1: Try direct AX text replacement first (native fields, address bar)
        if let sourceElement,
            AXElement.selectedTextSettable(sourceElement),
            AXElement.setSelectedText(sourceElement, to: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        if let element = AXElement.focusedElement(),
            AXElement.selectedTextSettable(element),
            AXElement.setSelectedText(element, to: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        // Tier 2: Universal Clipboard-based replacement (Safari WebKit, Chrome, Firefox, Electron, VS Code)
        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Execute paste (AppleScript System Events + CGEvent session/HID taps)
        KeyPoster.postPaste(to: targetApp?.processIdentifier)

        // Allow target app time to process the paste event before restoring
        // previous clipboard contents.
        try? await Task.sleep(nanoseconds: 700_000_000) // 700ms
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        return true
    }

    static func sendUndo() async {
        guard await KeyPoster.waitModifiersReleased() else { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
        KeyPoster.postUndo()
    }

    private static func waitForApp(_ app: NSRunningApplication, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
