import AppKit

/// Application delegate. PromptPaste lives in the menu bar and uses an
/// explicit AppKit entry point from main.swift.
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

        // PromptPaste is a menu-bar utility: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        let controller = StatusItemController(statusItem: statusItem)
        statusItemController = controller

        runner = ActionRunner(statusIcons: controller)

        let builder = MenuBuilder(appDelegate: self)
        menuBuilder = builder
        statusItem.menu = builder.menu

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

        // Keep Settings visible during the current test phase; the app itself
        // remains a menu-bar utility and does not appear in the Dock.
        DispatchQueue.main.async {
            SettingsWindowController.shared.show()
        }

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
