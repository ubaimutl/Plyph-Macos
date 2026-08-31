import AppKit

/// A temporary conversation-style result window used only by the built-in
/// Ask action. The selected text remains the fixed context while follow-up
/// instructions refine the answer that can ultimately be inserted.
@MainActor
final class AskPreviewController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var panel: AskPreviewPanel?
    private var messagesStack: NSStackView?
    private var messagesScroll: NSScrollView?
    private var followUpInput: NSTextView?
    private var followUpHeight: NSLayoutConstraint?
    private var followUpButton: NSButton?
    private var insertButton: NSButton?
    private var progress: NSProgressIndicator?
    private var errorLabel: NSTextField?
    private var turns: [AskConversationTurn]
    private var requestTask: Task<Void, Never>?
    private var isRequesting = false
    private var finishing = false

    private let onFollowUp: ([AskConversationTurn], String) async throws -> String
    private let onInsert: (String) -> Void
    private let onCancel: () -> Void

    init(
        question: String,
        response: String,
        onFollowUp: @escaping ([AskConversationTurn], String) async throws -> String,
        onInsert: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.turns = [AskConversationTurn(question: question, response: response)]
        self.onFollowUp = onFollowUp
        self.onInsert = onInsert
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        guard panel == nil else { return }

        let panel = AskPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel,
                        .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false)
        panel.title = "Ask Result"
        panel.minSize = NSSize(width: 540, height: 390)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }

        let content = NSView()
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        let title = NSTextField(labelWithString: "Ask about selected text")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let subtitle = NSTextField(
            labelWithString: "Refine the answer, then insert the latest response.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        self.progress = progress

        let header = NSStackView(views: [heading, NSView(), progress])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        let messagesScroll = NSScrollView()
        messagesScroll.hasVerticalScroller = true
        messagesScroll.hasHorizontalScroller = false
        messagesScroll.autohidesScrollers = true
        messagesScroll.drawsBackground = false
        messagesScroll.borderType = .noBorder
        messagesScroll.translatesAutoresizingMaskIntoConstraints = false
        self.messagesScroll = messagesScroll

        let messages = NSStackView()
        messages.orientation = .vertical
        messages.alignment = .leading
        messages.spacing = 12
        messages.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        messages.translatesAutoresizingMaskIntoConstraints = false
        messagesScroll.documentView = messages
        self.messagesStack = messages

        NSLayoutConstraint.activate([
            messages.leadingAnchor.constraint(equalTo: messagesScroll.contentView.leadingAnchor),
            messages.topAnchor.constraint(equalTo: messagesScroll.contentView.topAnchor),
            messages.widthAnchor.constraint(equalTo: messagesScroll.contentView.widthAnchor),
        ])

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        self.errorLabel = errorLabel

        let inputScroll = NSScrollView()
        inputScroll.borderType = .bezelBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.hasHorizontalScroller = false
        inputScroll.autohidesScrollers = true
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        let input = PlaceholderTextView()
        input.placeholderString = "Ask a follow-up or request a change…"
        input.font = .systemFont(ofSize: 13)
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.minSize = .zero
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
        self.followUpInput = input

        let followUp = NSButton(
            title: "Send",
            target: self,
            action: #selector(submitFollowUp))
        followUp.bezelStyle = .rounded
        followUp.isEnabled = false
        self.followUpButton = followUp

        let composer = NSStackView(views: [inputScroll, followUp])
        composer.orientation = .horizontal
        composer.alignment = .bottom
        composer.spacing = 8
        composer.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        followUpHeight = inputScroll.heightAnchor.constraint(equalToConstant: 56)
        followUpHeight?.isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded

        let insert = NSButton(
            title: "Insert Latest",
            target: self,
            action: #selector(insertLatest))
        insert.bezelStyle = .rounded
        self.insertButton = insert

        let actions = NSStackView(views: [cancel, insert])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(messagesScroll)
        content.addSubview(errorLabel)
        content.addSubview(composer)
        content.addSubview(separator)
        content.addSubview(actions)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            messagesScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            messagesScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            messagesScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            messagesScroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -6),

            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            composer.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 6),
            composer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            composer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            separator.topAnchor.constraint(equalTo: composer.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            actions.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        self.panel = panel
        rebuildMessages()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    private func rebuildMessages() {
        guard let messagesStack else { return }
        for view in messagesStack.arrangedSubviews {
            messagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, turn) in turns.enumerated() {
            messagesStack.addArrangedSubview(questionRow(turn.question))
            messagesStack.addArrangedSubview(responseRow(turn.response, index: index))
        }
        scrollToBottom()
    }

    private func questionRow(_ text: String) -> NSView {
        let bubble = bubbleView(text: text, isQuestion: true, responseIndex: nil)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        bubble.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(
                equalTo: messagesStack!.widthAnchor,
                constant: -32),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 60),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.78),
        ])
        return row
    }

    private func responseRow(_ text: String, index: Int) -> NSView {
        let bubble = bubbleView(text: text, isQuestion: false, responseIndex: index)
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        bubble.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(
                equalTo: messagesStack!.widthAnchor,
                constant: -32),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -40),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.88),
        ])
        return row
    }

    private func bubbleView(
        text: String,
        isQuestion: Bool,
        responseIndex: Int?
    ) -> NSView {
        let bubble = AskConversationBubble(isQuestion: isQuestion)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 0

        let body = NSStackView(views: [label])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.translatesAutoresizingMaskIntoConstraints = false

        if let responseIndex {
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyResponse(_:)))
            copy.bezelStyle = .inline
            copy.controlSize = .small
            copy.tag = responseIndex
            body.addArrangedSubview(copy)
        }

        bubble.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
        ])
        return bubble
    }

    func textDidChange(_ notification: Notification) {
        let value = followUpInput?.string
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        followUpButton?.isEnabled = !value.isEmpty && !isRequesting
        resizeComposer()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            submitFollowUp()
            return true
        }
        return false
    }

    private func resizeComposer() {
        guard let input = followUpInput,
              let textContainer = input.textContainer,
              let layoutManager = input.layoutManager,
              let followUpHeight else { return }
        input.enclosingScrollView?.contentView.layoutSubtreeIfNeeded()
        let width = max(1, input.enclosingScrollView?.contentView.bounds.width ?? 1)
        textContainer.containerSize = NSSize(
            width: max(1, width - input.textContainerInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            + input.textContainerInset.height * 2
        followUpHeight.constant = min(max(usedHeight, 56), 120)
    }

    @objc private func submitFollowUp() {
        guard !isRequesting else { return }
        let instruction = followUpInput?.string
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instruction.isEmpty else { return }

        isRequesting = true
        setError(nil)
        followUpInput?.isEditable = false
        followUpButton?.isEnabled = false
        insertButton?.isEnabled = false
        progress?.startAnimation(nil)
        messagesStack?.addArrangedSubview(questionRow(instruction))
        scrollToBottom()

        let history = turns
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.onFollowUp(history, instruction)
                guard !self.finishing else { return }
                self.turns.append(
                    AskConversationTurn(question: instruction, response: response))
                self.followUpInput?.string = ""
                self.finishRequest()
                self.rebuildMessages()
            } catch {
                guard !self.finishing else { return }
                self.finishRequest()
                self.rebuildMessages()
                self.setError(error.localizedDescription)
            }
        }
    }

    private func finishRequest() {
        requestTask = nil
        isRequesting = false
        progress?.stopAnimation(nil)
        followUpInput?.isEditable = true
        insertButton?.isEnabled = true
        let hasText = !(followUpInput?.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        followUpButton?.isEnabled = hasText
        panel?.makeFirstResponder(followUpInput)
    }

    private func setError(_ message: String?) {
        errorLabel?.stringValue = message ?? ""
        errorLabel?.isHidden = message == nil
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let lastMessage = self?.messagesStack?.arrangedSubviews.last else { return }
            lastMessage.scrollToVisible(lastMessage.bounds)
        }
    }

    @objc private func copyResponse(_ sender: NSButton) {
        guard turns.indices.contains(sender.tag) else { return }
        ClipboardStore.write(turns[sender.tag].response)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak sender] in
            sender?.title = "Copy"
        }
    }

    @objc private func insertLatest() {
        guard !finishing, !isRequesting, let latest = turns.last?.response else { return }
        finishing = true
        close()
        onInsert(latest)
    }

    @objc private func cancel() {
        guard !finishing else { return }
        finishing = true
        close()
        onCancel()
    }

    private func close() {
        requestTask?.cancel()
        requestTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !finishing else { return }
        finishing = true
        requestTask?.cancel()
        requestTask = nil
        panel = nil
        onCancel()
    }

    func windowDidResize(_ notification: Notification) {
        resizeComposer()
    }
}

private final class AskPreviewPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class AskConversationBubble: NSView {
    private let isQuestion: Bool

    init(isQuestion: Bool) {
        self.isQuestion = isQuestion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isQuestion
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = isQuestion ? 0 : 0.5
    }
}
