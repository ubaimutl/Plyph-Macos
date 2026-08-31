import AppKit
import ApplicationServices
import Foundation

/// Orchestrates a full action run: capture the selection, call the AI, then
/// route the result through preview, replacement, insertion, copy, or Ask.
@MainActor
final class ActionRunner: ObservableObject {
    @Published private(set) var isBusy = false

    private let settings: SettingsStore
    private let hud: FeedbackHUD
    private let statusIcons: StatusItemController?
    let undoController: UndoController

    private var previewController: PreviewController?
    private var askInputController: AskInputController?
    private var workingFeedbackActive = false

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
        var keepsInteractionOpen = false
        defer {
            clearWorkingFeedback()
            if !keepsInteractionOpen { isBusy = false }
        }
        statusIcons?.showWorking()
        beginWorkingFeedback()

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

            if case .custom(let action) = mode {
                keepsInteractionOpen = try await routeCustomOutput(
                    output,
                    action: action,
                    selection: selection,
                    targetApp: frontApp)
            } else if settings.previewResults {
                await transitionToPreview()
                showPreview(
                    output: output,
                    targetApp: frontApp,
                    snapshot: selection.clipboardSnapshot,
                    sourceElement: selection.focusedElement,
                    mode: mode,
                    actionName: actionName)
                keepsInteractionOpen = true
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
    }

    /// Runs the built-in Ask flow. Selection capture happens before the input
    /// panel becomes key, so browser/web selections use the same proven capture
    /// and replacement path as every other Plyph action.
    func runAsk(targetApp: NSRunningApplication? = nil) async {
        guard !isBusy else { return }

        let frontApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        isBusy = true
        var keepsInteractionOpen = false
        defer {
            clearWorkingFeedback()
            if !keepsInteractionOpen { isBusy = false }
        }
        statusIcons?.showWorking()

        do {
            let selection = try await SelectionReader.read(settings: settings, frontApp: frontApp)
            let context = selection.text
            guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptError.noSelection
            }

            keepsInteractionOpen = try await presentAsk(
                context: context,
                selection: selection,
                targetApp: frontApp)
        } catch {
            handleError(error, mode: .prompt)
        }
    }

    func run(action reference: ActionReference, targetApp: NSRunningApplication? = nil) {
        guard !isBusy else {
            hud.show("Finish the current action first", isError: true, duration: 2.5)
            return
        }
        guard let descriptor = ActionCatalog.descriptor(for: reference, settings: settings) else {
            hud.show("This action is no longer available", isError: true, duration: 2.5)
            return
        }
        if descriptor.isAsk {
            Task { await runAsk(targetApp: targetApp) }
        } else if let mode = descriptor.mode {
            Task { await run(mode: mode, targetApp: targetApp) }
        }
    }

    func openActionPalette(
        forcePopup: Bool = false,
        targetApp explicitTarget: NSRunningApplication? = nil,
        context: SelectionContext? = nil
    ) {
        guard !isBusy else { return }
        let targetApp = explicitTarget ?? NSWorkspace.shared.frontmostApplication
        if forcePopup || settings.actionPalettePosition != "disabled" {
            ActionPaletteController.shared.show(
                context: context,
                modeHandler: { [weak self] mode in
                    Task { await self?.run(mode: mode, targetApp: targetApp) }
                },
                askHandler: { [weak self] in
                    Task { await self?.runAsk(targetApp: targetApp) }
                })
        } else {
            AppDelegate.shared?.statusItemController?.openMenu()
        }
    }

    private func routeCustomOutput(
        _ output: String,
        action: CustomAction,
        selection: Selection,
        targetApp: NSRunningApplication?
    ) async throws -> Bool {
        switch action.outputBehavior {
        case .preview:
            await transitionToPreview()
            showPreview(
                output: output,
                targetApp: targetApp,
                snapshot: selection.clipboardSnapshot,
                sourceElement: selection.focusedElement,
                mode: .custom(action),
                actionName: action.name)
            return true
        case .replaceSelection:
            try await replace(
                output,
                snapshot: selection.clipboardSnapshot,
                targetApp: targetApp,
                sourceElement: selection.focusedElement,
                message: action.name)
        case .copyToClipboard:
            ClipboardStore.write(output)
            statusIcons?.showSuccess()
            feedback("Copied", error: false, duration: 1.5)
        case .insertBeforeSelection:
            try await replace(
                output + selection.text,
                snapshot: selection.clipboardSnapshot,
                targetApp: targetApp,
                sourceElement: selection.focusedElement,
                message: action.name)
        case .insertAfterSelection:
            try await replace(
                selection.text + output,
                snapshot: selection.clipboardSnapshot,
                targetApp: targetApp,
                sourceElement: selection.focusedElement,
                message: action.name)
        case .openInAsk:
            return try await presentAsk(
                context: output,
                selection: selection,
                targetApp: targetApp)
        }
        return false
    }

    private func presentAsk(
        context: String,
        selection: Selection,
        targetApp: NSRunningApplication?
    ) async throws -> Bool {
        clearWorkingFeedback()
        hud.dismiss()
        statusIcons?.restoreDefault()

        let controller = AskInputController()
        askInputController = controller
        let instruction = await controller.request(context: context)
        guard let instruction else {
            askInputController = nil
            return false
        }
        let cleanedInstruction = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedInstruction.isEmpty else {
            controller.close()
            askInputController = nil
            return false
        }

        statusIcons?.showWorking()
        let options = RunOptions(
            provider: settings.promptRunProvider,
            model: settings.promptRunModel,
            inputMode: .prompt,
            inputLimit: settings.promptRunInputLimit,
            outputLimit: settings.promptRunOutputLimit)
        let request = AskRequest.userMessage(
            context: context,
            instruction: cleanedInstruction)
        let output = try await AiClient.shared.transform(
            text: request,
            mode: .prompt,
            customPrompt: AskRequest.systemPrompt,
            options: options,
            config: AiConfig.from(settings))

        controller.close()
        askInputController = nil
        await transitionToPreview()
        showPreview(
            output: output,
            targetApp: targetApp,
            snapshot: selection.clipboardSnapshot,
            sourceElement: selection.focusedElement,
            mode: .prompt,
            actionName: nil)
        return true
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
                self.isBusy = false
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.previewController = nil
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
        askInputController?.close()
        askInputController = nil
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
        workingFeedbackActive = false
        hud.show(message, isError: error, duration: duration)
    }

    private func beginWorkingFeedback() {
        workingFeedbackActive = true
        hud.show("Working…", isError: false, duration: 0)
    }

    private func transitionToPreview() async {
        statusIcons?.restoreDefault()
        guard hud.hasAnchoredSurface else {
            clearWorkingFeedback()
            return
        }
        feedback("Ready to review", error: false, duration: 0.7)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func clearWorkingFeedback() {
        guard workingFeedbackActive else { return }
        workingFeedbackActive = false
        hud.dismiss()
    }
}
