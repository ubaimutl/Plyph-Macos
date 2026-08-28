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

/// Reads the user's currently selected text from the application that owned the
/// selection when the action was invoked.
///
/// On macOS this is automatic:
/// 1. Prefer the target application's Accessibility element directly.
/// 2. If the app does not expose selected text through Accessibility, reactivate
///    that same app and simulate Cmd+C.
/// 3. Preserve and immediately restore the user's clipboard after capture.
/// 4. If enabled, fall back to already-copied clipboard text when there is no
///    selection at all.
enum SelectionReader {
    static func read(
        settings: SettingsStore, frontApp: NSRunningApplication?
    ) async throws -> Selection {
        // Query the application that owned the selection, not PromptPaste's
        // status menu/palette. A status-menu click can temporarily change the
        // system-wide focused AX element even though the user's selection still
        // exists in the original app.
        if let element = focusedElement(in: frontApp),
            let text = AXElement.selectedText(of: element),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Selection(
                text: text,
                clipboardSnapshot: nil,
                focusedElement: element)
        }

        // Browsers and some custom editors do not expose AXSelectedText. Bring
        // the original app back to the front before sending Cmd+C so the copy
        // event cannot land in PromptPaste's menu or panel.
        return try await readViaExplicitCopy(settings: settings, frontApp: frontApp)
    }

    /// Simulated Cmd+C capture with target-app activation, clipboard
    /// preservation and pasteboard change detection.
    static func readViaExplicitCopy(
        settings: SettingsStore,
        frontApp: NSRunningApplication?
    ) async throws -> Selection {
        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }

        if let frontApp {
            frontApp.activate(options: [.activateIgnoringOtherApps])
            await waitForApp(frontApp, timeout: 1.5)
            // Give the target app time to restore its first responder after the
            // status menu/action palette disappears.
            try? await Task.sleep(nanoseconds: 120_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        let captureElement = focusedElement(in: frontApp)
        let previous = ClipboardStore.snapshot()
        ClipboardStore.clear()
        let clearedCount = ClipboardStore.changeCount
        KeyPoster.postCopy()

        // Wait for the target application to actually publish the selection.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if ClipboardStore.changeCount != clearedCount {
                let text = ClipboardStore.currentString()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Do not leave the user's clipboard replaced by the
                    // temporary selection while the AI request is running.
                    ClipboardStore.restore(previous)
                    return Selection(
                        text: text,
                        clipboardSnapshot: previous,
                        focusedElement: captureElement)
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
                focusedElement: captureElement)
        }

        throw PromptError.selectionCaptureFailed
    }

    /// Gets the focused element from a specific application instead of relying
    /// on the system-wide focused element, which can become PromptPaste while a
    /// status menu or panel is handling the action.
    private static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        guard let app else { return AXElement.focusedElement() }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value)
        guard error == .success, let raw = value else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
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
