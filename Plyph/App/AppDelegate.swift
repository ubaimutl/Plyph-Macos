import AppKit

/// Application delegate. Plyph normally lives only in the menu bar and
/// uses the explicit AppKit entry point from main.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private(set) var statusItemController: StatusItemController?
    private(set) var runner: ActionRunner?
    private var menuBuilder: MenuBuilder?

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        guard !Self.isRunningTests else { return }

        // No Dock icon during normal menu-bar operation. Regular windows such
        // as Settings temporarily switch the app to .regular while visible.
        NSApp.setActivationPolicy(.accessory)

        // Reuse the canonical Plyph artwork instead of the generated
        // placeholder icon from the original macOS port. This is the image the
        // Dock shows whenever a regular Plyph window is open.
        if let appIcon = NSImage(named: "AppBrandIcon") {
            NSApp.applicationIconImage = appIcon
        }

        // A menu-bar icon should occupy one normal square slot. Using
        // variableLength with a large vector asset can make AppKit reserve the
        // vector's intrinsic width and push the item out of the visible bar.
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = AXAccess.promptIfNeeded()
            // Start the optional selection dot if the setting is already on.
            self.applySelectionDotSetting()
        }
    }

    @MainActor func applySelectionDotSetting() {
        if SettingsStore.shared.selectionDotEnabled {
            SelectionDotController.shared.start { [weak self] in
                self?.runner?.openActionPalette(forcePopup: true)
            }
        } else {
            SelectionDotController.shared.stop()
        }
    }

    private var shortcutObserver: NSObjectProtocol?
    private var selectionDotObserver: NSObjectProtocol?

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
                self.applySelectionDotSetting()
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
