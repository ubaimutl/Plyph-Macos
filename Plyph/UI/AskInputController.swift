import AppKit

/// Compact native input panel for the built-in Ask action. It is shown only
/// after Plyph has captured the source selection, so taking keyboard focus here
/// cannot destroy the browser/editor context needed for replacement.
@MainActor
final class AskInputController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var panel: AskInputPanel?
    private var input: NSTextView?
    private var inputHeightConstraint: NSLayoutConstraint?
    private var askButton: NSButton?
    private var cancelButton: NSButton?
    private var progress: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var continuation: CheckedContinuation<String?, Never>?
    private var finishing = false
    private var anchor = NSPoint.zero

    func request(context: String) async -> String? {
        finishing = false
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.show(context: context)
        }
    }

    private func show(context: String) {
        let preferredWidth: CGFloat = 430
        anchor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let availableWidth = max(320, (screen?.visibleFrame.width ?? preferredWidth) - 32)
        let size = NSSize(width: min(preferredWidth, availableWidth), height: 170)
        let panel = AskInputPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        // Keep the width compact while allowing the instruction editor to grow
        // vertically as the user writes or pastes a longer request.
        panel.minSize = size
        panel.maxSize = NSSize(width: size.width, height: 360)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let icon = NSImageView(
            image: ActionSymbol.image(named: "questionmark.bubble") ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let title = NSTextField(labelWithString: "Ask about selected text")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [icon, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let contextLabel = NSTextField(labelWithString: contextPreview(context))
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.maximumNumberOfLines = 1
        contextLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        let inputScroll = NSScrollView()
        inputScroll.borderType = .bezelBorder
        inputScroll.drawsBackground = true
        inputScroll.hasVerticalScroller = true
        inputScroll.hasHorizontalScroller = false
        inputScroll.autohidesScrollers = true
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        let input = PlaceholderTextView()
        input.placeholderString = "What do you want to do with this text?"
        input.font = .systemFont(ofSize: 13)
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.minSize = NSSize(width: 0, height: 0)
        input.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        input.textContainerInset = NSSize(width: 6, height: 6)
        input.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        input.textContainer?.widthTracksTextView = true
        input.delegate = self
        inputScroll.documentView = input
        self.input = input

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        self.cancelButton = cancel

        let ask = NSButton(title: "Ask", target: self, action: #selector(submit))
        ask.bezelStyle = .rounded
        ask.controlSize = .small
        ask.keyEquivalent = "\r"
        ask.isEnabled = false
        self.askButton = ask

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        self.progress = progress

        let status = NSTextField(labelWithString: "Thinking…")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.isHidden = true
        self.statusLabel = status

        let buttons = NSStackView(views: [progress, status, NSView(), cancel, ask])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(titleRow)
        effect.addSubview(contextLabel)
        effect.addSubview(inputScroll)
        effect.addSubview(buttons)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: effect.topAnchor, constant: 13),
            titleRow.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            titleRow.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),

            contextLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 7),
            contextLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            contextLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),

            inputScroll.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 8),
            inputScroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            inputScroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),

            buttons.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 9),
            buttons.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor, constant: -10),
        ])
        inputHeightConstraint = inputScroll.heightAnchor.constraint(equalToConstant: 58)
        inputHeightConstraint?.isActive = true

        panel.setContentSize(size)
        position(panel)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        resizeInputToFit()
    }

    private func contextPreview(_ context: String) -> String {
        let collapsed = context
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > 170 else { return collapsed }
        return String(collapsed.prefix(167)) + "…"
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }

        var x = anchor.x + 12
        var y = anchor.y - panel.frame.height - 12
        x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func textDidChange(_ notification: Notification) {
        let instruction = input?.string
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        askButton?.isEnabled = !instruction.isEmpty
        resizeInputToFit()
    }

    @objc private func submit() {
        guard !finishing else { return }
        let instruction = input?.string
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instruction.isEmpty else {
            NSSound.beep()
            return
        }
        finishing = true
        input?.isEditable = false
        askButton?.isHidden = true
        cancelButton?.isHidden = true
        progress?.isHidden = false
        progress?.startAnimation(nil)
        statusLabel?.isHidden = false
        panel?.makeFirstResponder(nil)

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: instruction)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            submit()
            return true
        }
        return false
    }

    private func resizeInputToFit() {
        guard let panel, let input, let inputHeightConstraint else { return }
        guard let textContainer = input.textContainer,
              let layoutManager = input.layoutManager else { return }

        panel.contentView?.layoutSubtreeIfNeeded()
        let scrollWidth = input.enclosingScrollView?.contentView.bounds.width ?? 0
        let textWidth = max(
            1,
            scrollWidth > 1
                ? scrollWidth
                : (panel.contentView?.bounds.width ?? panel.frame.width) - 28)
        textContainer.containerSize = NSSize(
            width: textWidth - input.textContainerInset.width * 2,
            height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            + input.textContainerInset.height * 2
        let inputHeight = min(max(textHeight, 58), 210)
        guard abs(inputHeightConstraint.constant - inputHeight) > 0.5 else { return }

        inputHeightConstraint.constant = inputHeight
        let newHeight = min(max(112 + inputHeight, 170), 360)
        panel.setContentSize(NSSize(width: panel.frame.width, height: newHeight))
        position(panel)
    }

    @objc private func cancel() {
        guard !finishing else { return }
        finishing = true
        let continuation = self.continuation
        self.continuation = nil
        close()
        continuation?.resume(returning: nil)
    }

    func close() {
        let pendingContinuation = continuation
        self.continuation = nil

        progress?.stopAnimation(nil)
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        input = nil
        inputHeightConstraint = nil
        askButton = nil
        cancelButton = nil
        progress = nil
        statusLabel = nil

        pendingContinuation?.resume(returning: nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel != nil, !finishing else { return }
        cancel()
    }
}

final class AskInputPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
