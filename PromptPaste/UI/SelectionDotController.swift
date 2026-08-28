import AppKit
import ApplicationServices

/// Optional floating action indicator: a small non-activating panel that
/// appears near the user's selection and, when clicked, opens the action
/// palette — similar to the PromptPaste Chrome extension's selection bubble.
///
/// ## Implementation approach
/// macOS provides no public API equivalent to iOS's UIMenuController for
/// arbitrary third-party apps. The closest reliable system-wide mechanism is
/// combining:
///
/// 1. `AXObserver` watching `kAXFocusedUIElementChangedNotification` on the
///    system-wide AX element to detect app focus changes.
/// 2. `kAXSelectedTextChangedNotification` on the focused element's app to
///    detect text selection changes.
/// 3. `kAXBoundsForRangeParameterizedAttribute` to locate the selection end.
///    When unsupported (e.g. WKWebView content), the dot falls back to a
///    position near the current mouse cursor — a documented AX limitation.
///
/// ## Focus steal prevention
/// The panel uses `.nonactivatingPanel` so it never steals key focus.
///
/// ## Performance
/// A 300 ms debounce prevents the observer from firing on every keystroke.
/// The observer is torn down when the feature is disabled.
@MainActor
final class SelectionDotController: NSObject {

    // MARK: Singleton

    static let shared = SelectionDotController()
    private override init() { super.init() }

    // MARK: State

    private var enabled = false
    private var panel: NSPanel?
    private var debounceTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var onActivate: (() -> Void)?
    private var axObserver: AXObserver?
    private var observedPid: pid_t = 0

    // MARK: Public interface

    func start(onActivate: @escaping () -> Void) {
        guard !enabled else { return }
        enabled = true
        self.onActivate = onActivate
        installGlobalFocusObserver()
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        removeObserver()
        hideDot()
    }

    // MARK: AX observer

    private func installGlobalFocusObserver() {
        let myPid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var obs: AXObserver?
        guard AXObserverCreate(myPid, dotAXCallback, &obs) == .success,
              let obs else { return }
        axObserver = obs
        let sysWide = AXUIElementCreateSystemWide()
        AXObserverAddNotification(obs, sysWide,
            kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs), CFRunLoopMode.defaultMode)
    }

    private func removeObserver() {
        guard let obs = axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs), CFRunLoopMode.defaultMode)
        axObserver = nil
        observedPid = 0
    }

    // MARK: Notification handling (called from C callback on main queue)

    func handleFocusChanged(to element: AXUIElement) {
        guard enabled else { return }

        if observedPid != 0, let obs = axObserver {
            let prev = AXUIElementCreateApplication(observedPid)
            AXObserverRemoveNotification(obs, prev,
                kAXSelectedTextChangedNotification as CFString)
        }

        var newPid: pid_t = 0
        AXUIElementGetPid(element, &newPid)

        let myPid = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard newPid != 0 && newPid != myPid else {
            observedPid = 0
            hideDot()
            return
        }

        observedPid = newPid
        if let obs = axObserver {
            let appEl = AXUIElementCreateApplication(newPid)
            AXObserverAddNotification(obs, appEl,
                kAXSelectedTextChangedNotification as CFString,
                Unmanaged.passUnretained(self).toOpaque())
        }
        hideDot()
    }

    func handleSelectionChanged(on element: AXUIElement) {
        guard enabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self.evaluateSelection(element: element)
        }
    }

    // MARK: Evaluation

    private func evaluateSelection(element: AXUIElement) async {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &ref) == .success,
              let selected = ref as? String, selected.count >= 3
        else { hideDot(); return }

        let pos = selectionEndPoint(element: element) ?? nearMouse()
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

    // MARK: Panel

    private func showDot(at pt: NSPoint) {
        hideTask?.cancel(); hideTask = nil
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
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hideDot()
        }
    }

    private func hideDot() {
        hideTask?.cancel(); hideTask = nil
        debounceTask?.cancel(); debounceTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in panel?.orderOut(nil) }
    }

    private func buildPanel() {
        let sz: CGFloat = 28
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
        btn.onActivate = { [weak self] in self?.hideDot(); self?.onActivate?() }
        p.contentView = btn
        panel = p
    }
}

// MARK: - C-level AX callback

private let dotAXCallback: AXObserverCallback = { _, element, notification, userData in
    guard let userData else { return }
    let ctrl = Unmanaged<SelectionDotController>
        .fromOpaque(userData).takeUnretainedValue()
    let notifStr = notification as String
    let elem = element
    DispatchQueue.main.async {
        Task { @MainActor in
            if notifStr == kAXFocusedUIElementChangedNotification {
                ctrl.handleFocusChanged(to: elem)
            } else if notifStr == kAXSelectedTextChangedNotification {
                ctrl.handleSelectionChanged(on: elem)
            }
        }
    }
}

// MARK: - Dot button view

private final class DotButtonView: NSView {
    var onActivate: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
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
            ? NSColor(red: 0.46, green: 0.20, blue: 0.88, alpha: 1.0)
            : NSColor(red: 0.36, green: 0.13, blue: 0.74, alpha: 0.96)
        fillColor.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        drawFlameMark(in: r.insetBy(dx: r.width * 0.20, dy: r.height * 0.20),
                      fill: fillColor)
    }

    private func drawFlameMark(in box: NSRect, fill fillColor: NSColor) {
        // Maps SVG canvas coords (tight bbox: x∈[220,804], y∈[156,800]) into box.
        func p(_ sx: CGFloat, _ sy: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + (sx - 220) / 584 * box.width,
                    y: box.minY + (1 - (sy - 156) / 644) * box.height)
        }
        let path = NSBezierPath()
        path.move(to: p(512, 156))
        path.curve(to: p(401, 455), controlPoint1: p(496, 257), controlPoint2: p(458, 365))
        path.curve(to: p(220, 660), controlPoint1: p(349, 537), controlPoint2: p(286, 607))
        path.curve(to: p(419, 675), controlPoint1: p(302, 636), controlPoint2: p(368, 637))
        path.curve(to: p(512, 800), controlPoint1: p(465, 709), controlPoint2: p(493, 755))
        path.curve(to: p(605, 675), controlPoint1: p(531, 755), controlPoint2: p(559, 709))
        path.curve(to: p(804, 660), controlPoint1: p(656, 637), controlPoint2: p(722, 636))
        path.curve(to: p(623, 455), controlPoint1: p(738, 607), controlPoint2: p(675, 537))
        path.curve(to: p(512, 156), controlPoint1: p(566, 365), controlPoint2: p(528, 257))
        path.close()
        path.move(to: p(512, 405))
        path.curve(to: p(424, 487), controlPoint1: p(461, 405), controlPoint2: p(424, 439))
        path.curve(to: p(468, 650), controlPoint1: p(424, 539), controlPoint2: p(444, 594))
        path.curve(to: p(512, 800), controlPoint1: p(490, 702), controlPoint2: p(505, 751))
        path.curve(to: p(511, 678), controlPoint1: p(509, 757), controlPoint2: p(507, 714))
        path.curve(to: p(559, 586), controlPoint1: p(516, 635), controlPoint2: p(532, 612))
        path.curve(to: p(600, 488), controlPoint1: p(589, 557), controlPoint2: p(600, 527))
        path.curve(to: p(512, 405), controlPoint1: p(600, 440), controlPoint2: p(563, 405))
        path.close()
        path.windingRule = .evenOdd
        NSColor.white.setFill()
        path.fill()
        // Centre dot
        let cr = 37.0 / 584.0 * box.width
        let cc = p(512, 493)
        let dot = NSBezierPath(ovalIn: NSRect(x: cc.x - cr, y: cc.y - cr,
                                              width: cr * 2, height: cr * 2))
        fillColor.setFill()
        dot.fill()
    }
}
