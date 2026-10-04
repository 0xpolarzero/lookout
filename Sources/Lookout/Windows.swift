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
}

/// The whole pill is draggable. A mouse-down is held back until we know whether it's a click (forwarded to
/// SwiftUI on mouse-up) or a drag (moves the window; SwiftUI never sees it, so no button fires).
final class PillPanel: FloatingPanel {
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private var pendingDown: NSEvent?
    private var downAt: NSPoint = .zero
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        // Screen coordinates from the event itself (stable even though the window moves under the cursor).
        let p = convertPoint(toScreen: event.locationInWindow)
        switch event.type {
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
    private var pillHost: SizingHostingView<PillView>!
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var snapping = false
    /// App that had focus before the panel opened; it gets focus back when the panel closes.
    private var previousApp: NSRunningApplication?
    private var monitor: Any?
    private var keyMonitor: Any?

    init(store: Store) {
        self.store = store
        let actions = PillActions(
            toggle: { [weak self] tab in self?.toggle(tab) })

        let pillPanel = PillPanel(size: NSSize(width: 60, height: 200))
        pillPanel.onDragChanged = { [weak self] point in self?.dragChanged(to: point) }
        pillPanel.onDragEnded = { [weak self] point in self?.dragEnded(at: point) }
        pill = pillPanel
        pillHost = SizingHostingView(rootView: PillView(store: store, ui: ui, actions: actions))
        pillHost.onSizeChange = { [weak self] _ in self?.layoutPill() }
        pill.contentView = pillHost
        layoutPill()
        pill.orderFrontRegardless()

        let pad = Self.panelPadding * 2
        panel = FloatingPanel(size: NSSize(width: Self.panelContent.width + pad, height: Self.panelContent.height + pad))
        panel.allowsKey = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: PanelView(store: store, ui: ui, close: { [weak self] in self?.hidePanel() }))
        panel.onCancel = { [weak self] in self?.hidePanel() }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
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
        let alongX = min(max(vf.minX + vf.width * ui.position - size.width / 2, vf.minX), vf.maxX - size.width)
        let alongY = min(max(vf.minY + vf.height * ui.position - size.height / 2, vf.minY), vf.maxY - size.height)
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
    }

    private func dragChanged(to mouse: NSPoint) {
        if dragStart == nil {
            dragStart = (mouse, pill.frame.origin)
            hidePanel()
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
            let target = self.pillTarget()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.pill.animator().setFrame(target, display: true)
            }, completionHandler: {
                Task { @MainActor in
                    self.snapping = false
                    self.layoutPill()
                }
            })
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
        guard ui.isOpen, panel.isKeyWindow, !store.isRecordingShortcut else { return event }
        if event.keyCode == 53, event.modifierFlags.intersection(Shortcut.relevant).isEmpty {
            hidePanel()
            return nil
        }
        if panel.firstResponder is NSText { return event }
        let pressed = Shortcut(event)
        if pressed == store.shortcut(.refresh) {
            store.refreshNow()
            return nil
        }
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

    private func moveSelection(_ delta: Int, in list: [InboxItem]) {
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == ui.selection } ?? (delta > 0 ? -1 : list.count)
        ui.selection = list[min(max(index + delta, 0), list.count - 1)].id
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
