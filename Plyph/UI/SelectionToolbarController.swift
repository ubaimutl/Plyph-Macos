import AppKit
import QuartzCore

/// Compact, non-activating selection surface. It owns only presentation and
/// forwards stable action references to ActionRunner through its callbacks.
@MainActor
final class SelectionToolbarController {
    private let collapsedSize = NSSize(width: 30, height: 30)
    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var actionStack: NSStackView?
    private var anchor = NSPoint.zero
    private var targetScreen: NSScreen?
    private var descriptors: [ActionDescriptor] = []
    private var actionViews: [ActionReference: SelectionToolbarAction] = [:]
    private var moreActionView: SelectionToolbarAction?
    private var activeAction: ActionReference?
    private var feedbackTask: Task<Void, Never>?
    private var onAction: ((ActionReference) -> Void)?
    private var onMore: (() -> Void)?

    private(set) var isExpanded = false
    var isVisible: Bool { panel?.isVisible == true }
    var isShowingActionStatus: Bool { activeAction != nil }
    var frame: NSRect { panel?.frame ?? .zero }

    func show(
        near anchor: NSPoint,
        on screen: NSScreen?,
        actions: [ActionDescriptor],
        onAction: @escaping (ActionReference) -> Void,
        onMore: @escaping () -> Void
    ) {
        self.anchor = anchor
        self.targetScreen = screen
        self.descriptors = Array(actions.prefix(QuickActionConfiguration.maximumCount))
        self.onAction = onAction
        self.onMore = onMore
        feedbackTask?.cancel()
        feedbackTask = nil
        activeAction = nil
        if panel == nil { buildPanel() }
        rebuildActionViews()
        collapse(animated: false)
        position(size: collapsedSize, animated: false)

        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func toggleExpanded() {
        isExpanded ? collapse(animated: true) : expand()
    }

    func collapse(animated: Bool) {
        guard isExpanded || !animated else { return }
        isExpanded = false
        actionStack?.alphaValue = 0
        position(size: collapsedSize, animated: animated)
    }

    func handleEscape() {
        hide()
    }

    func hide() {
        feedbackTask?.cancel()
        feedbackTask = nil
        activeAction = nil
        isExpanded = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    func beginAction(_ reference: ActionReference) {
        guard isVisible, actionViews[reference] != nil else { return }
        feedbackTask?.cancel()
        feedbackTask = nil
        activeAction = reference
        for (candidate, view) in actionViews {
            view.state = candidate == reference ? .working : .disabled
        }
        moreActionView?.state = .disabled
    }

    private func expand() {
        isExpanded = true
        let availableWidth = max(
            collapsedSize.width,
            (targetScreen?.visibleFrame.width ?? expandedWidth()) - 12)
        let size = NSSize(width: min(expandedWidth(), availableWidth), height: 30)
        position(size: size, animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            actionStack?.animator().alphaValue = 1
        }
    }

    private func expandedWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let actionWidths = descriptors.reduce(CGFloat.zero) { total, descriptor in
            let titleWidth = (descriptor.name as NSString).size(
                withAttributes: [.font: font]).width
            return total + min(104, max(58, ceil(titleWidth) + 30))
        }
        return 30 + actionWidths + 34
    }

    private func position(size: NSSize, animated: Bool) {
        guard let panel else { return }
        let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8
        var origin = NSPoint(x: anchor.x - collapsedSize.width / 2, y: anchor.y + gap)
        if origin.y + size.height > visible.maxY - 6 {
            origin.y = anchor.y - gap - size.height
        }
        origin.x = max(visible.minX + 6, min(origin.x, visible.maxX - size.width - 6))
        origin.y = max(visible.minY + 6, min(origin.y, visible.maxY - size.height - 6))
        let frame = NSRect(origin: origin, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: collapsedSize))
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let logo = SelectionToolbarLogo(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 30).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 30).isActive = true
        logo.onClick = { [weak self] in self?.toggleExpanded() }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 1
        actions.alphaValue = 0
        self.actionStack = actions

        let root = NSStackView(views: [logo, actions])
        root.orientation = .horizontal
        root.alignment = .centerY
        root.spacing = 1
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        self.panel = panel
        self.effectView = effect
    }

    private func rebuildActionViews() {
        guard let actionStack else { return }
        actionViews.removeAll()
        moreActionView = nil
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for descriptor in descriptors {
            let view = SelectionToolbarAction(
                title: descriptor.name,
                icon: descriptor.icon)
            view.onClick = { [weak self] in
                self?.onAction?(descriptor.reference)
            }
            actionStack.addArrangedSubview(view)
            actionViews[descriptor.reference] = view
        }
        let more = SelectionToolbarAction(
            title: "",
            icon: ActionSymbol.image(named: "ellipsis"),
            fixedWidth: 32)
        more.toolTip = "More actions"
        more.onClick = { [weak self] in
            self?.hide()
            self?.onMore?()
        }
        actionStack.addArrangedSubview(more)
        moreActionView = more
    }
}

extension SelectionToolbarController: ActionFeedbackSurface {
    var canPresentFeedback: Bool { isVisible && activeAction != nil }

    func presentFeedback(
        _ message: String,
        isError: Bool,
        isWorking: Bool,
        duration: TimeInterval
    ) {
        guard let activeAction, let activeView = actionViews[activeAction] else { return }
        feedbackTask?.cancel()
        feedbackTask = nil

        activeView.toolTip = isError ? message : nil
        activeView.state = isWorking ? .working : (isError ? .error : .success)
        for (reference, view) in actionViews where reference != activeAction {
            view.state = .disabled
        }
        moreActionView?.state = .disabled

        guard duration > 0 else { return }
        let visibleDuration = isError ? duration : min(duration, 0.8)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(visibleDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hide()
        }
    }

    func dismissFeedback() {
        hide()
    }
}

private class SelectionToolbarHitView: NSView {
    var onClick: (() -> Void)?
    var hovered = false { didSet { needsDisplay = true } }
    var interactionEnabled = true {
        didSet {
            if !interactionEnabled { hovered = false }
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if interactionEnabled { hovered = true }
    }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        if interactionEnabled { onClick?() }
    }
    override var acceptsFirstResponder: Bool { false }
}

private final class SelectionToolbarLogo: SelectionToolbarHitView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor(white: hovered ? 0.08 : 0.02, alpha: 0.96).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(hovered ? 0.35 : 0.2).setStroke()
        path.lineWidth = 1
        path.stroke()
        if let logo = NSImage(named: "SelectionDotIcon") ?? NSImage(named: "MenuBarIcon") {
            logo.draw(
                in: NSRect(x: 7, y: 7, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1)
        }
    }
}

private final class SelectionToolbarAction: SelectionToolbarHitView {
    enum State {
        case normal
        case disabled
        case working
        case success
        case error
    }

    private let title: String
    private let icon: NSImage?
    private let progress = NSProgressIndicator()
    var state = State.normal {
        didSet {
            interactionEnabled = state == .normal
            progress.isHidden = state != .working
            if state == .working {
                progress.startAnimation(nil)
            } else {
                progress.stopAnimation(nil)
            }
            needsDisplay = true
        }
    }

    init(title: String, icon: NSImage?, fixedWidth: CGFloat? = nil) {
        self.title = title
        self.icon = icon
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        widthAnchor.constraint(equalToConstant: fixedWidth ?? min(104, max(58, titleWidth + 30)))
            .isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        progress.frame = NSRect(x: 7, y: 5, width: 16, height: 16)
        addSubview(progress)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && state == .normal {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
                .fill()
        }
        let iconSize: CGFloat = 13
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleColor: NSColor = state == .disabled ? .tertiaryLabelColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: titleColor,
        ]
        let displayIcon: NSImage?
        switch state {
        case .working: displayIcon = nil
        case .success:
            displayIcon = ActionSymbol.image(named: "checkmark.circle.fill")
        case .error:
            displayIcon = ActionSymbol.image(named: "exclamationmark.triangle.fill")
        case .normal, .disabled:
            displayIcon = icon
        }
        let iconFraction: CGFloat = state == .disabled ? 0.3 : 0.8
        if title.isEmpty {
            displayIcon?.draw(
                in: NSRect(
                    x: floor((bounds.width - iconSize) / 2),
                    y: floor((bounds.height - iconSize) / 2),
                    width: iconSize,
                    height: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: iconFraction)
            return
        }
        displayIcon?.draw(
            in: NSRect(x: 8, y: floor((bounds.height - iconSize) / 2), width: iconSize, height: iconSize),
            from: .zero,
            operation: .sourceOver,
            fraction: iconFraction)
        let titleSize = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 25, y: floor((bounds.height - titleSize.height) / 2)),
            withAttributes: attributes)
    }
}
