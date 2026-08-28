import AppKit
import ApplicationServices

/// Optional floating action indicator: a small non-activating panel that
/// appears near the user's selection and, when clicked, opens the action
/// palette — similar to the PromptPaste Chrome extension's selection bubble.
///
/// ## Approach
/// Uses `NSEvent.addGlobalMonitorForEvents` and `NSEvent.addLocalMonitorForEvents`
/// to detect mouse-up events (which end text selection). After a debounce, reads
/// the focused app's selected text via AX. If text is selected, shows a small dot
/// near the selection bounds (or near the mouse cursor when AX bounds are unavailable,
/// e.g. in WKWebView content — a documented macOS AX limitation).
///
/// ## Focus steal prevention
/// The panel uses `.nonactivatingPanel` so it never steals key focus.
@MainActor
final class SelectionDotController: NSObject {

    static let shared = SelectionDotController()
    private override init() { super.init() }

    private var enabled = false
    private var panel: NSPanel?
    private var debounceTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var onActivate: (() -> Void)?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    // MARK: Public

    func start(onActivate: @escaping () -> Void) {
        guard !enabled else { return }
        enabled = true
        self.onActivate = onActivate
        installMonitors()
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        removeMonitors()
        hideDot()
    }

    // MARK: Mouse monitoring

    private func installMonitors() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleCheck()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in
                self.scheduleCheck()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let m = localMouseMonitor {
            NSEvent.removeMonitor(m)
            localMouseMonitor = nil
        }
    }

    private func scheduleCheck() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            // 250 ms debounce gives the host application time to commit the selection.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self.evaluateCurrentSelection()
        }
    }

    // MARK: Selection evaluation

    private func evaluateCurrentSelection() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        var element: AXUIElement?

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        }

        if element == nil {
            element = AXElement.focusedElement()
        }

        var hasSelection = false
        var targetElement = element

        // 1. Try to read the text directly via Accessibility
        if let targetElement {
            var textRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                targetElement, kAXSelectedTextAttribute as CFString, &textRef) == .success,
               let str = textRef as? String,
               !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasSelection = true
            }
        }

        // 2. If AX text read failed (Chrome, Electron, some WebKit elements), check if Edit > Copy is enabled!
        if !hasSelection {
            if AXMenuAction.isCopyEnabled(in: frontApp) {
                hasSelection = true
            }
        }

        guard hasSelection else {
            hideDot()
            return
        }

        let pos: NSPoint
        if let targetElement, let pt = selectionEndPoint(element: targetElement) {
            pos = pt
        } else {
            pos = nearMouse()
        }
        showDot(at: pos)
    }

    private func selectionEndPoint(element: AXUIElement) -> NSPoint? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeRef, &boundsRef) == .success,
              let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = screenH - rect.origin.y - rect.height
        return NSPoint(x: rect.maxX + 8, y: cocoaY + rect.height / 2)
    }

    private func nearMouse() -> NSPoint {
        let m = NSEvent.mouseLocation
        return NSPoint(x: m.x + 14, y: m.y + 14)
    }

    // MARK: Dot panel

    private func showDot(at pt: NSPoint) {
        hideTask?.cancel()
        hideTask = nil
        if panel == nil { buildPanel() }
        guard let panel else { return }

        let sz = panel.frame.size
        var origin = NSPoint(x: pt.x, y: pt.y - sz.height / 2)
        for scr in NSScreen.screens where scr.frame.contains(pt) {
            let vis = scr.visibleFrame
            origin.x = max(vis.minX + 4, min(origin.x, vis.maxX - sz.width - 4))
            origin.y = max(vis.minY + 4, min(origin.y, vis.maxY - sz.height - 4))
            break
        }
        panel.setFrameOrigin(origin)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }

        // Auto-hide after 5 seconds of inactivity.
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hideDot()
        }
    }

    private func hideDot() {
        hideTask?.cancel()
        hideTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func buildPanel() {
        let sz: CGFloat = 30
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: sz, height: sz),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = false

        let btn = DotButtonView(frame: NSRect(x: 0, y: 0, width: sz, height: sz))
        btn.onActivate = { [weak self] in
            self?.hideDot()
            self?.onActivate?()
        }
        p.contentView = btn
        panel = p
    }
}

// MARK: - Dot button view

private final class DotButtonView: NSView {
    var onActivate: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }
    override func mouseDown(with event: NSEvent)     { onActivate?() }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let circle = NSBezierPath(ovalIn: r)

        let fillColor = hovered
            ? NSColor(red: 0.48, green: 0.22, blue: 0.92, alpha: 1.0)
            : NSColor(red: 0.38, green: 0.14, blue: 0.78, alpha: 0.98)
        fillColor.setFill()
        circle.fill()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 1.0
        circle.stroke()

        if let symbol = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "PromptPaste"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) {
            let symbolSize = symbol.size
            let symbolRect = NSRect(
                x: floor((bounds.width - symbolSize.width) / 2),
                y: floor((bounds.height - symbolSize.height) / 2),
                width: symbolSize.width,
                height: symbolSize.height)
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}
