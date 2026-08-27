import AppKit

/// Preview window shown before replacing (when `preview-results` is on):
/// the generated text is editable and selectable, with a wrap toggle, an
/// expand toggle and Cancel / Copy / Replace buttons — ported from the GNOME
/// ResultDialog, including Escape-to-cancel and Ctrl/Cmd+Return-to-replace.
@MainActor
final class PreviewController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var wrapButton: NSButton?
    private var expandButton: NSButton?
    private var compactFrame = NSRect.zero
    private var expanded = false

    private let onReplace: (String) -> Void
    private let onCopy: (String) -> Void
    private let onCancel: () -> Void

    init(result: String, onReplace: @escaping (String) -> Void,
         onCopy: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onReplace = onReplace
        self.onCopy = onCopy
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        guard panel == nil else { return }

        let panel = PreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let effect = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        effect.material = .windowBackground
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        // Header: Result — Wrap — Expand
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        let title = NSTextField(labelWithString: "Result")
        title.font = .boldSystemFont(ofSize: 15)
        let wrap = NSButton(title: "Wrap", target: self, action: #selector(toggleWrap))
        wrap.setButtonType(.pushOnPushOff)
        wrap.bezelStyle = .rounded
        wrap.state = .on
        let expand = NSButton(title: "", target: self, action: #selector(toggleExpand))
        expand.isBordered = false
        expand.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Expand preview")
        header.addArrangedSubview(title)
        header.addArrangedSubview(wrap)
        header.addArrangedSubview(expand)
        header.translatesAutoresizingMaskIntoConstraints = false

        // Editable, selectable result text.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        text.isEditable = true
        text.isSelectable = true
        text.richText = false
        text.font = .systemFont(ofSize: 13)
        text.string = result
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.drawsBackground = false
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        self.textView = text
        self.wrapButton = wrap
        self.expandButton = expand

        // Buttons: Cancel / Copy / Replace (Replace is the primary action).
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        let replace = NSButton(title: "Replace", target: self, action: #selector(replaceClicked))
        replace.bezelStyle = .rounded
        replace.hasDestructiveAction = false
        replace.keyEquivalent = "\r"
        replace.highlight(true)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(copy)
        buttons.addArrangedSubview(replace)
        buttons.setHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(header)
        effect.addSubview(scroll)
        effect.addSubview(buttons)
        panel.contentView = effect

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
        ])

        panel.onEscape = { [weak self] in self?.cancelClicked() }
        panel.onActionReturn = { [weak self] in self?.replaceClicked() }

        self.panel = panel

        // Compute the compact frame from the GNOME sizing rules.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenWidth = screen?.frame.width ?? 1200
        let screenHeight = screen?.frame.height ?? 800
        let estimatedLines = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { total, line in
                total + max(1, Int(ceil(Double(line.count) / 70.0)))
            }
        let width = min(680, max(500, screenWidth * 0.4))
        let height = min(
            max(200, screenHeight * 0.5),
            max(96, CGFloat(estimatedLines) * 21 + 24))
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
    }

    // MARK: Actions

    @objc private func toggleWrap() {
        guard let text = textView else { return }
        let wrapOn = (wrapButton?.state ?? .on) == .on
        text.textContainer?.widthTracksTextView = wrapOn
        if !wrapOn {
            text.textContainer?.containerSize = NSSize(width: 10_000, height: .greatestFiniteMagnitude)
        }
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
        let screenWidth = screen?.frame.width ?? 1200
        let screenHeight = screen?.frame.height ?? 800
        let size: NSSize
        if expanded {
            size = NSSize(
                width: max(480, screenWidth - 160),
                height: max(260, screenHeight - 300))
        } else {
            size = compactFrame.size
        }
        let frame = centerIn(screen: screen, size: size)
        panel?.setFrame(frame, display: true, animate: true)
    }

    @objc private func replaceClicked() {
        let text = textView?.string ?? ""
        close()
        onReplace(text)
    }

    @objc private func copyClicked() {
        let text = textView?.string ?? ""
        close()
        onCopy(text)
    }

    @objc private func cancelClicked() {
        close()
        onCancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Like a sheet: leaving the preview without a decision cancels it.
        // (The GNOME dialog is modal; here Escape, the close button, or
        // switching away all cancel.)
        if panel != nil {
            close()
            onCancel()
        }
    }
}

/// Panel subclass implementing the preview keyboard behavior: Escape cancels,
/// Ctrl+Return or Cmd+Return replaces.
final class PreviewPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onActionReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .command])
        if event.keyCode == 53 {  // Escape
            onEscape?()
            return
        }
        if event.keyCode == 36 && !flags.isEmpty {  // Return with Ctrl or Cmd
            onActionReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
