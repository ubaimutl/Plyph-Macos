import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// Native AppKit controls are replaced through Accessibility. Safari webpage
/// editors are different: AX calls can report success without changing the DOM,
/// so after native AX replacement fails we use the clipboard + System Events
/// paste path directly. This matches the paste mechanism verified to work in
/// Safari web editors and avoids false-success short circuits.
enum TextReplacer {
    @discardableResult
    static func replace(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        sourceElement: AXUIElement?
    ) async throws -> Bool {
        let safariLike = isSafariLike(targetApp)

        if let targetApp {
            targetApp.activate(options: [.activateIgnoringOtherApps])
            await waitForApp(targetApp, timeout: 1.5)

            // Do not force Safari's AX focused/main window here. Its webpage
            // editor owns focus inside WebKit, and changing the native window
            // focus is unnecessary for the System Events paste path below.
            if !safariLike {
                let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
                var mainWindowRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    appElement,
                    kAXMainWindowAttribute as CFString,
                    &mainWindowRef
                ) == .success,
                   let mainWindow = mainWindowRef {
                    AXUIElementSetAttributeValue(
                        appElement,
                        kAXFocusedWindowAttribute as CFString,
                        mainWindow)
                    AXUIElementSetAttributeValue(
                        unsafeBitCast(mainWindow, to: AXUIElement.self),
                        kAXMainAttribute as CFString,
                        true as CFTypeRef)
                }
            }

            try? await Task.sleep(nanoseconds: safariLike ? 120_000_000 : 200_000_000)
        }

        guard await KeyPoster.waitModifiersReleased() else {
            throw PromptError.releaseShortcutKeys
        }

        // Tier 1: direct AX replacement. This keeps Safari's native search/address
        // fields and normal AppKit controls on the fast, clipboard-free path.
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

        // Safari webpage editors: do not trust AXTextOperation or AX menu return
        // codes as proof that the DOM changed. Go straight to the mechanism that
        // is known to work: write the replacement, then have System Events issue
        // Cmd+V while Safari is frontmost. KeyPoster chooses AppleScript for
        // Safari/WebKit targets.
        if safariLike {
            ClipboardStore.write(text)
            let writtenCount = ClipboardStore.changeCount
            try? await Task.sleep(nanoseconds: 100_000_000)
            KeyPoster.postPaste(to: targetApp)

            try? await Task.sleep(nanoseconds: 700_000_000)
            if snapshot != nil && ClipboardStore.changeCount == writtenCount {
                ClipboardStore.restore(snapshot)
            }
            return true
        }

        // Non-Safari apps retain the existing compatibility tiers.
        if let sourceElement,
            AXElement.performWebKitTextOperationReplace(element: sourceElement, text: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        if let element = AXElement.focusedElement(),
            AXElement.performWebKitTextOperationReplace(element: element, text: text)
        {
            ClipboardStore.restore(snapshot)
            return true
        }

        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        try? await Task.sleep(nanoseconds: 50_000_000)

        var pastedViaMenu = false
        if let targetApp {
            pastedViaMenu = await AXMenuAction.performPaste(in: targetApp)
        }

        if !pastedViaMenu {
            KeyPoster.postPaste(to: targetApp)
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        return true
    }

    static func sendUndo(to targetApp: NSRunningApplication?) async {
        guard await KeyPoster.waitModifiersReleased() else { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
        KeyPoster.postUndo(to: targetApp)
    }

    private static func isSafariLike(_ app: NSRunningApplication?) -> Bool {
        guard let bundleID = app?.bundleIdentifier?.lowercased() else { return false }
        return bundleID.contains("safari") || bundleID.contains("webkit")
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
