import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// The preview window temporarily becomes key, so asking only for the current
/// focused AX element after preview is unreliable. Prefer the exact element
/// captured with the original selection, then fall back to the newly focused
/// element, then finally to Cmd+V.
enum TextReplacer {
    /// Ensures the target app is frontmost and replaces the original selection.
    /// Returns true when an Accessibility path was used, false when paste was
    /// required.
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
            // Give AppKit a short moment to restore the target app's responder.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }

        // Best path: write back to the exact element that owned the selection
        // before PromptPaste's preview took focus.
        if let sourceElement,
            AXElement.selectedTextSettable(sourceElement),
            AXElement.setSelectedText(sourceElement, to: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        // If the original element was not retained (for example when capture
        // needed Cmd+C), try the current focused element after reactivation.
        if let element = AXElement.focusedElement(),
            AXElement.selectedTextSettable(element),
            AXElement.setSelectedText(element, to: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        // Universal fallback: paste into the restored target application.
        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        try? await Task.sleep(nanoseconds: 50_000_000)
        KeyPoster.postPaste()

        // Let the target app consume the pasteboard before restoring it.
        try? await Task.sleep(nanoseconds: 450_000_000)
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        return false
    }

    /// Sends Cmd+Z to the frontmost app (used by the undo controller).
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
