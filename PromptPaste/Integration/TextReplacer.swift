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
            // Give the target window enough time to restore its first responder.
            // WebKit content views can take a little longer than native fields.
            try? await Task.sleep(nanoseconds: 180_000_000)
        }

        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }

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

        // Safari/WebKit and Chromium page editors live in separate content
        // processes. Posting Cmd+V to Safari's/Chrome's main PID only reaches
        // native browser UI such as the address bar. Since the target app has
        // already been reactivated above, a normal HID event is delivered to
        // the actual focused page editor, regardless of which helper PID owns it.
        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        try? await Task.sleep(nanoseconds: 60_000_000)
        KeyPoster.postPaste()

        try? await Task.sleep(nanoseconds: 500_000_000)
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        return false
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
