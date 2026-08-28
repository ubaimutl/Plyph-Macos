import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// Prefer the exact Accessibility element captured with the selection. When an
/// app (notably Safari/WebKit content) does not allow AXSelectedText writes,
/// fall back to Cmd+V posted directly to the target process.
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
            try? await Task.sleep(nanoseconds: 100_000_000)
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

        // Safari and many web editors expose the selection for reading but do
        // not make AXSelectedText writable. Paste is the universal fallback.
        // Address the event to the target process so PromptPaste's own panel or
        // status menu cannot accidentally receive it.
        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        try? await Task.sleep(nanoseconds: 60_000_000)
        KeyPoster.postPaste(to: targetApp?.processIdentifier)

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
