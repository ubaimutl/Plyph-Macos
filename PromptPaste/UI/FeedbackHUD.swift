import AppKit

/// Floating status label that follows the pointer — the macOS equivalent of the
/// GNOME extension's pointer-feedback label ("Working…", errors, "Copied").
/// Automatically disabled when the user turns `pointer-feedback` off.
@MainActor
final class FeedbackHUD {
    static let shared = FeedbackHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String, isError: Bool, duration: TimeInterval) {
        let settings = SettingsStore.shared
        if !settings.pointerFeedback {
            // GNOME falls back to a notification only for errors.
            if isError {
                present(message: message, isError: true, duration: duration)
            }
            return
        }
        present(message: message, isError: isError, duration: duration)
    }

    private func present(message: String, isError: Bool, duration: TimeInterval) {
        hideTask?.cancel()
        if panel == nil {
            createPanel()
        }
        guard let panel, let label else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let maxWidth: CGFloat = 360
        let fitting = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let padding = NSEdgeInsets(
            top: 8, left: 12, bottom: 8, right: 12)
        let size = NSSize(
            width: ceil(fitting.width) + padding.left + padding.right,
            height: ceil(fitting.height) + padding.top + padding.bottom)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
        label.attributedStringValue = attributed

        let color = isError
            ? NSColor(red: 145 / 255, green: 28 / 255, blue: 28 / 255, alpha: 0.96)
            : NSColor(calibratedWhite: 32 / 255, alpha: 0.94)
        panel.backgroundColor = color

        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }

        if duration > 0 {
            hideTask = Task { [weak self, panel] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                })
                _ = self
            }
        }
    }

    private func createPanel() {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byWordWrapping
        label.autoresizingMask = [.width]
        label.frame = NSRect(x: 12, y: 8, width: 336, height: 18)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = label
        panel.isReleasedWhenClosed = false
        self.panel = panel
        self.label = label
    }

    /// Keeps the label near the pointer (clamped to screen edges), mirroring
    /// the GNOME follow-the-pointer behavior.
    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        var x = mouse.x + 16
        var y = mouse.y - panel.frame.height - 20
        for screen in NSScreen.screens {
            if screen.frame.contains(mouse) {
                x = min(max(x, screen.frame.minX + 8),
                        screen.frame.maxX - panel.frame.width - 8)
                y = min(max(y, screen.frame.minY + 8),
                        screen.frame.maxY - panel.frame.height - 8)
                break
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
