import AppKit
import ApplicationServices

/// Floating action indicator: a small non-activating panel that appears near the
/// user's selection and, when clicked, opens the action palette.
///
/// Implements the exact selection detection and positioning architecture used by PopClip:
/// 1. Monitors mouse-up events systemwide via global and local event monitors.
/// 2. Suppresses popup when Command (⌘) modifier key is held during selection.
/// 3. Detects and immediately suppresses for secure/password fields and excluded apps.
/// 4. Discovers selection via focused element and point-hit element fallback.
/// 5. Calculates precise screen bounds via standard Cocoa AX ranges and WebKit/Chromium Text Markers.
/// 6. Dismisses immediately upon keyboard typing (keyDown), scrolling (scrollWheel), or outside clicks.
/// 7. Uses `.nonactivatingPanel` so key focus is never stolen from the active application.
@MainActor
final class SelectionDotController: NSObject {

    static let shared = SelectionDotController()
    private override init() { super.init() }

    private var enabled = false
    private var panel: NSPanel?
    private var debounceTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var onActivate: (() -> Void)?

    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Excluded Apps & System Identifiers (PopClip rules)
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.SystemUIServer",
        "com.1password.1password",
        "com.1password.7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass"
    ]

    // MARK: - Public

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

    // MARK: - Event Monitoring

    private func installMonitors() {
        guard globalMouseUpMonitor == nil else { return }

        // 1. Mouse Up Monitor (Selection Completed)
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            // PopClip Rule: Suppress if Command key is held down during selection
            if event.modifierFlags.contains(.command) {
                Task { @MainActor in self.hideDot() }
                return
            }
            let loc = NSEvent.mouseLocation
            Task { @MainActor in
                self.scheduleCheck(mouseLocation: loc)
            }
        }

        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command) {
                Task { @MainActor in self.hideDot() }
                return event
            }
            let loc = NSEvent.mouseLocation
            Task { @MainActor in
                self.scheduleCheck(mouseLocation: loc)
            }
            return event
        }

        // 2. Dismiss Monitors: Instant dismissal on typing, scrolling, or outside clicks (PopClip standard)
        let dismissMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: dismissMask) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                let mouseLoc = NSEvent.mouseLocation
                if panel.frame.contains(mouseLoc) {
                    return
                }
            }
            Task { @MainActor in self.hideDot() }
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: dismissMask) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                let mouseLoc = NSEvent.mouseLocation
                if panel.frame.contains(mouseLoc) {
                    return event
                }
            }
            Task { @MainActor in self.hideDot() }
            return event
        }

        // 3. Workspace Observers: Dismiss on app switch or deactivate
        let nc = NSWorkspace.shared.notificationCenter
        let obs1 = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hideDot() }
        }
        let obs2 = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hideDot() }
        }
        workspaceObservers = [obs1, obs2]
    }

    private func removeMonitors() {
        if let m = globalMouseUpMonitor {
            NSEvent.removeMonitor(m)
            globalMouseUpMonitor = nil
        }
        if let m = localMouseUpMonitor {
            NSEvent.removeMonitor(m)
            localMouseUpMonitor = nil
        }
        if let m = globalDismissMonitor {
            NSEvent.removeMonitor(m)
            globalDismissMonitor = nil
        }
        if let m = localDismissMonitor {
            NSEvent.removeMonitor(m)
            localDismissMonitor = nil
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
    }

    private func scheduleCheck(mouseLocation: NSPoint) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            // 180 ms debounce gives the target application time to commit the selection range
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self.evaluateCurrentSelection(mouseLocation: mouseLocation)
        }
    }

    // MARK: - Selection Evaluation & Suppression Rules

    private func evaluateCurrentSelection(mouseLocation: NSPoint) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        // Exclusion Rule 1: Excluded system / password manager apps
        if let bundleID = frontApp.bundleIdentifier {
            if Self.excludedBundleIdentifiers.contains(bundleID) {
                hideDot()
                return
            }
            if SettingsStore.shared.explicitCopyAppList.contains(bundleID.lowercased()) {
                hideDot()
                return
            }
        }

        // Element Discovery: Stage 1 - Focused Element
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var element: AXUIElement?
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        }

        if element == nil {
            element = AXElement.focusedElement()
        }

        // Element Discovery: Stage 2 - Element at mouse position (fallback for WebAreas / complex trees)
        var hitElement: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let carbonY = primaryScreenHeight - mouseLocation.y
        _ = AXUIElementCopyElementAtPosition(systemWide, Float(mouseLocation.x), Float(carbonY), &hitElement)

        // Target element candidate list to inspect
        let candidates = [element, hitElement].compactMap { $0 }

        // Exclusion Rule 2: Password / Secure Text Fields (PopClip Security Rule)
        for candidate in candidates {
            if isSecureField(element: candidate) {
                hideDot()
                return
            }
        }

        // Selection Verification across candidates
        var hasSelection = false
        var selectedElement: AXUIElement?

        for candidate in candidates {
            var textRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, kAXSelectedTextAttribute as CFString, &textRef) == .success,
               let str = textRef as? String,
               !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasSelection = true
                selectedElement = candidate
                break
            }

            // WebKit text marker check
            var markerRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                candidate, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
               markerRef != nil {
                hasSelection = true
                selectedElement = candidate
                break
            }
        }

        // Fallback check: Edit > Copy enabled in menu (Chromium/Electron/WebViews with inaccessible text)
        if !hasSelection {
            if AXMenuAction.isCopyEnabled(in: frontApp) {
                hasSelection = true
                selectedElement = element ?? hitElement
            }
        }

        guard hasSelection else {
            hideDot()
            return
        }

        // Calculate Position
        let pos: NSPoint
        if let target = selectedElement, let pt = selectionEndPoint(element: target, primaryScreenHeight: primaryScreenHeight) {
            pos = pt
        } else if let el = element, let pt = selectionEndPoint(element: el, primaryScreenHeight: primaryScreenHeight) {
            pos = pt
        } else {
            pos = NSPoint(x: mouseLocation.x + 14, y: mouseLocation.y + 14)
        }

        showDot(at: pos)
    }

    // MARK: - Security / Password Detection

    private func isSecureField(element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXSecureTextField" {
            return true
        }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == "AXSecureTextField" {
            return true
        }

        return false
    }

    // MARK: - Systemwide Selection Geometry (PopClip Method)

    private func selectionEndPoint(element: AXUIElement, primaryScreenHeight: CGFloat) -> NSPoint? {
        // 1. Cocoa Standard Range Bounds (NSTextView, TextEdit, Pages, Xcode, Notes, Cocoa controls)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeRef, &boundsRef) == .success,
               let boundsRef {
                var rect = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) {
                    if let pt = validateAndConvert(rect: rect, primaryScreenHeight: primaryScreenHeight) {
                        return pt
                    }
                }
            }
        }

        // 2. WebKit / Chromium Text Marker Range Bounds (Safari, Chrome, Arc, Brave, Electron, VS Code, Slack, Discord)
        var markerRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRangeRef) == .success,
           let markerRangeRef {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXBoundsForTextMarkerRange" as CFString,
                markerRangeRef, &boundsRef) == .success,
               let boundsRef {
                var rect = CGRect.zero
                if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) {
                    if let pt = validateAndConvert(rect: rect, primaryScreenHeight: primaryScreenHeight) {
                        return pt
                    }
                }
            }
        }

        return nil
    }

    private func validateAndConvert(rect: CGRect, primaryScreenHeight: CGFloat) -> NSPoint? {
        // BOGUS bounds check: Validate bounds are realistic (not 0, not whole window, not offscreen)
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard rect.height <= 200, rect.width <= 1600 else { return nil }

        // Convert Carbon/AX screen coordinates (origin top-left) to Cocoa screen coordinates (origin bottom-left)
        let cocoaY = primaryScreenHeight - rect.origin.y - rect.height
        return NSPoint(x: rect.maxX + 8, y: cocoaY + rect.height / 2)
    }

    // MARK: - Dot Panel UI & Clamping

    private func showDot(at pt: NSPoint) {
        hideTask?.cancel()
        hideTask = nil
        if panel == nil { buildPanel() }
        guard let panel else { return }

        let sz = panel.frame.size
        var origin = NSPoint(x: pt.x, y: pt.y - sz.height / 2)

        // Find the target screen containing the point and clamp within its visible frame
        for scr in NSScreen.screens where scr.frame.contains(pt) {
            let vis = scr.visibleFrame
            origin.x = max(vis.minX + 6, min(origin.x, vis.maxX - sz.width - 6))
            origin.y = max(vis.minY + 6, min(origin.y, vis.maxY - sz.height - 6))
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

// MARK: - Dot Button View (Polished Apple-Style Floating Bubble)

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

        // Native Dark Glass / PopClip aesthetic
        let fillColor = hovered
            ? NSColor(white: 0.12, alpha: 0.95)
            : NSColor(white: 0.18, alpha: 0.90)
        fillColor.setFill()
        circle.fill()

        // Subtle crisp white rim
        NSColor.white.withAlphaComponent(hovered ? 0.35 : 0.20).setStroke()
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
