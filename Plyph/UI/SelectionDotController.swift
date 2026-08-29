import AppKit
import ApplicationServices

/// Floating action indicator: a small non-activating panel that appears near the
/// user's selection and, when clicked, opens the action palette.
///
/// Uses the same user-facing rules as PopClip without depending on clipboard state:
/// 1. Monitors mouse-up events systemwide via global and local event monitors.
/// 2. Suppresses popup when Command (⌘) modifier key is held during selection.
/// 3. Detects and immediately suppresses for secure/password fields and excluded apps.
/// 4. Discovers selection via focused, point-hit, and ancestor AX elements.
/// 5. Requires a non-empty native range or verified WebKit/Chromium text-marker string.
/// 6. Anchors to the selection endpoint when AX exposes it and otherwise to the
///    mouse-up point that completed the selection.
/// 7. Dismisses immediately upon keyboard typing (keyDown), scrolling (scrollWheel), or outside clicks.
/// 8. Uses `.nonactivatingPanel` so key focus is never stolen from the active application.
@MainActor
final class SelectionDotController: NSObject {

    static let shared = SelectionDotController()
    private override init() { super.init() }

    private var enabled = false
    private var panel: NSPanel?
    private var debounceTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var onActivate: (() -> Void)?
    private var mouseDownLocation: NSPoint?

    private var globalMouseUpMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    // Apps where automatic selection UI is unsafe regardless of user settings.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.systemuiserver",
        "com.1password.1password",
        "com.1password.7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.lastpass.lastpass"
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
            let clickCount = event.clickCount
            Task { @MainActor in
                let dragged = self.mouseDownLocation.map {
                    self.distanceSquared(from: $0, to: loc) >= 9
                } ?? false
                self.mouseDownLocation = nil
                self.scheduleCheck(
                    mouseLocation: loc,
                    selectionGesture: dragged || clickCount >= 2)
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
            let clickCount = event.clickCount
            Task { @MainActor in
                let dragged = self.mouseDownLocation.map {
                    self.distanceSquared(from: $0, to: loc) >= 9
                } ?? false
                self.mouseDownLocation = nil
                self.scheduleCheck(
                    mouseLocation: loc,
                    selectionGesture: dragged || clickCount >= 2)
            }
            return event
        }

        // 2. Dismiss Monitors: Instant dismissal on typing, scrolling, or outside clicks (PopClip standard)
        let dismissMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: dismissMask) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown {
                let location = NSEvent.mouseLocation
                Task { @MainActor in self.mouseDownLocation = location }
            }
            guard let panel = self.panel, panel.isVisible else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                let mouseLoc = NSEvent.mouseLocation
                if panel.frame.contains(mouseLoc) {
                    return
                }
            }
            Task { @MainActor in self.hideDot() }
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: dismissMask) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                let location = NSEvent.mouseLocation
                Task { @MainActor in self.mouseDownLocation = location }
            }
            guard let panel = self.panel, panel.isVisible else { return event }
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

    private func scheduleCheck(mouseLocation: NSPoint, selectionGesture: Bool) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            // 180 ms debounce gives the target application time to commit the selection range
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self.evaluateCurrentSelection(
                mouseLocation: mouseLocation,
                selectionGesture: selectionGesture)
        }
    }

    // MARK: - Selection Evaluation & Suppression Rules

    private func evaluateCurrentSelection(
        mouseLocation: NSPoint,
        selectionGesture: Bool
    ) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        // Exclusion Rule 1: Excluded system / password manager apps
        if let bundleID = frontApp.bundleIdentifier {
            if Self.protectedBundleIdentifiers.contains(bundleID.lowercased()) {
                hideDot()
                return
            }
            if SettingsStore.shared.isAppExcluded(bundleIdentifier: bundleID) {
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
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        let axY = mainDisplayHeight - mouseLocation.y
        _ = AXUIElementCopyElementAtPosition(
            systemWide, Float(mouseLocation.x), Float(axY), &hitElement)

        // Web content commonly exposes the selection on an ancestor WebArea
        // rather than the leaf returned by hit-testing.
        let candidates = selectionCandidates(focused: element, hit: hitElement)

        // Exclusion Rule 2: Password / Secure Text Fields (PopClip Security Rule)
        for candidate in candidates {
            if isSecureField(element: candidate) {
                hideDot()
                return
            }
        }

        // Selection Verification across candidates
        var selectedElement: AXUIElement?

        for candidate in candidates {
            if hasNonEmptySelection(in: candidate) {
                selectedElement = candidate
                break
            }
        }

        guard let selectedElement else {
            hideDot()
            return
        }

        // A selection may stay active while the user clicks a toolbar, image,
        // or other control. Do not resurrect the button for that stale range.
        // A nearby AX range proves that this mouse-up belongs to the selection;
        // drag and multi-click gestures cover apps that expose text but no bounds.
        let proximity = selectionProximity(
            to: mouseLocation,
            in: selectedElement,
            mainDisplayHeight: mainDisplayHeight)
        guard proximity == true || (proximity == nil && selectionGesture) else {
            hideDot()
            return
        }

        let anchor = selectionAnchor(
            element: selectedElement,
            mainDisplayHeight: mainDisplayHeight,
            mouseLocation: mouseLocation) ?? mouseLocation
        showDot(near: anchor, on: screen(containing: mouseLocation))
    }

    private func selectionCandidates(
        focused: AXUIElement?, hit: AXUIElement?
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []

        for root in [focused, hit].compactMap({ $0 }) {
            var current: AXUIElement? = root
            var depth = 0
            while let candidate = current, depth < 8 {
                if !result.contains(where: { CFEqual($0, candidate) }) {
                    result.append(candidate)
                }

                var parentRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    candidate, kAXParentAttribute as CFString, &parentRef) == .success,
                   let parentRef {
                    current = unsafeBitCast(parentRef, to: AXUIElement.self)
                } else {
                    current = nil
                }
                depth += 1
            }
        }
        return result
    }

    private func hasNonEmptySelection(in element: AXUIElement) -> Bool {
        var textRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
           let text = textRef as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           let range = cfRange(from: rangeRef), range.length > 0 {
            return true
        }

        // A text-marker range object can represent only a caret. Asking the AX
        // provider for the range's string distinguishes that from real selected
        // text and avoids the old random-popup false positive.
        var markerRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
              let markerRef else { return false }

        var markerTextRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString,
            markerRef, &markerTextRef) == .success,
           let text = markerTextRef as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var attributedRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element, "AXAttributedStringForTextMarkerRange" as CFString,
            markerRef, &attributedRef) == .success,
           let text = attributedRef as? NSAttributedString {
            return !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
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

    // MARK: - Systemwide Selection Geometry

    /// Returns nil when the application exposes selected text but no selection
    /// geometry. That is different from false, which means AX gave us bounds
    /// and they prove the click occurred elsewhere.
    private func selectionProximity(
        to point: NSPoint,
        in element: AXUIElement,
        mainDisplayHeight: CGFloat
    ) -> Bool? {
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           let rect = boundsForAXValue(
                rangeRef,
                parameterizedAttribute: kAXBoundsForRangeParameterizedAttribute as CFString,
                in: element,
                mainDisplayHeight: mainDisplayHeight) {
            return rect.insetBy(dx: -60, dy: -45).contains(point)
        }

        var markerRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
           let markerRef,
           let rect = boundsForAXValue(
                markerRef,
                parameterizedAttribute: "AXBoundsForTextMarkerRange" as CFString,
                in: element,
                mainDisplayHeight: mainDisplayHeight) {
            return rect.insetBy(dx: -60, dy: -45).contains(point)
        }
        return nil
    }

    private func boundsForAXValue(
        _ value: CFTypeRef,
        parameterizedAttribute: CFString,
        in element: AXUIElement,
        mainDisplayHeight: CGFloat
    ) -> CGRect? {
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, parameterizedAttribute, value, &boundsRef) == .success,
              let boundsRef, let axRect = cgRect(from: boundsRef),
              axRect.width > 0, axRect.height > 0 else { return nil }
        return appKitRect(from: axRect, mainDisplayHeight: mainDisplayHeight)
    }

    private func selectionAnchor(
        element: AXUIElement,
        mainDisplayHeight: CGFloat,
        mouseLocation: NSPoint
    ) -> NSPoint? {
        // Native Cocoa: ask for the first and last selected glyph rather than
        // the union of a multi-line selection. Pick the endpoint nearest the
        // mouse-up position so reverse selections are handled correctly.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           let selectedRange = cfRange(from: rangeRef), selectedRange.length > 0 {
            let first = CFRange(location: selectedRange.location, length: 1)
            let last = CFRange(
                location: selectedRange.location + selectedRange.length - 1,
                length: 1)
            let rects = [first, last].compactMap {
                boundsForRange($0, in: element, mainDisplayHeight: mainDisplayHeight)
            }
            if let closest = rects.min(by: {
                distanceSquared(from: $0.center, to: mouseLocation)
                    < distanceSquared(from: $1.center, to: mouseLocation)
            }) {
                return closest.center
            }
        }

        // WebKit/Chromium usually return the union of every selected line.
        // Use it only when it describes a compact selection near the release
        // point; for multi-line/container bounds the mouse-up point is the
        // reliable active endpoint.
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
                if let axRect = cgRect(from: boundsRef) {
                    let rect = appKitRect(from: axRect, mainDisplayHeight: mainDisplayHeight)
                    let compact = rect.width > 0 && rect.height > 0
                        && rect.width <= 320 && rect.height <= 80
                    let closeToRelease = rect.insetBy(dx: -50, dy: -40).contains(mouseLocation)
                    if compact && closeToRelease {
                        return NSPoint(
                            x: min(max(mouseLocation.x, rect.minX), rect.maxX),
                            y: min(max(mouseLocation.y, rect.minY), rect.maxY))
                    }
                }
            }
        }

        return nil
    }

    private func boundsForRange(
        _ range: CFRange,
        in element: AXUIElement,
        mainDisplayHeight: CGFloat
    ) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue, &boundsRef) == .success,
              let boundsRef, let axRect = cgRect(from: boundsRef),
              axRect.width > 0, axRect.height > 0, axRect.height < 200 else { return nil }
        return appKitRect(from: axRect, mainDisplayHeight: mainDisplayHeight)
    }

    private func cfRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func cgRect(from value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func appKitRect(from rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    private func distanceSquared(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return exact
        }
        return NSScreen.screens.min {
            distanceSquared(from: $0.frame.center, to: point)
                < distanceSquared(from: $1.frame.center, to: point)
        }
    }

    // MARK: - Dot Panel UI & Clamping

    private func showDot(near anchor: NSPoint, on screen: NSScreen?) {
        hideTask?.cancel()
        hideTask = nil
        if panel == nil { buildPanel() }
        guard let panel else { return }

        let sz = panel.frame.size
        let gap: CGFloat = 8
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.x - sz.width / 2, y: anchor.y + gap)

        // PopClip-style placement prefers above the active selection endpoint,
        // then flips below when the menu bar or screen edge leaves no room.
        if origin.y + sz.height > visible.maxY - 6 {
            origin.y = anchor.y - gap - sz.height
        }
        origin.x = max(visible.minX + 6, min(origin.x, visible.maxX - sz.width - 6))
        origin.y = max(visible.minY + 6, min(origin.y, visible.maxY - sz.height - 6))
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
            ? NSColor(white: 0.08, alpha: 0.98)
            : NSColor(white: 0.02, alpha: 0.95)
        fillColor.setFill()
        circle.fill()

        // Subtle crisp white rim
        NSColor.white.withAlphaComponent(hovered ? 0.35 : 0.20).setStroke()
        circle.lineWidth = 1.0
        circle.stroke()

        // Draw the white Plyph logo icon
        if let logo = NSImage(named: "SelectionDotIcon") ?? NSImage(named: "MenuBarIcon") {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(
                x: floor((bounds.width - iconSize) / 2),
                y: floor((bounds.height - iconSize) / 2),
                width: iconSize,
                height: iconSize)
            logo.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
