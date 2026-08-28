import AppKit
import ApplicationServices
import Foundation

/// The outcome of a selection read.
struct Selection {
    let text: String
    /// Snapshot of the user's clipboard when Cmd+C fallback was needed, so it
    /// can be restored after replacement.
    let clipboardSnapshot: ClipboardSnapshot?
    /// The exact Accessibility element that owned the original selection.
    /// Keeping this lets replacement target the original field even after the
    /// preview window temporarily takes focus.
    let focusedElement: AXUIElement?
}

/// Reads the user's currently selected text from the frontmost application.
///
/// On macOS this is automatic:
/// 1. Prefer the Accessibility API and remember the exact focused element.
/// 2. If the app does not expose selected text through Accessibility, simulate
///    Cmd+C, read the pasteboard, and preserve the user's previous clipboard.
/// 3. If enabled, fall back to already-copied clipboard text when there is no
///    selection at all.
enum SelectionReader {
    static func read(
        settings: SettingsStore, frontApp: NSRunningApplication?
    ) async throws -> Selection {
        if let element = AXElement.focusedElement(),
            let text = AXElement.selectedText(of: element),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Selection(
                text: text,
                clipboardSnapshot: nil,
                focusedElement: element)
        }

        // Accessibility support varies by app (notably browsers and web
        // content). Fall back automatically instead of exposing an app list in
        // Settings.
        return try await readViaExplicitCopy(settings: settings)
    }

    /// Simulated Cmd+C capture with clipboard preservation and change detection.
    static func readViaExplicitCopy(settings: SettingsStore) async throws -> Selection {
        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }
        try? await Task.sleep(nanoseconds: 40_000_000)

        let previous = ClipboardStore.snapshot()
        ClipboardStore.clear()
        let clearedCount = ClipboardStore.changeCount
        KeyPoster.postCopy()

        // Wait for the target application to actually publish the selection.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if ClipboardStore.changeCount != clearedCount {
                let text = ClipboardStore.currentString()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return Selection(
                        text: text,
                        clipboardSnapshot: previous,
                        focusedElement: nil)
                }
            }
        }

        ClipboardStore.restore(previous)

        if settings.clipboardFallback,
            let text = previous?.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Selection(
                text: text,
                clipboardSnapshot: nil,
                focusedElement: nil)
        }

        throw PromptError.selectionCaptureFailed
    }
}
