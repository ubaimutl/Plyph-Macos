import AppKit
import ApplicationServices
import Foundation

/// The outcome of a selection read.
struct Selection {
    let text: String
    let clipboardSnapshot: ClipboardSnapshot?
    let focusedElement: AXUIElement?
}

/// Reads the user's currently selected text from the application that owned the
/// selection when the action was invoked.
enum SelectionReader {
    static func read(
        settings: SettingsStore, frontApp: NSRunningApplication?
    ) async throws -> Selection {
        if let element = focusedElement(in: frontApp),
            let text = AXElement.selectedText(of: element),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Selection(
                text: text,
                clipboardSnapshot: nil,
                focusedElement: element)
        }

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
            // Wait until the target app (including its sandboxed content process
            // — e.g. Safari's WebContent or Chrome's renderer) has actually
            // restored its first responder. A fixed sleep fails on slower
            // machines or complex pages; AX polling returns as early as possible.
            await AXElement.waitFocusRestored(in: frontApp, timeout: 1.0)
        } else {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        let captureElement = focusedElement(in: frontApp)
        let previous = ClipboardStore.snapshot()
        ClipboardStore.clear()
        let clearedCount = ClipboardStore.changeCount

        // Use the normal HID event path after reactivating the target app. In
        // Safari/Chrome, webpage editors live in separate content processes, so
        // posting Cmd+C only to the browser's main PID misses the actual editor.
        KeyPoster.postCopy()

        // Allow up to 2 s for the content process to respond; complex pages and
        // Electron apps can be slower than native fields.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if ClipboardStore.changeCount != clearedCount {
                let text = ClipboardStore.currentString()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
