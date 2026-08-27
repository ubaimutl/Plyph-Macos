import AppKit
import Foundation

/// Orchestrates a full action run: capture the selection, call the AI, then
/// either preview the result or replace it directly — mirroring the GNOME
/// extension's `_run()`/`_replace()` flow, including the busy lock, status
/// feedback and undo bookkeeping.
@MainActor
final class ActionRunner: ObservableObject {
    /// True while an action is running; new triggers are ignored (GNOME parity).
    @Published private(set) var isBusy = false

    private let settings: SettingsStore
    private let hud: FeedbackHUD
    private let statusIcons: StatusItemController?
    let undoController: UndoController

    /// Currently open preview window, if any.
    private var previewController: PreviewController?

    init(
        settings: SettingsStore = .shared,
        hud: FeedbackHUD = .shared,
        statusIcons: StatusItemController? = nil
    ) {
        self.settings = settings
        self.hud = hud
        self.statusIcons = statusIcons
        self.undoController = UndoController()
    }

    // MARK: Entry points

    func run(mode: RunMode) async {
        guard !isBusy else { return }
        isBusy = true
        statusIcons?.showWorking()
        feedback("Working…", error: false, duration: 0)

        let frontApp = NSWorkspace.shared.frontmostApplication
        do {
            let selection = try await SelectionReader.read(settings: settings, frontApp: frontApp)
            let text = selection.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptError.noSelection
            }

            let options: RunOptions
            let customPrompt: String?
            let actionName: String?
            switch mode {
            case .correct:
                options = RunOptions()
                customPrompt = nil
                actionName = nil
            case .rewrite:
                options = RunOptions()
                customPrompt = nil
                actionName = nil
            case .prompt:
                options = RunOptions(
                    provider: settings.promptRunProvider,
                    model: settings.promptRunModel,
                    inputLimit: settings.promptRunInputLimit,
                    outputLimit: settings.promptRunOutputLimit)
                customPrompt = nil
                actionName = nil
            case .custom(let action):
                options = RunOptions(
                    provider: action.provider,
                    model: action.model,
                    inputMode: action.inputMode,
                    inputLimit: action.inputLimit,
                    outputLimit: action.outputLimit)
                customPrompt = action.prompt
                actionName = action.name
            }

            let config = AiConfig.from(settings)
            let output = try await AiClient.shared.transform(
                text: text, mode: mode, customPrompt: customPrompt, options: options,
                config: config)

            if settings.previewResults {
                showPreview(
                    output: output, targetApp: frontApp, snapshot: selection.clipboardSnapshot,
                    mode: mode, actionName: actionName)
            } else {
                let message = replaceMessage(mode: mode, actionName: actionName)
                try await replace(
                    output, snapshot: selection.clipboardSnapshot, targetApp: frontApp,
                    message: message)
            }
        } catch {
            handleError(error, mode: mode)
        }
        isBusy = false
    }

    func openActionPalette() {
        guard !isBusy else { return }
        switch settings.actionPalettePosition {
        case "monitor-center", "near-pointer":
            ActionPaletteController.shared.show(modeHandler: { [weak self] mode in
                Task { await self?.run(mode: mode) }
            })
        default:
            // GNOME opens the panel menu when the palette is disabled.
            AppDelegate.shared?.statusItemController?.openMenu()
        }
    }

    // MARK: Preview

    private func showPreview(
        output: String, targetApp: NSRunningApplication?, snapshot: ClipboardSnapshot?,
        mode: RunMode, actionName: String?
    ) {
        previewController?.close()
        statusIcons?.restoreDefault()
        feedback("Ready to review", error: false, duration: 1.5)
        let controller = PreviewController(
            result: output,
            onReplace: { [weak self] text in
                guard let self else { return }
                self.previewController = nil
                Task {
                    let message = self.replaceMessage(mode: mode, actionName: actionName)
                    try? await self.replace(
                        text, snapshot: snapshot, targetApp: targetApp, message: message,
                        previewReplaced: true)
                    self.isBusy = false
                }
            },
            onCopy: { [weak self] text in
                guard let self else { return }
                ClipboardStore.write(text)
                self.previewController = nil
                self.statusIcons?.showSuccess()
                self.feedback("Copied", error: false, duration: 1.5)
                self.isBusy = false
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.previewController = nil
                self.feedback("Cancelled", error: false, duration: 1.5)
                self.isBusy = false
            })
        previewController = controller
        controller.show()
    }

    // MARK: Replacement

    private func replace(
        _ output: String, snapshot: ClipboardSnapshot?, targetApp: NSRunningApplication?,
        message: String, previewReplaced: Bool = false
    ) async throws {
        let usedAX = try await TextReplacer.replace(
            output, snapshot: snapshot, targetApp: targetApp)
        undoController.remember(app: NSWorkspace.shared.frontmostApplication ?? targetApp)
        statusIcons?.showSuccess()
        feedback(message, error: false, duration: 1.5)
        _ = usedAX
    }

    private func replaceMessage(mode: RunMode, actionName: String?) -> String {
        if let actionName {
            return actionName
        }
        switch mode {
        case .rewrite:
            return "Rewritten"
        case .prompt:
            return "Generated"
        default:
            return "Corrected"
        }
    }

    // MARK: Errors

    private func handleError(_ error: Error, mode: RunMode) {
        statusIcons?.restoreDefault()
        let message: String
        switch error {
        case PromptError.noSelection:
            message = PromptError.noSelection.localizedDescription
        default:
            message = error.localizedDescription
        }
        feedback(message, error: true, duration: 3.5)
        isBusy = false
    }

    private func feedback(_ message: String, error: Bool, duration: TimeInterval) {
        hud.show(message, isError: error, duration: duration)
    }
}
