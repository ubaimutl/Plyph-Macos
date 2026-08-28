import AppKit

/// Compact pointer-following feedback HUD used for working, success and error
/// messages. It deliberately stays non-activating so it never steals focus
/// from the application whose selection PromptPaste is transforming.
@MainActor
final class FeedbackHUD: NSObject {
    static let shared = FeedbackHUD()

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var label: NSTextField?
    private var iconView: NSImageView?
    private var hideTask: Task<Void, Never>?
    private var followTimer: Timer?

    private override init() {
        super.init()
    }

    func show(_ message: String, isError: Bool, duration: TimeInterval) {
        let settings = SettingsStore.shared
        if !settings.pointerFeedback {
            if isError {
                present(message: message, isError: true, duration: duration)
            }
            return
        }
        present(message: message, isError: isError, duration: duration)
    }

    private func present(message: String, isError: Bool, duration: TimeInterval) {
        hideTask?.cancel()
        hideTask = nil

        if panel == nil {
            createPanel()
        }
        guard
            let panel,
            let effectView,
            let label,
            let iconView
        else { return }

        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let maxTextWidth: CGFloat = 300
        let fitting = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        let horizontalPadding: CGFloat = 13
        let iconWidth: CGFloat = 16
        let gap: CGFloat = 8
        let contentWidth = min(maxTextWidth, ceil(fitting.width))
        let width = max(112, contentWidth + horizontalPadding * 2 + iconWidth + gap)
        let height = max(38, min(72, ceil(fitting.height) + 18))
        let size = NSSize(width: width, height: height)

        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        effectView.frame = NSRect(origin: .zero, size: size)

        let iconY = floor((height - iconWidth) / 2)
        iconView.frame = NSRect(
            x: horizontalPadding,
            y: iconY,
            width: iconWidth,
            height: iconWidth)
        label.frame = NSRect(
            x: horizontalPadding + iconWidth + gap,
            y: 7,
            width: width - horizontalPadding * 2 - iconWidth - gap,
            height: height - 14)
        label.attributedStringValue = attributed

        let symbolName: String
        if isError {
            symbolName = "exclamationmark.circle.fill"
            iconView.contentTintColor = .systemRed
        } else if message.lowercased().contains("working") {
            symbolName = "sparkles"
            iconView.contentTintColor = .secondaryLabelColor
        } else {
            symbolName = "checkmark.circle.fill"
            iconView.contentTintColor = .systemGreen
        }
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isError ? "Error" : "Status")

        position()
        startFollowingPointer()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        if duration > 0 {
            hideTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(duration * 1_000_000_000))
                guard let self, !Task.isCancelled, let panel = self.panel else { return }

                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panel.animator().alphaValue = 0
                }
                try? await Task.sleep(nanoseconds: 170_000_000)
                guard !Task.isCancelled else { return }
                panel.orderOut(nil)
                self.stopFollowingPointer()
                self.hideTask = nil
            }
        }
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        let icon = NSImageView(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2

        effect.addSubview(icon)
        effect.addSubview(label)
        panel.contentView = effect

        self.panel = panel
        self.effectView = effect
        self.iconView = icon
        self.label = label
    }

    private func startFollowingPointer() {
        guard followTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(followPointerTick),
            userInfo: nil,
            repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowingPointer() {
        followTimer?.invalidate()
        followTimer = nil
    }

    @objc private func followPointerTick() {
        position()
    }

    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        var x = mouse.x + 18
        var y = mouse.y - panel.frame.height - 18

        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            let visible = screen.visibleFrame
            x = min(
                max(x, visible.minX + 8),
                visible.maxX - panel.frame.width - 8)
            y = min(
                max(y, visible.minY + 8),
                visible.maxY - panel.frame.height - 8)
            break
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
