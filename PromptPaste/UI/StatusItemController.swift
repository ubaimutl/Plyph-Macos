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
        restoreDefault()
    }

    var button: NSStatusBarButton? { item.button }

    func showWorking() {
        cancelReset()
        button?.image = workingIcon
    }

    func showSuccess() {
        cancelReset()
        button?.image = successIcon
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.restoreDefault()
        }
    }

    func restoreDefault() {
        cancelReset()
        button?.image = defaultIcon
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
