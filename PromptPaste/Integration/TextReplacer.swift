import AppKit
import ApplicationServices
import Foundation

/// Replaces the original selection in the target app.
///
/// Native AppKit controls are replaced through Accessibility. Safari is routed
/// directly through clipboard + System Events because WebKit can report a
/// successful AXSelectedText write without actually changing webpage content.
/// The detailed debug trace is written to ~/Library/Logs/PromptPaste/debug.log.
enum TextReplacer {
    @discardableResult
    static func replace(
        _ text: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        sourceElement: AXUIElement?
    ) async throws -> Bool {
        let debugSession = PromptPasteDebug.newSession()
        let safariLike = isSafariLike(targetApp)

        PromptPasteDebug.log(
            "REPLACE BEGIN outputLen=\(text.count) safariLike=\(safariLike) axTrusted=\(AXAccess.isTrusted) target={\(PromptPasteDebug.appSummary(targetApp))} frontmost={\(PromptPasteDebug.frontmostSummary())} source={\(PromptPasteDebug.elementSummary(sourceElement))} snapshot=\(snapshot != nil)",
            session: debugSession)

        if let targetApp {
            PromptPasteDebug.log(
                "Activating target app; before frontmost={\(PromptPasteDebug.frontmostSummary())}",
                session: debugSession)
            targetApp.activate(options: [.activateIgnoringOtherApps])
            await waitForApp(targetApp, timeout: 1.5)
            PromptPasteDebug.log(
                "Activation wait finished; frontmost={\(PromptPasteDebug.frontmostSummary())}",
                session: debugSession)

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

        let modifiersReleased = await KeyPoster.waitModifiersReleased()
        PromptPasteDebug.log(
            "Modifiers released=\(modifiersReleased) frontmost={\(PromptPasteDebug.frontmostSummary())} currentFocused={\(PromptPasteDebug.elementSummary(AXElement.focusedElement()))}",
            session: debugSession)
        guard modifiersReleased else {
            PromptPasteDebug.log("REPLACE ABORT releaseShortcutKeys", session: debugSession)
            throw PromptError.releaseShortcutKeys
        }

        // Safari must bypass direct AX writes entirely. The debug build proved
        // that WebKit's AXTextArea reports selectedTextSettable=true and
        // AXUIElementSetAttributeValue returns success while the DOM remains
        // unchanged. Using that return code caused PromptPaste to exit before
        // reaching the paste path that is known to work on the same page.
        if safariLike {
            let beforeWriteCount = ClipboardStore.changeCount
            let beforeWriteLength = ClipboardStore.currentString().count
            PromptPasteDebug.log(
                "Safari DIRECT paste path BEGIN clipboardCount=\(beforeWriteCount) clipboardStringLen=\(beforeWriteLength) frontmost={\(PromptPasteDebug.frontmostSummary())} focused={\(PromptPasteDebug.elementSummary(AXElement.focusedElement()))}",
                session: debugSession)

            ClipboardStore.write(text)
            let writtenCount = ClipboardStore.changeCount
            let writtenLength = ClipboardStore.currentString().count
            PromptPasteDebug.log(
                "Safari clipboard WRITE requestedLen=\(text.count) resultingLen=\(writtenLength) countBefore=\(beforeWriteCount) countAfter=\(writtenCount)",
                session: debugSession)

            try? await Task.sleep(nanoseconds: 100_000_000)
            PromptPasteDebug.log(
                "Safari BEFORE System Events paste frontmost={\(PromptPasteDebug.frontmostSummary())} focused={\(PromptPasteDebug.elementSummary(AXElement.focusedElement()))} clipboardCount=\(ClipboardStore.changeCount) clipboardLen=\(ClipboardStore.currentString().count)",
                session: debugSession)

            let dispatched = KeyPoster.postPaste(
                to: targetApp,
                debugSession: debugSession)
            PromptPasteDebug.log(
                "Safari System Events dispatch returned=\(dispatched)",
                session: debugSession)

            try? await Task.sleep(nanoseconds: 700_000_000)
            PromptPasteDebug.log(
                "Safari AFTER paste frontmost={\(PromptPasteDebug.frontmostSummary())} focused={\(PromptPasteDebug.elementSummary(AXElement.focusedElement()))} clipboardCount=\(ClipboardStore.changeCount) clipboardLen=\(ClipboardStore.currentString().count)",
                session: debugSession)

            if snapshot != nil && ClipboardStore.changeCount == writtenCount {
                ClipboardStore.restore(snapshot)
                PromptPasteDebug.log(
                    "Safari clipboard restored original snapshot",
                    session: debugSession)
            } else {
                PromptPasteDebug.log(
                    "Safari clipboard NOT restored snapshotExists=\(snapshot != nil) writtenCount=\(writtenCount) currentCount=\(ClipboardStore.changeCount)",
                    session: debugSession)
            }

            PromptPasteDebug.log(
                "REPLACE END Safari direct paste dispatched=\(dispatched)",
                session: debugSession)
            return true
        }

        // Tier 1: direct AX replacement for native AppKit controls.
        if let sourceElement {
            let settable = AXElement.selectedTextSettable(sourceElement)
            PromptPasteDebug.log(
                "Tier1/source settable=\(settable) element={\(PromptPasteDebug.elementSummary(sourceElement))}",
                session: debugSession)
            if settable {
                let success = AXElement.setSelectedText(sourceElement, to: text)
                PromptPasteDebug.log(
                    "Tier1/source setSelectedText success=\(success)",
                    session: debugSession)
                if success {
                    ClipboardStore.restore(snapshot)
                    PromptPasteDebug.log("REPLACE END via Tier1/source", session: debugSession)
                    return true
                }
            }
        } else {
            PromptPasteDebug.log("Tier1/source skipped: sourceElement=nil", session: debugSession)
        }

        let currentFocused = AXElement.focusedElement()
        if let currentFocused {
            let settable = AXElement.selectedTextSettable(currentFocused)
            PromptPasteDebug.log(
                "Tier1/focused settable=\(settable) element={\(PromptPasteDebug.elementSummary(currentFocused))}",
                session: debugSession)
            if settable {
                let success = AXElement.setSelectedText(currentFocused, to: text)
                PromptPasteDebug.log(
                    "Tier1/focused setSelectedText success=\(success)",
                    session: debugSession)
                if success {
                    ClipboardStore.restore(snapshot)
                    PromptPasteDebug.log("REPLACE END via Tier1/focused", session: debugSession)
                    return true
                }
            }
        } else {
            PromptPasteDebug.log("Tier1/focused skipped: system focused element=nil", session: debugSession)
        }

        // Non-Safari compatibility tiers.
        if let sourceElement {
            let webKitSuccess = AXElement.performWebKitTextOperationReplace(
                element: sourceElement,
                text: text)
            PromptPasteDebug.log(
                "Tier1.5/source AXTextOperation success=\(webKitSuccess)",
                session: debugSession)
            if webKitSuccess {
                ClipboardStore.restore(snapshot)
                PromptPasteDebug.log("REPLACE END via Tier1.5/source", session: debugSession)
                return true
            }
        }

        if let element = AXElement.focusedElement() {
            let webKitSuccess = AXElement.performWebKitTextOperationReplace(
                element: element,
                text: text)
            PromptPasteDebug.log(
                "Tier1.5/focused AXTextOperation success=\(webKitSuccess)",
                session: debugSession)
            if webKitSuccess {
                ClipboardStore.restore(snapshot)
                PromptPasteDebug.log("REPLACE END via Tier1.5/focused", session: debugSession)
                return true
            }
        }

        ClipboardStore.write(text)
        let writtenCount = ClipboardStore.changeCount
        PromptPasteDebug.log(
            "Non-Safari clipboard write count=\(writtenCount) len=\(ClipboardStore.currentString().count)",
            session: debugSession)
        try? await Task.sleep(nanoseconds: 50_000_000)

        var pastedViaMenu = false
        if let targetApp {
            pastedViaMenu = await AXMenuAction.performPaste(in: targetApp)
        }
        PromptPasteDebug.log(
            "Non-Safari AX menu paste reported=\(pastedViaMenu)",
            session: debugSession)

        if !pastedViaMenu {
            let dispatched = KeyPoster.postPaste(
                to: targetApp,
                debugSession: debugSession)
            PromptPasteDebug.log(
                "Non-Safari keyboard paste dispatch=\(dispatched)",
                session: debugSession)
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        if snapshot != nil && ClipboardStore.changeCount == writtenCount {
            ClipboardStore.restore(snapshot)
        }
        PromptPasteDebug.log("REPLACE END non-Safari fallback", session: debugSession)
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
