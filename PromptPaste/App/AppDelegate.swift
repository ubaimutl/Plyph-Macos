import AppKit

/// Application entry point. PromptPaste is a menu bar (accessory) app: it
/// lives in the status area, registers the global hotkeys and wires the
/// palette, preview, HUD and settings together.
@main
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

        // Menu bar item.
        runner = ActionRunner()
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        let controller = StatusItemController(statusItem: statusItem)
        statusItemController = controller

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

        // Re-register hotkeys when the user changes them.
        observeShortcutChanges()

        runner?.undoController.onStateChange = {
            // Menu items refresh each time the menu opens; nothing else to do.
        }

        // Ask for Accessibility permission on first launch; without it the app
        // cannot read selections or replace text.
        AXAccess.promptIfNeeded()
    }

    private var shortcutObserver: NSObjectProtocol?
    private func observeShortcutChanges() {
        guard shortcutObserver == nil else { return }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyManagerRefreshDebounce?.cancel()
            self?.hotkeyManagerRefreshDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self != nil else { return }
                    HotkeyManager.shared.refresh()
                }
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
        // The app keeps running as a menu bar utility.
        false
    }
}
