import AppKit

/// The floating action palette: a lightweight, non-activating panel with
/// keyboard navigation (Up/Down/Enter/Escape), positioned at the screen center
/// or near the pointer depending on the `action-palette-position` setting.
@MainActor
final class ActionPaletteController: NSObject {
    static let shared = ActionPaletteController()

    private var panel: ActionPalettePanel?
    private var table: NSTableView?
    private var items: [PaletteItem] = []
    private var selectedRow = 0
    private var modeHandler: ((RunMode) -> Void)?
    private var eventMonitor: Any?

    struct PaletteItem {
        let name: String
        let icon: NSImage?
        let mode: RunMode
        let isSeparator: Bool
    }

    override private init() {
        super.init()
    }

    var isOpen: Bool { panel != nil }

    func show(modeHandler: @escaping (RunMode) -> Void) {
        guard panel == nil else { return }
        self.modeHandler = modeHandler
        buildItems()
        buildPanel()
        positionPanel()
        selectedRow = 0
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table?.scrollRowToVisible(0)
        panel?.makeKeyAndOrderFront(nil)
        
        // Start global monitor to capture clicks outside and keyboard navigation 
        // since our panel is strictly non-key to preserve Safari's selection.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                // If clicked outside the panel, close it.
                if let panel = self.panel, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                    self.close()
                }
            } else if event.type == .keyDown {
                self.handleKey(event)
            }
        }
    }

    func close() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Items (built-ins, separator, enabled custom actions)

    private func buildItems() {
        let settings = SettingsStore.shared
        items = [
            PaletteItem(
                name: "Correct selected text", icon: image("text.badge.checkmark"),
                mode: .correct, isSeparator: false),
            PaletteItem(
                name: "Rewrite selected text", icon: image("square.and.pencil"),
                mode: .rewrite, isSeparator: false),
            PaletteItem(
                name: "Run selected prompt", icon: image("gearshape"),
                mode: .prompt, isSeparator: false),
        ]
        let actions = settings.enabledCustomActions
        for action in actions {
            items.append(
                PaletteItem(
                    name: action.name, icon: image("gearshape"),
                    mode: .custom(action), isSeparator: false))
        }
        if !actions.isEmpty {
            items.insert(
                PaletteItem(name: "", icon: nil, mode: .correct, isSeparator: true),
                at: 3)
        }
    }

    private func image(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    // MARK: Panel construction

    private func buildPanel() {
        let panel = ActionPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) }

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        // Header
        let title = NSTextField(labelWithString: "PromptPaste")
        title.font = .boldSystemFont(ofSize: 14)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.image = NSImage(
            systemSymbolName: "xmark.circle", accessibilityDescription: "Close palette")
        close.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .fullWidth
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        self.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(close)
        effect.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            title.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            close.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])

        let listHeight = items.reduce(0) { total, item in
            total + (item.isSeparator ? 12 : 40)
        }
        let maxHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 800) * 0.6
        let height: CGFloat = min(CGFloat(listHeight + 56), maxHeight)
        panel.setContentSize(NSSize(width: 380, height: max(120, height)))
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        if SettingsStore.shared.actionPalettePosition == "monitor-center" {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        } else {
            var x = mouse.x + 8
            var y = mouse.y - panel.frame.height - 8
            x = min(max(x, screen.visibleFrame.minX),
                    screen.visibleFrame.maxX - panel.frame.width)
            y = min(max(y, screen.visibleFrame.minY),
                    screen.visibleFrame.maxY - panel.frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: Interaction

    func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 126:  // Up
            moveSelection(-1)
        case 125:  // Down
            moveSelection(1)
        case 36, 76:  // Return / keypad Enter
            activateSelection()
        case 53:  // Escape
            close()
        default:
            break
        }
    }

    private func moveSelection(_ offset: Int) {
        guard let table else { return }
        let rows = items.enumerated().filter { !$0.element.isSeparator }.map(\.offset)
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(of: selectedRow) ?? 0
        let nextIndex = (currentIndex + offset + rows.count) % rows.count
        selectedRow = rows[nextIndex]
        table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        table.scrollRowToVisible(selectedRow)
    }

    private func activateSelection() {
        guard selectedRow < items.count else { return }
        let item = items[selectedRow]
        close()
        modeHandler?(item.mode)
    }

    @objc private func closeClicked() {
        close()
    }

    @objc private func rowClicked() {
        let clicked = table?.clickedRow ?? -1
        guard clicked >= 0 else { return }
        selectedRow = clicked
        activateSelection()
    }
}

// MARK: - Table data

extension ActionPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].isSeparator ? 12 : 40
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let item = items[row]
        if item.isSeparator {
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 10
        container.alignment = .centerY
        container.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        if let icon = item.icon {
            let imageView = NSImageView(image: icon)
            imageView.contentTintColor = .secondaryLabelColor
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
            container.addArrangedSubview(imageView)
        }
        let label = NSTextField(labelWithString: item.name)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        container.addArrangedSubview(label)
        return container
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !items[row].isSeparator
    }
}

// MARK: - Panel delegate (close when the palette loses key focus or on click outside)

extension ActionPaletteController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Since we are no longer key, this won't fire for our panel, but we handle closing via global monitor.
    }
}

// MARK: - Panel subclass

/// NSPanel subclass that strictly prevents becoming key. This is crucial for Safari
/// and Chromium web editors: if the palette becomes key, the browser's DOM loses
/// focus and clears its active selection, breaking text replacement.
final class ActionPalettePanel: NSPanel {
    var keyHandler: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
