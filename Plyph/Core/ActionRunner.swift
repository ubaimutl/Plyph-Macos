import AppKit
import ApplicationServices
import Foundation

/// Orchestrates a full action run: capture the selection, call the AI, then
/// either preview the result or replace it directly.
@MainActor
final class ActionRunner: ObservableObject {
    @Published private(set) var isBusy = false

    private let settings: SettingsStore
    private let hud: FeedbackHUD
    private let statusIcons: StatusItemController?
    let undoController: UndoController

    private var previewController: PreviewController?

    init(
        settings: SettingsStore? = nil,
        hud: FeedbackHUD? = nil,
        statusIcons: StatusItemController? = nil
    ) {
        self.settings = settings ?? SettingsStore.shared
        self.hud = hud ?? FeedbackHUD.shared
        self.statusIcons = statusIcons
        self.undoController = UndoController()
    }

    // MARK: Entry points

    func run(mode: RunMode, targetApp: NSRunningApplication? = nil) async {
        guard !isBusy else { return }

        // Capture the target before Plyph changes any UI state. Menu
        // actions can pass the app remembered when the status menu opened;
        // hotkeys use the current frontmost app.
        let frontApp = targetApp ?? NSWorkspace.shared.frontmostApplication

        isBusy = true
        statusIcons?.showWorking()
        feedback("Working…", error: false, duration: 0)

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
                    output: output,
                    targetApp: frontApp,
                    snapshot: selection.clipboardSnapshot,
                    sourceElement: selection.focusedElement,
                    mode: mode,
                    actionName: actionName)
            } else {
                let message = replaceMessage(mode: mode, actionName: actionName)
                try await replace(
                    output,
                    snapshot: selection.clipboardSnapshot,
                    targetApp: frontApp,
                    sourceElement: selection.focusedElement,
                    message: message)
            }
        } catch {
            handleError(error, mode: mode)
        }
        isBusy = false
    }

    func openActionPalette(forcePopup: Bool = false) {
        guard !isBusy else { return }
        let targetApp = NSWorkspace.shared.frontmostApplication
        if forcePopup || settings.actionPalettePosition != "disabled" {
            ActionPaletteController.shared.show(modeHandler: { [weak self] mode in
                Task { await self?.run(mode: mode, targetApp: targetApp) }
            })
        } else {
            AppDelegate.shared?.statusItemController?.openMenu()
        }
    }

    // MARK: Preview

    private func showPreview(
        output: String,
        targetApp: NSRunningApplication?,
        snapshot: ClipboardSnapshot?,
        sourceElement: AXUIElement?,
        mode: RunMode,
        actionName: String?
    ) {
        previewController?.close()
        statusIcons?.restoreDefault()
        feedback("Ready to review", error: false, duration: 1.5)

        let controller = PreviewController(
            result: output,
            onReplace: { [weak self] text in
                guard let self else { return }
                self.previewController = nil
                Task { @MainActor in
                    do {
                        let message = self.replaceMessage(mode: mode, actionName: actionName)
                        try await self.replace(
                            text,
                            snapshot: snapshot,
                            targetApp: targetApp,
                            sourceElement: sourceElement,
                            message: message)
                    } catch {
                        self.handleError(error, mode: mode)
                    }
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
        _ output: String,
        snapshot: ClipboardSnapshot?,
        targetApp: NSRunningApplication?,
        sourceElement: AXUIElement?,
        message: String
    ) async throws {
        _ = try await TextReplacer.replace(
            output,
            snapshot: snapshot,
            targetApp: targetApp,
            sourceElement: sourceElement)
        undoController.remember(app: NSWorkspace.shared.frontmostApplication ?? targetApp)
        statusIcons?.showSuccess()
        feedback(message, error: false, duration: 1.5)
    }

    private func replaceMessage(mode: RunMode, actionName: String?) -> String {
        if let actionName { return actionName }
        switch mode {
        case .rewrite: return "Rewritten"
        case .prompt: return "Generated"
        default: return "Corrected"
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
