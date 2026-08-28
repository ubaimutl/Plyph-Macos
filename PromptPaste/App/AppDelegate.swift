import AppKit

/// Application delegate. PromptPaste normally lives in the menu bar.
/// During VM testing we also launch as a regular app and always show Settings
/// so startup is impossible to miss.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var statusItemController: StatusItemController?
    private(set) var runner: ActionRunner?
    private var menuBuilder: MenuBuilder?

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        print("[PromptPaste] applicationWillFinishLaunching")
        NSLog("[PromptPaste] applicationWillFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[PromptPaste] applicationDidFinishLaunching")
        NSLog("[PromptPaste] applicationDidFinishLaunching")

        Self.shared = self
        guard !Self.isRunningTests else {
            print("[PromptPaste] running tests; skipping UI startup")
            return
        }

        // TEST MODE: make PromptPaste a normal foreground app so it appears
        // in the Dock and can never look like a silent background process.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Menu-bar item.
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        let controller = StatusItemController(statusItem: statusItem)
        statusItemController = controller

        // Wire status feedback correctly.
        runner = ActionRunner(statusIcons: controller)

        let builder = MenuBuilder(appDelegate: self)
        menuBuilder = builder
        statusItem.menu = builder.menu

        // Global hotkeys (configurable in Settings; none by default).
        HotkeyManager.shared.refresh()
        HotkeyManager.shared.onHotKey = { [weak self] identifier in
            guard let self else { return }
            switch identifier {
            case .correct:
                Task { await self.runner?.run(mode: .correct) }
            case .rewrite:
                Task { await self.runner?.run(mode: .rewrite) }
            case .actions:
                self.runner?.openActionPalette()
            }
        }

        observeShortcutChanges()

        runner?.undoController.onStateChange = {
            // Menu items refresh each time the menu opens.
        }

        // Always show Settings in this test build. No first-launch flag.
        DispatchQueue.main.async {
            print("[PromptPaste] showing Settings window")
            NSLog("[PromptPaste] showing Settings window")
            SettingsWindowController.shared.show()
        }

        // Ask for Accessibility after the visible window has been scheduled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = AXAccess.promptIfNeeded()
        }
    }

    private var shortcutObserver: NSObjectProtocol?
    private func observeShortcutChanges() {
        guard shortcutObserver == nil else { return }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyManagerRefreshDebounce?.cancel()
            self.hotkeyManagerRefreshDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                HotkeyManager.shared.refresh()
                self.hotkeyManagerRefreshDebounce = nil
            }
        }
    }

    private var hotkeyManagerRefreshDebounce: Task<Void, Never>?

    func applicationWillTerminate(_ notification: Notification) {
        runner?.undoController.clear()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
