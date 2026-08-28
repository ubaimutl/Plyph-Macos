import AppKit

/// Manages the menu bar status item icon states: PromptPaste logo by default,
/// then loading while working and success briefly after completion.
@MainActor
final class StatusItemController {
    let item: NSStatusItem

    private var resetTask: Task<Void, Never>?

    /// The canonical PromptPaste symbolic mark from the GNOME project. Marking
    /// it as a template lets macOS tint it correctly for light/dark menu bars.
    private let defaultIcon: NSImage? = {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

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
            workingIcon.isTemplate = true
            button?.image = workingIcon
            button?.title = ""
        } else {
            useTextFallback()
        }
    }

    func showSuccess() {
        cancelReset()
        if let successIcon {
            successIcon.isTemplate = true
            button?.image = successIcon
            button?.title = ""
        } else {
            useTextFallback()
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
            useTextFallback()
        }
        button?.toolTip = "PromptPaste"
    }

    /// Opens the status item's menu (used when the action palette is disabled).
    func openMenu() {
        button?.performClick(nil)
    }

    private func useTextFallback() {
        button?.image = nil
        button?.title = "PP"
    }

    private func cancelReset() {
        resetTask?.cancel()
        resetTask = nil
    }
}
