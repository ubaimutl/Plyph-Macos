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
        return (raw as AnyObject) as? AXUIElement
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
}
