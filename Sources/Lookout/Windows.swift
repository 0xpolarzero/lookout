import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class UIState {
    var isOpen = false
    var tab: PanelTab = .inbox
    var filter: InboxFilter = .needsYou {
        didSet { selection = nil }
    }
    /// Inbox row that keyboard shortcuts act on: the hovered row, or the one picked with ↑↓.
    var selection: String?
    /// Same, in the Agents tab.
    var agentSelection: String?
    /// Pill drawer: open while the strip or the drawer is hovered, or from the keyboard (the switcher).
    var drawerOpen = false
    var switcher = false
    /// Drawer row the switcher keys act on (also follows the mouse).
    var drawerSelection: String?
    /// What you've typed in the switcher: it then lists every matching session.
    var switcherQuery = ""
    /// Where the strip's tiles are in the pill window (top-left origin), and the pill's size: the drawer is its own
    /// window and lines its rows up with these.
    var tileFrames: [String: CGRect] = [:]
    var pillSize: CGSize = .zero
    var edge: DockEdge = DockEdge(rawValue: UserDefaults.standard.string(forKey: "pill.edge") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "pill.onLeft") ? .left : .right) {
        didSet { if persists { UserDefaults.standard.set(edge.rawValue, forKey: "pill.edge") } }
    }
    /// Position of the pill along its edge, as a fraction of that edge's length.
    var position: Double = UserDefaults.standard.object(forKey: "pill.y") as? Double ?? 0.5 {
        didSet { if persists { UserDefaults.standard.set(position, forKey: "pill.y") } }
    }
    /// Off for screenshots, so rendering never moves the real pill.
    @ObservationIgnored var persists = true

    init() {}

    init(persists: Bool, edge: DockEdge) {
        self.persists = persists
        self.edge = edge
    }
}

enum DockEdge: String {
    case left, right, top, bottom

    var isHorizontal: Bool { self == .top || self == .bottom }
}

class FloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // Lookout is an accessory app, inactive most of the time: without this, `.help` tooltips never show.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Reports SwiftUI content size changes so the borderless window can hug its content.
final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?
    private var last: NSSize = .zero

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    func check() {
        let size = fittingSize
        guard size != last else { return }
        last = size
        onSizeChange?(size)
    }
}

struct PillActions {
    let toggle: (PanelTab) -> Void
    var hoverAgents: (Bool) -> Void = { _ in }
}

/// The whole pill is draggable. A mouse-down is held back until we know whether it's a click (forwarded to
/// SwiftUI on mouse-up) or a drag (moves the window; SwiftUI never sees it, so no button fires).
final class PillPanel: FloatingPanel {
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    /// Where a drag may start (window coordinates); clicks elsewhere go straight through.
    var canDrag: (NSPoint) -> Bool = { _ in true }
    private var pendingDown: NSEvent?
    private var downAt: NSPoint = .zero
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        // Screen coordinates from the event itself (stable even though the window moves under the cursor).
        let p = convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDown where !canDrag(event.locationInWindow):
            pendingDown = nil
            dragging = false
            super.sendEvent(event)
        case .leftMouseDown:
            pendingDown = event
            downAt = p
            dragging = false
        case .leftMouseDragged where pendingDown != nil || dragging:
            if !dragging, hypot(p.x - downAt.x, p.y - downAt.y) > 3 {
                dragging = true
                NSCursor.closedHand.push()
                onDragChanged?(downAt)
            }
            if dragging { onDragChanged?(p) }
        case .leftMouseUp where dragging:
            dragging = false
            pendingDown = nil
            NSCursor.pop()
            onDragEnded?(p)
        case .leftMouseUp:
            if let down = pendingDown {
                pendingDown = nil
                super.sendEvent(down)
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
final class UIController {
    let store: Store
    let ui = UIState()
    static let panelPadding: CGFloat = 0
    static let panelContent = NSSize(width: 400, height: 600)

    private var pill: FloatingPanel!
    private var panel: FloatingPanel!
    private var drawer: FloatingPanel!
    private var drawerHost: SizingHostingView<AgentDrawer>!
    private var pillHost: SizingHostingView<PillView>!
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var snapping = false
    /// App that had focus before the panel opened; it gets focus back when the panel closes.
    private var previousApp: NSRunningApplication?
    private var monitor: Any?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    init(store: Store) {
        self.store = store
        let actions = PillActions(
            toggle: { [weak self] tab in self?.toggle(tab) },
            hoverAgents: { [weak self] inside in self?.hoverAgents(inside) })

        let pillPanel = PillPanel(size: NSSize(width: 60, height: 200))
        pillPanel.onDragChanged = { [weak self] point in self?.dragChanged(to: point) }
        pillPanel.onDragEnded = { [weak self] point in self?.dragEnded(at: point) }
        pill = pillPanel
        pillHost = SizingHostingView(rootView: PillView(store: store, ui: ui, actions: actions))
        pillHost.onSizeChange = { [weak self] _ in self?.layoutPill() }
        pill.contentView = pillHost
        layoutPill()
        pill.orderFrontRegardless()
        observeCentering()

        let pad = Self.panelPadding * 2
        panel = FloatingPanel(size: NSSize(width: Self.panelContent.width + pad, height: Self.panelContent.height + pad))
        panel.allowsKey = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: PanelView(store: store, ui: ui, close: { [weak self] in self?.hidePanel() }))
        panel.onCancel = { [weak self] in self?.hidePanel() }

        drawer = FloatingPanel(size: NSSize(width: AgentDrawer.width, height: 200))
        drawerHost = SizingHostingView(rootView: AgentDrawer(
            store: store, ui: ui, showAgents: { [weak self] in self?.toggle(.agents) },
            onHover: { [weak self] inside in self?.hoverDrawer(inside) }))
        drawerHost.onSizeChange = { [weak self] _ in self?.positionDrawer() }
        drawer.contentView = drawerHost
        observeDrawer()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
                self?.closeSwitcher(refocus: false)
            }
        }
        // A click outside the field being edited ends the editing (SwiftUI only does that for other fields), which
        // closes search suggestions the way you'd expect.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                if event.window === self.panel, let field = self.editedField(), let superview = field.superview,
                   !superview.convert(field.frame, to: nil).contains(event.locationInWindow) {
                    self.panel.makeFirstResponder(nil)
                }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !NSScreen.screens.contains(self.screen) { self.screen = NSScreen.main ?? NSScreen.screens[0] }
                self.layoutPill()
            }
        }
    }

    // MARK: Pill

    private func pillTarget() -> NSRect {
        let size = pillHost.fittingSize
        let vf = screen.visibleFrame
        let inset: CGFloat = 2
        let position = store.settings.centerPill == true ? 0.5 : ui.position
        let alongX = min(max(vf.minX + vf.width * position - size.width / 2, vf.minX), vf.maxX - size.width)
        let alongY = min(max(vf.minY + vf.height * position - size.height / 2, vf.minY), vf.maxY - size.height)
        let origin = switch ui.edge {
        case .left: NSPoint(x: vf.minX + inset, y: alongY)
        case .right: NSPoint(x: vf.maxX - size.width - inset, y: alongY)
        case .top: NSPoint(x: alongX, y: vf.maxY - size.height - inset)
        case .bottom: NSPoint(x: alongX, y: vf.minY + inset)
        }
        return NSRect(origin: origin, size: size)
    }

    func layoutPill() {
        guard dragStart == nil, !snapping else { return }
        pill.setFrame(pillTarget(), display: true)
        if ui.isOpen { positionPanel() }
        if drawer?.isVisible == true { positionDrawer() }
    }

    /// Moves the pill to (or back from) the middle of its edge when the setting changes.
    private func observeCentering() {
        withObservationTracking {
            _ = store.settings.centerPill
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.animatePill(to: self.pillTarget())
                self.observeCentering()
            }
        }
    }

    private func animatePill(to target: NSRect, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.pill.animator().setFrame(target, display: true)
        }, completionHandler: {
            Task { @MainActor in
                if let done { done() } else { self.layoutPill() }
            }
        })
    }

    private func dragChanged(to mouse: NSPoint) {
        if dragStart == nil {
            dragStart = (mouse, pill.frame.origin)
            hidePanel()
            closeSwitcher(refocus: false)
            ui.drawerOpen = false
        }
        guard let start = dragStart else { return }
        pill.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded(at mouse: NSPoint) {
        dragStart = nil
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screen
        let vf = screen.visibleFrame
        (ui.edge, ui.position) = Self.snap(pill.frame, in: vf)
        // Let SwiftUI re-lay out the pill (it may have rotated) before measuring the target frame.
        snapping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.animatePill(to: self.pillTarget()) {
                self.snapping = false
                self.layoutPill()
            }
        }
    }

    /// Closest screen edge to the dropped pill, and where along that edge it sits (0…1).
    nonisolated static func snap(_ f: NSRect, in vf: NSRect) -> (DockEdge, Double) {
        let distances: [(DockEdge, CGFloat)] = [
            (.left, f.midX - vf.minX), (.right, vf.maxX - f.midX), (.top, vf.maxY - f.midY), (.bottom, f.midY - vf.minY),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        let position = edge.isHorizontal
            ? min(max((f.midX - vf.minX) / vf.width, 0.03), 0.97)
            : min(max((f.midY - vf.minY) / vf.height, 0.05), 0.95)
        return (edge, position)
    }

    // MARK: Keyboard

    /// Panel shortcuts. Returns nil when the key was handled. Typing in a text field is never intercepted.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if ui.switcher, drawer.isKeyWindow { return handleSwitcherKey(event) }
        guard ui.isOpen, panel.isKeyWindow, !store.isRecordingShortcut else { return event }
        if event.keyCode == 53, event.modifierFlags.intersection(Shortcut.relevant).isEmpty {
            // Esc leaves a search field first (closing its suggestions); the next one closes the panel.
            if editedField() != nil {
                panel.makeFirstResponder(nil)
            } else {
                hidePanel()
            }
            return nil
        }
        if panel.firstResponder is NSText { return event }
        let pressed = Shortcut(event)
        if pressed == store.shortcut(.refresh) {
            store.refreshNow()
            return nil
        }
        if ui.tab == .agents { return handleAgentsKey(event, pressed) }
        guard ui.tab == .inbox else { return event }
        let list = store.list(ui.filter)
        let current = list.first { $0.id == ui.selection }
        switch event.keyCode {
        case 125: moveSelection(1, in: list); return nil
        case 126: moveSelection(-1, in: list); return nil
        default: break
        }
        if pressed == store.shortcut(.markAllRead) {
            store.markAllRead(ui.filter)
        } else if let item = current, pressed == store.shortcut(.openItem) {
            store.open(item)
        } else if let item = current, pressed == store.shortcut(.toggleRead) {
            item.state == .unread ? store.markRead(item) : store.markUnread(item)
        } else if let item = current, pressed == store.shortcut(.discard) {
            moveSelection(1, in: list)
            item.state.isOpen ? store.discard(item) : store.restore(item)
        } else {
            return event
        }
        return nil
    }

    /// The text field being edited in the panel, if any (its field editor is the first responder).
    private func editedField() -> NSView? {
        guard let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return editor.delegate as? NSView
    }

    private func moveSelection(_ delta: Int, in list: [InboxItem]) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == ui.selection } ?? (delta > 0 ? -1 : list.count)
        ui.selection = list[min(max(index + delta, 0), list.count - 1)].id
    }

    // MARK: Agents strip

    private var drawerClose: DispatchWorkItem?
    private var stripHovered = false
    private var drawerHovered = false

    private func hoverAgents(_ inside: Bool) {
        stripHovered = inside
        hoverChanged()
    }

    private func hoverDrawer(_ inside: Bool) {
        drawerHovered = inside
        hoverChanged()
    }

    /// The drawer opens with the pointer over the strip and closes a moment after it has left both windows.
    private func hoverChanged() {
        drawerClose?.cancel()
        guard !ui.switcher else { return }
        if stripHovered || drawerHovered {
            ui.drawerOpen = true
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.ui.switcher, !self.stripHovered, !self.drawerHovered else { return }
                self.ui.drawerOpen = false
                self.ui.drawerSelection = nil
            }
            drawerClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Shows, moves or hides the drawer window whenever what it depends on changes.
    private func observeDrawer() {
        withObservationTracking {
            syncDrawer()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeDrawer() }
        }
    }

    private func syncDrawer() {
        let visible = store.agents.enabled && (store.agents.expanded || ui.switcher) && ui.drawerOpen && !ui.isOpen
            && dragStart == nil
        _ = ui.edge
        if visible {
            positionDrawer()
            if !drawer.isVisible { drawer.orderFrontRegardless() }
        } else if drawer.isVisible {
            drawer.orderOut(nil)
            drawerHovered = false
        }
    }

    /// Beside a vertical pill, exactly as tall as it (rows line up with tiles); under or over a horizontal one.
    private func positionDrawer() {
        guard let drawer, let drawerHost else { return }
        let size = drawerHost.fittingSize
        let pf = pill.frame
        let vf = screen.visibleFrame
        let gap: CGFloat = 6
        let x = min(max(pf.midX - size.width / 2, vf.minX + 4), vf.maxX - size.width - 4)
        let origin = switch ui.edge {
        case .right: NSPoint(x: pf.minX - gap - size.width, y: pf.maxY - size.height)
        case .left: NSPoint(x: pf.maxX + gap, y: pf.maxY - size.height)
        case .top: NSPoint(x: x, y: pf.minY - gap - size.height)
        case .bottom: NSPoint(x: x, y: pf.maxY + gap)
        }
        drawer.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func agentsChanged() {
        if !store.agents.enabled {
            closeSwitcher(refocus: true)
            if ui.tab == .agents { ui.tab = .inbox }
        }
        layoutPill()
    }

    /// The keyboard way in: expands the strip, opens the drawer and takes focus until a pick or Esc.
    func showSwitcher() {
        guard store.agents.enabled else { return }
        if ui.switcher {
            closeSwitcher(refocus: true)
            return
        }
        hidePanel()
        store.refreshClaude()
        let rows = store.allAgentRows
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        ui.switcher = true
        ui.switcherQuery = ""
        ui.drawerOpen = true
        // Start on what most likely needs you: the first unread session, else the first one.
        ui.drawerSelection = (rows.first { $0.unread && !$0.session.running } ?? rows.first)?.id
        syncDrawer()
        drawer.allowsKey = true
        NSApp.activate(ignoringOtherApps: true)
        drawer.makeKeyAndOrderFront(nil)
    }

    /// `refocus`: hand focus back to the app you were in (not when a session was opened or you clicked away).
    func closeSwitcher(refocus: Bool) {
        guard ui.switcher else { return }
        ui.switcher = false
        ui.switcherQuery = ""
        ui.drawerOpen = false
        ui.drawerSelection = nil
        drawer.allowsKey = false
        drawer.resignKey()
        if refocus, NSApp.isActive, let app = previousApp { app.activate() }
        previousApp = nil
    }

    /// What the switcher's keys move through: your strip's sessions, or what matches what you typed.
    private var switcherRows: [AgentRow] {
        ui.switcherQuery.isEmpty
            ? Array(store.allAgentRows.prefix(store.agentRows.kept.count + PillView.pendingTiles))
            : store.searchSessions(ui.switcherQuery)
    }

    private func handleSwitcherKey(_ event: NSEvent) -> NSEvent? {
        let rows = switcherRows
        let current = rows.first { $0.id == ui.drawerSelection }
        let pressed = Shortcut(event)
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]  // 1…9 by key position (no ⇧ needed on AZERTY)
        let typed = event.characters ?? ""
        if event.keyCode == 53 {
            // Esc clears what you typed first, then closes.
            if ui.switcherQuery.isEmpty { closeSwitcher(refocus: true) } else { setQuery("") }
        } else if event.keyCode == 125 || event.keyCode == 126 {
            guard !rows.isEmpty else { return nil }
            let i = rows.firstIndex { $0.id == ui.drawerSelection } ?? (event.keyCode == 125 ? -1 : rows.count)
            ui.drawerSelection = rows[min(max(i + (event.keyCode == 125 ? 1 : -1), 0), rows.count - 1)].id
        } else if let n = digits.firstIndex(of: event.keyCode), plain, ui.switcherQuery.isEmpty {
            if n < rows.count { open(rows[n]) }
        } else if let row = current, pressed == store.shortcut(.openItem) {
            open(row)
        } else if event.keyCode == 51, plain, !ui.switcherQuery.isEmpty {
            setQuery(String(ui.switcherQuery.dropLast()))
        } else if let row = current, pressed == store.shortcut(.keepSession) {
            store.keepAgent(row.id)
        } else if let row = current, ui.switcherQuery.isEmpty, pressed == store.shortcut(.toggleRead) {
            store.toggleAgentRead(row.id)
        } else if let row = current, pressed == store.shortcut(.removeSession) {
            let i = rows.firstIndex(of: row) ?? 0
            store.dismissAgent(row.id)
            let left = switcherRows
            ui.drawerSelection = left.isEmpty ? nil : left[min(i, left.count - 1)].id
        } else if plain, let c = typed.first, typed.count == 1, c.isLetter || c.isNumber || c.isPunctuation || c.isSymbol || c == " " {
            // Anything else you type searches every session.
            if c == " " && ui.switcherQuery.isEmpty { return nil }
            setQuery(ui.switcherQuery + typed)
        } else {
            return event
        }
        return nil
    }

    private func setQuery(_ query: String) {
        ui.switcherQuery = query
        let rows = switcherRows
        ui.drawerSelection = (query.isEmpty ? rows.first { $0.unread && !$0.session.running } ?? rows.first : rows.first)?.id
    }

    private func open(_ row: AgentRow) {
        closeSwitcher(refocus: false)
        store.openAgent(row.id)
    }

    private func handleAgentsKey(_ event: NSEvent, _ pressed: Shortcut) -> NSEvent? {
        let rows = store.allAgentRows
        let current = rows.first { $0.id == ui.agentSelection }
        switch event.keyCode {
        case 125, 126:
            guard !rows.isEmpty else { return nil }
            let i = rows.firstIndex { $0.id == ui.agentSelection } ?? (event.keyCode == 125 ? -1 : rows.count)
            ui.agentSelection = rows[min(max(i + (event.keyCode == 125 ? 1 : -1), 0), rows.count - 1)].id
            return nil
        default: break
        }
        guard let row = current else { return event }
        if pressed == store.shortcut(.openItem) {
            store.openAgent(row.id)
        } else if pressed == store.shortcut(.toggleRead) {
            store.toggleAgentRead(row.id)
        } else if row.pending, pressed == store.shortcut(.keepSession) {
            store.keepAgent(row.id)
        } else if pressed == store.shortcut(.removeSession) {
            store.dismissAgent(row.id)
        } else {
            return event
        }
        return nil
    }

    // MARK: Panel

    func toggle(_ tab: PanelTab) {
        if ui.isOpen && ui.tab == tab {
            hidePanel()
        } else {
            ui.tab = tab
            showPanel()
        }
    }

    private func positionPanel() {
        let vf = screen.visibleFrame
        let pf = pill.frame
        let size = panel.frame.size
        let pad = Self.panelPadding
        let gap: CGFloat = 4
        let centeredX = min(max(pf.midX - size.width / 2, vf.minX - pad), vf.maxX - size.width + pad)
        let centeredY = min(max(pf.midY - size.height / 2, vf.minY - pad), vf.maxY - size.height + pad)
        let origin = switch ui.edge {
        case .left: NSPoint(x: pf.maxX + gap - pad, y: centeredY)
        case .right: NSPoint(x: pf.minX - gap - size.width + pad, y: centeredY)
        case .top: NSPoint(x: centeredX, y: pf.minY - gap - size.height + pad)
        case .bottom: NSPoint(x: centeredX, y: pf.maxY + gap - pad)
        }
        panel.setFrameOrigin(origin)
    }

    private func showPanel() {
        // From the switcher (its "more pending" row): keep the app to hand focus back to.
        let saved = previousApp
        closeSwitcher(refocus: false)
        previousApp = saved
        ui.drawerOpen = false
        positionPanel()
        if !ui.isOpen {
            // Take keyboard focus so the inbox shortcuts work without clicking into the panel first.
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            NSApp.activate(ignoringOtherApps: true)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { self.panel.invalidateShadow() }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        ui.isOpen = true
    }

    func hidePanel() {
        guard ui.isOpen else { return }
        ui.isOpen = false
        // Closed from inside (Esc, ✕, shortcut, pill): hand focus back. A click in another app already moved it.
        if NSApp.isActive, let app = previousApp {
            app.activate()
        }
        previousApp = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.ui.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }
}
