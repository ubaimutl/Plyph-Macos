import AppKit
import Foundation

/// The outcome of a selection read.
struct Selection {
    let text: String
    /// Snapshot of the user's clipboard, present only when the explicit-copy
    /// path was used (so it can be restored after a paste-based replacement).
    let clipboardSnapshot: ClipboardSnapshot?
}

/// Reads the user's currently selected text from the frontmost application.
///
/// macOS replacement for the GNOME PRIMARY-selection mechanism:
/// 1. When the app is listed in the compatibility list (`explicit-copy-apps`,
///    Firefox by default) the selection is captured by simulating Cmd+C.
/// 2. Otherwise the Accessibility API is asked for the focused element's
///    selected text (the closest native equivalent of PRIMARY).
/// 3. If enabled by `clipboard-fallback`, the regular clipboard is used when
///    nothing is selected.
///
/// The simulated-copy path saves the clipboard, clears it, issues Cmd+C and
/// waits for the pasteboard's `changeCount` to move instead of arbitrary
/// delays, then reports the snapshot back so the clipboard can be restored.
enum SelectionReader {
    /// Whether the frontmost app matches the compatibility list (substring
    /// matching against bundle id and name, like the GNOME extension).
    static func usesExplicitCopy(frontApp: NSRunningApplication?, allowed: [String]) -> Bool {
        guard let frontApp, !allowed.isEmpty else { return false }
        let identifiers = [
            frontApp.bundleIdentifier ?? "",
            frontApp.localizedName ?? "",
        ]
        .filter { !$0.isEmpty }
        .map { $0.lowercased() }
        return allowed.contains { entry in
            identifiers.contains { $0.contains(entry) }
        }
    }

    static func read(
        settings: SettingsStore, frontApp: NSRunningApplication?
    ) async throws -> Selection {
        let allowed = settings.explicitCopyAppList
        if usesExplicitCopy(frontApp: frontApp, allowed: allowed) {
            return try await readViaExplicitCopy(settings: settings)
        }

        if let text = readViaAX(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Selection(text: text, clipboardSnapshot: nil)
        }

        if settings.clipboardFallback {
            let clipboard = ClipboardStore.currentString()
            if !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Selection(text: clipboard, clipboardSnapshot: nil)
            }
        }
        return Selection(text: "", clipboardSnapshot: nil)
    }

    /// AX path: selected text of the system-wide focused element.
    static func readViaAX() -> String? {
        guard let element = AXElement.focusedElement() else { return nil }
        return AXElement.selectedText(of: element)
    }

    /// Simulated Cmd+C capture with clipboard preservation and change detection.
    static func readViaExplicitCopy(settings: SettingsStore) async throws -> Selection {
        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }
        try? await Task.sleep(nanoseconds: 25_000_000)

        let previous = ClipboardStore.snapshot()
        let startCount = ClipboardStore.changeCount
        ClipboardStore.clear()
        KeyPoster.postCopy()

        // Wait for the copy to actually land: watch changeCount, polling gently.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if ClipboardStore.changeCount != startCount {
                let text = ClipboardStore.currentString()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Keep the snapshot around for restoration after replacement;
                    // the copied selection stays on the clipboard in the meantime.
                    return Selection(text: text, clipboardSnapshot: previous)
                }
            }
        }

        // Nothing was copied: restore the user's clipboard and either fall back
        // to it or fail with the GNOME wording.
        ClipboardStore.restore(previous)
        if settings.clipboardFallback,
            let text = previous?.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Selection(text: text, clipboardSnapshot: nil)
        }
        throw PromptError.selectionCaptureFailed
    }
}
