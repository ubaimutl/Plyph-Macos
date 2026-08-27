import AppKit
import Foundation

/// Tracks whether PromptPaste actually performed an automatic replacement and
/// offers Undo only for a short time window afterwards (60 seconds, like the
/// GNOME extension). Undo sends the target app's native Cmd+Z to the *same*
/// window/app that received the replacement; it is never left enabled forever.
@MainActor
final class UndoController: ObservableObject {
    struct Replacement {
        let appName: String
        let bundleIdentifier: String?
        let processIdentifier: pid_t
    }

    /// Published so the menu bar item can enable/disable the Undo row.
    @Published private(set) var pending: Replacement?

    private var clearTask: Task<Void, Never>?
    var onStateChange: (() -> Void)?

    /// Records that PromptPaste replaced text in the given app.
    func remember(app: NSRunningApplication?) {
        clearTask?.cancel()
        pending = Replacement(
            appName: app?.localizedName ?? "the original app",
            bundleIdentifier: app?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? 0)
        onStateChange?()
        clearTask = Task { [weak self] in
            // 60-second window, matching the GNOME behavior.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.clear()
        }
    }

    /// Performs the undo: verifies the same app is still frontmost, then sends
    /// Cmd+Z. Returns an error message when the undo could not run.
    func perform(frontmost: NSRunningApplication?) async -> String? {
        guard let pending else { return nil }
        if let bundleIdentifier = pending.bundleIdentifier,
            frontmost?.bundleIdentifier != bundleIdentifier
        {
            return PromptError.returnToOriginalApp.localizedDescription
        }
        clear()
        await TextReplacer.sendUndo()
        return nil
    }

    func clear() {
        guard pending != nil else { return }
        clearTask?.cancel()
        clearTask = nil
        pending = nil
        onStateChange?()
    }
}
