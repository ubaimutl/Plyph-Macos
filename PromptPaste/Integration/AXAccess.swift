import AppKit
import ApplicationServices

/// Accessibility (AX) permission handling. PromptPaste needs Accessibility to
/// read the focused element's selected text and to post keyboard events.
enum AXAccess {
    /// Whether the app is currently trusted for Accessibility.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Checks trust and, when missing, asks macOS to show the permission dialog.
    /// Returns the current trust state.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Privacy & Security > Accessibility pane in System Settings.
    static func openSystemSettings() {
        guard let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Small helpers around the AX API used for selection capture and replacement.
enum AXElement {
    /// The system-wide focused UI element, if any.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let raw = value else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// Waits for the target app's keyboard focus to stabilise after activation.
    ///
    /// Browsers (Safari, Chrome) and Electron apps restore keyboard focus to
    /// their renderer/content subprocess asynchronously after the main process
    /// is activated. Simply waiting until `kAXFocusedUIElementAttribute` is
    /// non-nil is insufficient because the browser's native chrome (URL bar,
    /// toolbar) is *always* focused — the renderer only takes over later.
    ///
    /// Strategy: enforce a minimum wait of 100 ms (the absolute floor for the
    /// renderer hand-off), then keep polling until the focused element stops
    /// changing between two consecutive 50 ms checks, indicating focus has
    /// settled on the final target. Hard timeout prevents hangs.
    ///
    /// - Parameters:
    ///   - app: The target `NSRunningApplication`.
    ///   - timeout: Maximum seconds to wait (default 1.5 s).
    static func waitFocusRestored(
        in app: NSRunningApplication,
        timeout: TimeInterval = 1.5
    ) async {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)

        // Minimum wait — the renderer hand-off never completes in under ~80 ms.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Now poll for stability: two consecutive reads returning the same
        // element means focus has settled.
        var previousDescription: String?
        while Date() < deadline {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                appElement, kAXFocusedUIElementAttribute as CFString, &value)
            let desc: String?
            if err == .success, let el = value {
                // Compare by AX description since AXUIElement is not Equatable.
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(
                    unsafeBitCast(el, to: AXUIElement.self),
                    kAXRoleAttribute as CFString, &role)
                desc = role as? String
            } else {
                desc = nil
            }

            if desc != nil && desc == previousDescription {
                // Focus has stabilised — safe to post key events.
                return
            }
            previousDescription = desc
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
    }

    static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &value)
        guard error == .success, let text = value as? String else { return nil }
        return text
    }

    /// Whether the focused element's selection can be replaced through AX.
    static func selectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    /// Replaces the current selection through AX. Returns whether it succeeded.
    @discardableResult
    static func setSelectedText(_ element: AXUIElement, to text: String) -> Bool {
        let error = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return error == .success
    }

    /// Invokes WebKit's internal AXTextOperation API to replace text inside WKWebView/Safari.
    /// This bypasses standard keyboard and clipboard limitations entirely by manipulating
    /// the WebKit DOM selection directly through its accessibility bridge.
    @discardableResult
    static func performWebKitTextOperationReplace(element: AXUIElement, text: String) -> Bool {
        var rangeRef: CFTypeRef?
        // WebKit uses AXSelectedTextMarkerRange for rich text selections
        let rangeErr = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &rangeRef)
        
        guard rangeErr == .success, let range = rangeRef else { return false }
        
        // Try multiple known WebKit/Chromium AXTextOperationType values
        let operationTypes = [
            "TextOperationReplacePreserveCase",
            "AXTextOperationReplacePreserveCase",
            "TextOperationReplace",
            "AXTextOperationReplace"
        ]
        
        for type in operationTypes {
            let params: [String: Any] = [
                "AXTextOperationType": type,
                "AXTextOperationMarkerRanges": [range],
                "AXTextOperationReplacementString": text
            ]
            var resultRef: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextOperation" as CFString, params as CFDictionary, &resultRef)
            
            if err == .success {
                return true
            }
        }
        return false
    }
}

/// Triggers standard menu actions (e.g. Edit › Paste) directly on the target
/// application's menu bar via the Accessibility API.
///
/// In WebKit (Safari) and Chromium (Chrome, Electron, VS Code), web content
/// editors do not expose settable AXSelectedText attributes. Triggering the
/// application's native Edit › Paste action causes the host application to
/// dispatch the standard Cocoa `paste:` selector through its native responder
/// chain directly into the active WebContent / WKWebView DOM selection.
enum AXMenuAction {
    @MainActor
    @discardableResult
    static func performPaste(in app: NSRunningApplication) async -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        // Wait up to 1.5 seconds for the Paste menu to become available and enabled
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            var menuBarRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
               let menuBarRef {
                let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let menus = childrenRef as? [AXUIElement] {
                    
                    for menu in menus {
                        if searchAndPressPaste(in: menu) {
                            return true
                        }
                    }
                }
            }
            // If not found or not enabled yet, sleep and poll again. (VMs are slow to restore DOM caret)
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return false
    }

    private static func searchAndPressPaste(in element: AXUIElement) -> Bool {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let lower = title.lowercased()
            // Match standard localized "Paste" commands
            if lower.hasPrefix("paste") || lower.hasPrefix("einsetzen") || lower.hasPrefix("coller") ||
               lower.hasPrefix("pegar") || lower.hasPrefix("incolla") || lower.hasPrefix("貼") || lower.hasPrefix("粘") {
                
                var enabledRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
                   let enabled = enabledRef as? Bool, enabled == true {
                    let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    if err == .success {
                        return true
                    }
                }
                // If it's the paste button but it's disabled, return false immediately so we can poll again
                return false
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if searchAndPressPaste(in: child) {
                    return true
                }
            }
        }
        return false
    }

    static func isCopyEnabled(in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef else { return false }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let menus = childrenRef as? [AXUIElement] else { return false }

        for menu in menus {
            if searchAndCheckCopyEnabled(in: menu) {
                return true
            }
        }
        return false
    }

    private static func searchAndCheckCopyEnabled(in element: AXUIElement) -> Bool {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let lower = title.lowercased()
            // Match standard localized "Copy" commands
            if lower.hasPrefix("copy") || lower.hasPrefix("kopieren") || lower.hasPrefix("copier") ||
               lower.hasPrefix("copiar") || lower.hasPrefix("copia") || lower.hasPrefix("拷") || lower.hasPrefix("复") {
                
                var enabledRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
                   let enabled = enabledRef as? Bool {
                    return enabled
                }
                return false
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if searchAndCheckCopyEnabled(in: child) {
                    return true
                }
            }
        }
        return false
    }
}
