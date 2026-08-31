import AppKit

/// Preview window shown before replacing (when `preview-results` is on).
@MainActor
final class PreviewController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var wrapButton: NSButton?
    private var expandButton: NSButton?
    private var compactFrame = NSRect.zero
    private var expanded = false
    private var finishing = false
    private let result: String

    private let onReplace: (String) -> Void
    private let onCopy: (String) -> Void
    private let onCancel: () -> Void

    init(result: String, onReplace: @escaping (String) -> Void,
         onCopy: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.result = result
        self.onReplace = onReplace
        self.onCopy = onCopy
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        guard panel == nil else { return }

        let panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 380),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel,
                        .unifiedTitleAndToolbar],
            backing: .buffered, defer: false)
        panel.title = "Preview Result"
        panel.minSize = NSSize(width: 560, height: 300)
        panel.isOpaque = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = false
        panel.toolbarStyle = .unified
        panel.delegate = self

        // Content area inside the titled panel chrome.
        let content = NSView()
        content.autoresizingMask = [.width, .height]

        // Wrap text in a scroll view
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        self.scrollView = scroll

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 280))
        text.isEditable = true
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 13)
        text.string = result
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 8)
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false

        self.textView = text

        let removeMarkdown = NSButton(
            title: "Remove Markdown",
            target: self,
            action: #selector(removeMarkdownClicked))
        removeMarkdown.bezelStyle = .rounded
        removeMarkdown.controlSize = .small
        removeMarkdown.toolTip = "Convert common Markdown formatting to plain text"

        // Wrap toggle button
        let wrap = NSButton(title: "Wrap", target: self, action: #selector(toggleWrap))
        wrap.setButtonType(.pushOnPushOff)
        wrap.bezelStyle = .rounded
        wrap.controlSize = .small
        wrap.state = .on
        self.wrapButton = wrap

        // Expand toggle
        let expand = NSButton(title: "", target: self, action: #selector(toggleExpand))
        expand.isBordered = false
        expand.imageScaling = .scaleProportionallyDown
        expand.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Expand preview")
        self.expandButton = expand

        // Right-aligned accessory controls in a stack
        let accessory = NSStackView(views: [removeMarkdown, wrap, expand])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.alignment = .centerY

        // Accessory toolbar: placed in a thin bar below the title bar
        let accessoryBar = NSView()
        accessoryBar.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessoryBar.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: accessoryBar.trailingAnchor, constant: -16),
            accessory.centerYAnchor.constraint(equalTo: accessoryBar.centerYAnchor),
            accessoryBar.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Bottom action buttons
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copyBtn.bezelStyle = .rounded

        let replaceBtn = NSButton(title: "Replace", target: self, action: #selector(replaceClicked))
        replaceBtn.bezelStyle = .rounded
        replaceBtn.keyEquivalent = "\r"

        let buttons = NSStackView(views: [cancelBtn, copyBtn, replaceBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.setHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // Separator above buttons
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(accessoryBar)
        content.addSubview(scroll)
        content.addSubview(sep)
        content.addSubview(buttons)
        panel.contentView = content

        NSLayoutConstraint.activate([
            accessoryBar.topAnchor.constraint(equalTo: content.topAnchor),
            accessoryBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            accessoryBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: accessoryBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: sep.topAnchor),

            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])

        panel.onEscape = { [weak self] in self?.cancelClicked() }
        panel.onActionReturn = { [weak self] in self?.replaceClicked() }
        self.panel = panel

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let estimatedLines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { total, line in
                total + max(1, Int(ceil(Double(line.count) / 80.0)))
            }

        let width = min(760, max(640, visible.width * 0.55))
        let contentDrivenHeight = CGFloat(estimatedLines) * 21 + 150
        let height = min(max(340, visible.height * 0.52), max(340, contentDrivenHeight))
        compactFrame = NSRect(x: 0, y: 0, width: width, height: height)

        panel.setFrame(centerIn(screen: screen, size: compactFrame.size), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
    }

    private func centerIn(screen: NSScreen?, size: NSSize) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(
            x: 0, y: 0, width: 1200, height: 800)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        scrollView = nil
    }

    // MARK: Actions

    @objc private func removeMarkdownClicked() {
        guard let text = textView else { return }
        let cleaned = MarkdownTextCleaner.plainText(from: text.string)
        guard cleaned != text.string else { return }

        let fullRange = NSRange(location: 0, length: (text.string as NSString).length)
        text.setSelectedRange(fullRange)
        text.insertText(cleaned, replacementRange: fullRange)
        text.setSelectedRange(NSRange(location: (cleaned as NSString).length, length: 0))
    }

    @objc private func toggleWrap() {
        guard let text = textView else { return }
        let wrapOn = (wrapButton?.state ?? .on) == .on
        text.isHorizontallyResizable = !wrapOn
        text.autoresizingMask = wrapOn ? [.width] : []
        scrollView?.hasHorizontalScroller = !wrapOn
        if wrapOn {
            text.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
        } else {
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(
                width: 10_000,
                height: CGFloat.greatestFiniteMagnitude)
        }
        text.enclosingScrollView?.contentView.layoutSubtreeIfNeeded()
        text.needsLayout = true
    }

    @objc private func toggleExpand() {
        expanded.toggle()
        expandButton?.image = NSImage(
            systemSymbolName: expanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: expanded ? "Restore preview size" : "Expand preview")

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size: NSSize
        if expanded {
            size = NSSize(
                width: max(640, visible.width - 120),
                height: max(400, visible.height - 140))
        } else {
            size = compactFrame.size
        }
        panel?.setFrame(centerIn(screen: screen, size: size), display: true, animate: true)
    }

    @objc private func replaceClicked() {
        guard !finishing else { return }
        finishing = true
        let text = textView?.string ?? ""
        close()
        onReplace(text)
    }

    @objc private func copyClicked() {
        guard !finishing else { return }
        finishing = true
        let text = textView?.string ?? ""
        close()
        onCopy(text)
    }

    @objc private func cancelClicked() {
        guard !finishing else { return }
        finishing = true
        close()
        onCancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss only when the user genuinely leaves the preview. Do not fire
        // Cancel as a side effect of Replace/Copy closing the panel.
        guard panel != nil, !finishing else { return }
        finishing = true
        close()
        onCancel()
    }
}

final class PreviewPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onActionReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .command])
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if event.keyCode == 36 && !flags.isEmpty {
            onActionReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
