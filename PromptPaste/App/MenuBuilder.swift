import AppKit

/// Builds the status item menu: the three built-in actions, the enabled custom
/// actions, the time-windowed Undo item, settings and quit. Rebuilt every time
/// the menu opens so new/changed custom actions appear immediately.
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    private weak var appDelegate: AppDelegate?
    private var selectionTargetApp: NSRunningApplication?
    let menu = NSMenu()

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        rememberSelectionTarget()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Capture the app that owned the user's selection before a menu action
        // is dispatched. This prevents PromptPaste itself from becoming the
        // capture target after interacting with the status menu.
        rememberSelectionTarget()
        rebuild(menu)
    }

    private func rememberSelectionTarget() {
        guard let candidate = NSWorkspace.shared.frontmostApplication else { return }
        guard candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        selectionTargetApp = candidate
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let appDelegate else { return }
        guard let runner = appDelegate.runner else { return }
        let settings = SettingsStore.shared

        // Accessibility guidance when the app cannot work yet.
        if !AXAccess.isTrusted {
            let item = NSMenuItem(
                title: "Enable Accessibility Permission…",
                action: #selector(openAccessibility(_:)),
                keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem("Correct selected text", .correct, runner))
        menu.addItem(actionItem("Rewrite selected text", .rewrite, runner))
        menu.addItem(actionItem("Run selected prompt", .prompt, runner))

        let enabled = settings.enabledCustomActions
        if !enabled.isEmpty {
            menu.addItem(.separator())
            for action in enabled {
                menu.addItem(actionItem(action.name, .custom(action), runner))
            }
        }

        menu.addItem(.separator())
        let undo = NSMenuItem(
            title: "Undo last replacement",
            action: #selector(undoClicked(_:)),
            keyEquivalent: "")
        undo.target = self
        undo.isEnabled = runner.undoController.pending != nil
        menu.addItem(undo)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit PromptPaste",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private func actionItem(_ title: String, _ mode: RunMode, _ runner: ActionRunner)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: #selector(actionClicked(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.representedObject = ModeBox(mode: mode, runner: runner)
        return item
    }

    @objc private func actionClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ModeBox else { return }
        let targetApp = selectionTargetApp
        Task { await box.runner.run(mode: box.mode, targetApp: targetApp) }
    }

    @objc private func undoClicked(_ sender: NSMenuItem) {
        guard let appDelegate else { return }
        guard let runner = appDelegate.runner else { return }
        Task {
            if let message = await runner.undoController.perform(
                frontmost: NSWorkspace.shared.frontmostApplication)
            {
                await MainActor.run {
                    FeedbackHUD.shared.show(message, isError: true, duration: 3.5)
                }
            } else {
                await MainActor.run {
                    FeedbackHUD.shared.show(
                        "Replacement undone", isError: false, duration: 1.5)
                }
            }
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        SettingsWindowController.shared.show()
    }

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        AXAccess.openSystemSettings()
    }
}

/// Helper storing a run mode with its runner for menu item callbacks.
final class ModeBox {
    let mode: RunMode
    let runner: ActionRunner

    init(mode: RunMode, runner: ActionRunner) {
        self.mode = mode
        self.runner = runner
    }
}
