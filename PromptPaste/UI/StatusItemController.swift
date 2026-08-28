import AppKit

/// Manages the menu bar status item icon states, mirroring the GNOME panel
/// icon behavior: default logo → loading while working → success briefly.
@MainActor
final class StatusItemController {
    let item: NSStatusItem

    private var resetTask: Task<Void, Never>?
    private let defaultIcon = NSImage(systemSymbolName: "sparkles",
                                      accessibilityDescription: "PromptPaste")
    private let workingIcon = NSImage(systemSymbolName: "hourglass",
                                      accessibilityDescription: "Working")
    private let successIcon = NSImage(systemSymbolName: "checkmark.circle.fill",
                                      accessibilityDescription: "Done")

    init(statusItem: NSStatusItem) {
        self.item = statusItem
        self.item.isVisible = true
        restoreDefault()
    }

    var button: NSStatusBarButton? { item.button }

    func showWorking() {
        cancelReset()
        if let workingIcon {
            button?.image = workingIcon
            button?.title = ""
        } else {
            button?.image = nil
            button?.title = "PP"
        }
    }

    func showSuccess() {
        cancelReset()
        if let successIcon {
            button?.image = successIcon
            button?.title = ""
        } else {
            button?.image = nil
            button?.title = "PP"
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.restoreDefault()
        }
    }

    func restoreDefault() {
        cancelReset()
        if let defaultIcon {
            button?.image = defaultIcon
            button?.title = ""
        } else {
            // Text fallback makes the menu-bar item visible even if an SF Symbol
            // unexpectedly fails to resolve on a particular macOS environment.
            button?.image = nil
            button?.title = "PP"
        }
        button?.toolTip = "PromptPaste"
    }

    /// Opens the status item's menu (used when the action palette is disabled,
    /// matching the GNOME "open the panel menu" behavior).
    func openMenu() {
        button?.performClick(nil)
    }

    private func cancelReset() {
        resetTask?.cancel()
        resetTask = nil
    }
}
