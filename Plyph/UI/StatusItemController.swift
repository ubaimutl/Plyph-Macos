import AppKit

/// Manages the menu bar status item icon states: Plyph logo by default,
/// then loading while working and success briefly after completion.
@MainActor
final class StatusItemController {
    let item: NSStatusItem

    private var resetTask: Task<Void, Never>?

    /// The canonical Plyph symbolic mark from the GNOME project. The SVG
    /// has a large intrinsic canvas, so force it to menu-bar dimensions before
    /// assigning it to NSStatusBarButton.
    private let defaultIcon: NSImage? = {
        guard let source = NSImage(named: "MenuBarIcon") else { return nil }
        let image = source.copy() as? NSImage ?? source
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private let workingIcon: NSImage? = {
        guard let image = NSImage(systemSymbolName: "hourglass",
                                  accessibilityDescription: "Working") else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private let successIcon: NSImage? = {
        guard let image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "Done") else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    init(statusItem: NSStatusItem) {
        self.item = statusItem
        self.item.isVisible = true
        if let button = self.item.button {
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "Plyph"
        }
        restoreDefault()
    }

    var button: NSStatusBarButton? { item.button }

    func showWorking() {
        cancelReset()
        setIcon(workingIcon)
    }

    func showSuccess() {
        cancelReset()
        setIcon(successIcon)
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.restoreDefault()
        }
    }

    func restoreDefault() {
        cancelReset()
        setIcon(defaultIcon)
        button?.toolTip = "Plyph"
    }

    /// Opens the status item's menu (used when the action palette is disabled).
    func openMenu() {
        button?.performClick(nil)
    }

    private func setIcon(_ image: NSImage?) {
        if let image {
            button?.image = image
            button?.title = ""
            button?.imagePosition = .imageOnly
        } else {
            useTextFallback()
        }
    }

    /// Never allow the app to become completely invisible if an asset fails to
    /// load on a particular macOS build.
    private func useTextFallback() {
        button?.image = nil
        button?.imagePosition = .noImage
        button?.title = "P"
        button?.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private func cancelReset() {
        resetTask?.cancel()
        resetTask = nil
    }
}
