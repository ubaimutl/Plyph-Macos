import AppKit
import Foundation

/// Replaces the current selection in the target app.
///
/// macOS replacement for the GNOME paste-back mechanism:
/// 1. Preferred: set the focused element's selected text directly through the
///    Accessibility API (no clipboard involvement at all).
/// 2. Fallback: write the result to the pasteboard and simulate Cmd+V.
///
/// When a clipboard snapshot was taken while capturing the selection (or the
/// paste path is used and the user had clipboard content), it is restored after
/// the replacement so the user's clipboard is not destroyed.
enum TextReplacer {
    /// Ensures the target app is frontmost (relevant after the preview window
    /// took focus) and replaces the selection. Returns true when the AX path
    /// was used, false when the paste fallback ran.
    @discardableResult
    static func replace(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?
    ) async throws -> Bool {
        if let targetApp, targetApp != NSWorkspace.shared.frontmostApplication {
            targetApp.activate()
            await waitForApp(targetApp, timeout: 1.5)
        }

        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }
        try? await Task.sleep(nanoseconds: 25_000_000)

        if let element = AXElement.focusedElement(),
            AXElement.selectedTextSettable(element),
            AXElement.setSelectedText(element, to: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        // Paste fallback.
        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        KeyPoster.postPaste()
        // Give the target app a moment to consume the pasteboard, then restore
        // the user's clipboard — unless the user changed it in the meantime.
        try? await Task.sleep(nanoseconds: 300_000_000)
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
            if NSWorkspace.shared.frontmostApplication == app {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
