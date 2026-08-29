import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// Native AppKit controls are replaced through Accessibility. Browser/web
/// content is routed through clipboard + System Events because browser AX
/// bridges can report successful AXSelectedText writes without changing the DOM.
/// Detailed diagnostics are written to ~/Library/Logs/Plyph/debug.log.
enum TextReplacer {
    @discardableResult
    static func replace(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        sourceElement: AXUIElement?
    ) async throws -> Bool {
        let debugSession = PlyphDebug.newSession()
        let browserLike = isBrowserLike(targetApp)
        let sourceInWebArea = sourceElement.map(isInsideWebArea) ?? false

        PlyphDebug.log(
            "REPLACE BEGIN outputLen=\(text.count) browserLike=\(browserLike) sourceInWebArea=\(sourceInWebArea) axTrusted=\(AXAccess.isTrusted) target={\(PlyphDebug.appSummary(targetApp))} frontmost={\(PlyphDebug.frontmostSummary())} source={\(PlyphDebug.elementSummary(sourceElement))} snapshot=\(snapshot != nil)",
            session: debugSession)

        if let targetApp {
            PlyphDebug.log(
                "Activating target app; before frontmost={\(PlyphDebug.frontmostSummary())}",
                session: debugSession)
            targetApp.activate(options: [.activateIgnoringOtherApps])
            await waitForApp(targetApp, timeout: 1.5)
            PlyphDebug.log(
                "Activation wait finished; frontmost={\(PlyphDebug.frontmostSummary())}",
                session: debugSession)

            // Do not force browser/web-content window focus through AX. The
            // webpage editor owns its responder state and System Events only
            // needs the target application to remain frontmost.
            if !browserLike && !sourceInWebArea {
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

            try? await Task.sleep(
                nanoseconds: (browserLike || sourceInWebArea) ? 120_000_000 : 200_000_000)
        }

        let modifiersReleased = await KeyPoster.waitModifiersReleased()
        let currentFocused = AXElement.focusedElement()
        let focusedInWebArea = currentFocused.map(isInsideWebArea) ?? false
        let webContent = browserLike || sourceInWebArea || focusedInWebArea

        PlyphDebug.log(
            "Modifiers released=\(modifiersReleased) webContent=\(webContent) focusedInWebArea=\(focusedInWebArea) frontmost={\(PlyphDebug.frontmostSummary())} currentFocused={\(PlyphDebug.elementSummary(currentFocused))}",
            session: debugSession)
        guard modifiersReleased else {
            PlyphDebug.log("REPLACE ABORT releaseShortcutKeys", session: debugSession)
            throw PromptError.releaseShortcutKeys
        }

        // Browsers and AXWebArea descendants must bypass direct AX writes and
        // AXTextOperation. Safari and Chrome both proved that those APIs can
        // report success while leaving the webpage unchanged.
        if webContent {
            return await pasteWebContent(
                text,
                snapshot: snapshot,
                targetApp: targetApp,
                debugSession: debugSession)
        }

        // Tier 1: direct AX replacement for actual native AppKit controls.
        if let sourceElement {
            let settable = AXElement.selectedTextSettable(sourceElement)
            PlyphDebug.log(
                "Tier1/source settable=\(settable) element={\(PlyphDebug.elementSummary(sourceElement))}",
                session: debugSession)
            if settable {
                let success = AXElement.setSelectedText(sourceElement, to: text)
                PlyphDebug.log(
                    "Tier1/source setSelectedText success=\(success)",
                    session: debugSession)
                if success {
                    ClipboardStore.restore(snapshot)
                    PlyphDebug.log("REPLACE END via Tier1/source", session: debugSession)
                    return true
                }
            }
        } else {
            PlyphDebug.log("Tier1/source skipped: sourceElement=nil", session: debugSession)
        }

        if let currentFocused {
            let settable = AXElement.selectedTextSettable(currentFocused)
            PlyphDebug.log(
                "Tier1/focused settable=\(settable) element={\(PlyphDebug.elementSummary(currentFocused))}",
                session: debugSession)
            if settable {
                let success = AXElement.setSelectedText(currentFocused, to: text)
                PlyphDebug.log(
                    "Tier1/focused setSelectedText success=\(success)",
                    session: debugSession)
                if success {
                    ClipboardStore.restore(snapshot)
                    PlyphDebug.log("REPLACE END via Tier1/focused", session: debugSession)
                    return true
                }
            }
        } else {
            PlyphDebug.log("Tier1/focused skipped: system focused element=nil", session: debugSession)
        }

        // Compatibility tiers for non-web controls that do not support direct AX.
        if let sourceElement {
            let webKitSuccess = AXElement.performWebKitTextOperationReplace(
                element: sourceElement,
                text: text)
            PlyphDebug.log(
                "Tier1.5/source AXTextOperation success=\(webKitSuccess)",
                session: debugSession)
            if webKitSuccess {
                ClipboardStore.restore(snapshot)
                PlyphDebug.log("REPLACE END via Tier1.5/source", session: debugSession)
                return true
            }
        }

        if let element = AXElement.focusedElement() {
            let webKitSuccess = AXElement.performWebKitTextOperationReplace(
                element: element,
                text: text)
            PlyphDebug.log(
                "Tier1.5/focused AXTextOperation success=\(webKitSuccess)",
                session: debugSession)
            if webKitSuccess {
                ClipboardStore.restore(snapshot)
                PlyphDebug.log("REPLACE END via Tier1.5/focused", session: debugSession)
                return true
            }
        }

        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        PlyphDebug.log(
            "Non-web clipboard write count=\(writtenCount) len=\(ClipboardStore.currentString().count)",
            session: debugSession)
        try? await Task.sleep(nanoseconds: 50_000_000)

        var pastedViaMenu = false
        if let targetApp {
            pastedViaMenu = await AXMenuAction.performPaste(in: targetApp)
        }
        PlyphDebug.log(
            "Non-web AX menu paste reported=\(pastedViaMenu)",
            session: debugSession)

        if !pastedViaMenu {
            let dispatched = KeyPoster.postPaste(
                to: targetApp,
                debugSession: debugSession)
            PlyphDebug.log(
                "Non-web keyboard paste dispatch=\(dispatched)",
                session: debugSession)
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        PlyphDebug.log("REPLACE END non-web fallback", session: debugSession)
        return true
    }

    static func sendUndo(to targetApp: NSRunningApplication?) async {
        guard await KeyPoster.waitModifiersReleased() else { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
        KeyPoster.postUndo(to: targetApp)
    }

    private static func pasteWebContent(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        debugSession: String
    ) async -> Bool {
        // Capture the current clipboard here even when selection capture used AX
        // and therefore did not already create a snapshot.
        let originalClipboard = snapshot ?? ClipboardStore.snapshot()
        let originalWasEmpty = originalClipboard == nil
        let beforeWriteCount = ClipboardStore.changeCount

        PlyphDebug.log(
            "WEB paste path BEGIN clipboardCount=\(beforeWriteCount) clipboardStringLen=\(ClipboardStore.currentString().count) originalWasEmpty=\(originalWasEmpty) frontmost={\(PlyphDebug.frontmostSummary())} focused={\(PlyphDebug.elementSummary(AXElement.focusedElement()))}",
            session: debugSession)

        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        PlyphDebug.log(
            "WEB clipboard WRITE requestedLen=\(text.count) resultingLen=\(ClipboardStore.currentString().count) countBefore=\(beforeWriteCount) countAfter=\(writtenCount)",
            session: debugSession)

        try? await Task.sleep(nanoseconds: 100_000_000)
        PlyphDebug.log(
            "WEB BEFORE System Events paste target={\(PlyphDebug.appSummary(targetApp))} frontmost={\(PlyphDebug.frontmostSummary())} focused={\(PlyphDebug.elementSummary(AXElement.focusedElement()))}",
            session: debugSession)

        let dispatched = KeyPoster.postPasteUsingSystemEvents(debugSession: debugSession)
        PlyphDebug.log(
            "WEB System Events dispatch returned=\(dispatched)",
            session: debugSession)

        try? await Task.sleep(nanoseconds: 700_000_000)
        PlyphDebug.log(
            "WEB AFTER paste frontmost={\(PlyphDebug.frontmostSummary())} focused={\(PlyphDebug.elementSummary(AXElement.focusedElement()))} clipboardCount=\(ClipboardStore.changeCount) clipboardLen=\(ClipboardStore.currentString().count)",
            session: debugSession)

        if ClipboardStore.changeCount == writtenCount {
            if let originalClipboard {
                ClipboardStore.restore(originalClipboard)
                PlyphDebug.log("WEB clipboard restored original snapshot", session: debugSession)
            } else {
                ClipboardStore.clear()
                PlyphDebug.log("WEB clipboard restored original empty state", session: debugSession)
            }
        } else {
            PlyphDebug.log(
                "WEB clipboard not restored because another process changed it writtenCount=\(writtenCount) currentCount=\(ClipboardStore.changeCount)",
                session: debugSession)
        }

        PlyphDebug.log(
            "REPLACE END web path dispatched=\(dispatched)",
            session: debugSession)
        return dispatched
    }

    private static func isBrowserLike(_ app: NSRunningApplication?) -> Bool {
        guard let bundleID = app?.bundleIdentifier?.lowercased() else { return false }
        let markers = [
            "safari", "webkit", "chrome", "chromium", "firefox", "edge",
            "brave", "vivaldi", "opera", "thebrowser"
        ]
        return markers.contains { bundleID.contains($0) }
    }

    private static func isInsideWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<20 {
            guard let node = current else { return false }
            if role(of: node) == "AXWebArea" {
                return true
            }

            var parentRef: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                node,
                kAXParentAttribute as CFString,
                &parentRef)
            guard error == .success, let parentRef else { return false }
            current = unsafeBitCast(parentRef, to: AXUIElement.self)
        }
        return false
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value) == .success else { return nil }
        return value as? String
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
