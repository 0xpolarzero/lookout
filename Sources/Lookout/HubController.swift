import AppKit
import Observation
import SwiftUI

/// Where the hub sits in its window, and what the controller needs to know about it.
@Observable
@MainActor
final class HubLayout {
    /// Docked: the window spans the edge and the hub is placed along it. Floating: the window is exactly the bar
    /// (while it's dragged to another edge).
    var floating = false
    /// The bar's length along its edge at rest: the expanded view keeps the bar's start where it was.
    var restLength: CGFloat = 0
    /// The bar's size at rest, to carry exactly that when it's dragged.
    @ObservationIgnored var restSize: CGSize = .zero
    /// The hub's frame in the window (top-left origin).
    @ObservationIgnored var frame: CGRect = .zero {
        didSet { if frame != oldValue { onFrame?() } }
    }
    @ObservationIgnored var onFrame: (() -> Void)?
}

/// A transparent window over the bar at rest. The real window lets the mouse through everywhere until the pointer
/// is on the hub; this one's tracking area is how that's noticed without a system-wide mouse monitor.
private final class HoverTrigger: FloatingPanel {
    private final class TriggerView: NSView {
        var onHover: (() -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onHover?() }
        override func mouseMoved(with event: NSEvent) { onHover?() }
    }

    private let trigger = TriggerView()
    var onHover: (() -> Void)? {
        get { trigger.onHover }
        set { trigger.onHover = newValue }
    }

    override init(size: NSSize) {
        super.init(size: size)
        contentView = trigger
        // It takes the mouse (a window that ignores it gets no tracking events); it only covers the hub's own frame,
        // and goes away the moment the pointer is on it.
        acceptsMouseMovedEvents = true
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Places the hub against its edge: flush with the screen, at its position along the edge, and kept on screen
/// as it grows (from the bar's top on the sides, from its left end along the top and bottom).
private struct EdgeLayout: Layout {
    let edge: DockEdge
    let position: Double
    let restLength: CGFloat
    private let inset = Theme.Metrics.inset

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let hub = subviews.first else { return }
        let size = hub.sizeThatFits(.unspecified)
        func along(_ length: CGFloat, _ own: CGFloat) -> CGFloat {
            // From where the bar starts at rest, so the bar never moves as the view opens or a divider is dragged.
            let start = length * position - restLength / 2
            return min(max(start, inset), length - own - inset)
        }
        let origin = switch edge {
        case .right: CGPoint(x: bounds.maxX - size.width, y: bounds.minY + along(bounds.height, size.height))
        case .left: CGPoint(x: bounds.minX, y: bounds.minY + along(bounds.height, size.height))
        case .top: CGPoint(x: bounds.minX + along(bounds.width, size.width), y: bounds.minY)
        case .bottom: CGPoint(x: bounds.minX + along(bounds.width, size.width), y: bounds.maxY - size.height)
        }
        hub.place(at: origin, proposal: .unspecified)
    }
}

struct HubRoot: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let layout: HubLayout
    var maxLength: CGFloat

    var body: some View {
        GeometryReader { geo in content(in: geo.size) }
            .coordinateSpace(.named(LookoutHub.rootSpace))
            // Tooltips are drawn over the whole window, outside the hub's clipped shape, so they're never cut off.
            .tipSpace()
    }

    /// On the sides the view grows down from the bar, into the room below it, so the bar doesn't move as it opens;
    /// it only moves up when there's too little room below.
    private func length(in size: CGSize) -> CGFloat {
        guard !ui.edge.isHorizontal else { return maxLength }
        let position = store.settings.centerPill == true ? 0.5 : ui.position
        let top = min(max(size.height * position - layout.restLength / 2, 6), size.height - layout.restLength - 6)
        return min(maxLength, max(size.height - top - 12, 560))
    }

    @ViewBuilder private func content(in size: CGSize) -> some View {
        let view = LookoutHub(store: store, ui: ui, hub: hub, maxLength: length(in: size), maxWidth: size.width)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LookoutHub.rootSpace)) } action: { frame in
                if HubController.debug { NSLog("Lookout hub frame \(frame)") }
                layout.frame = frame
                if !hub.expanded, hub.page == .main {
                    layout.restLength = ui.edge.isHorizontal ? frame.width : frame.height
                    layout.restSize = frame.size
                }
            }
        Group {
            if layout.floating {
                view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                EdgeLayout(edge: ui.edge, position: store.settings.centerPill == true ? 0.5 : ui.position,
                           restLength: layout.restLength) { view }
                    .motion(hub.expanded ? LookoutHub.opening : LookoutHub.closing, value: hub.expanded)
            }
        }
    }
}

/// The app's one window: the hub on its screen edge. The window spans the edge (so the hub can grow without the
/// window being resized mid-animation) and lets the mouse through everywhere but the hub itself.
@MainActor
final class HubController {
    let store: Store
    let ui: UIState
    let hub = HubState()
    let keys: HubKeys
    private let layout = HubLayout()
    private let window: PillPanel
    private let host: NSHostingView<HubRoot>
    private var screen: NSScreen
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    /// The hover state a scheduled task is about to apply, so repeated events don't reschedule it.
    private var pendingHover: Bool?
    /// Whether the hub was last reported to the store as visible beyond the bare bar.
    private var reportedOpen = false
    private var lastPinned = false
    /// The app that had focus before the hub took it, to hand it back.
    private var previousApp: NSRunningApplication?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    fileprivate static let debug = ProcessInfo.processInfo.environment["LOOKOUT_DEBUG"] != nil
    private let trigger = HoverTrigger(size: NSSize(width: 10, height: 10))
    private var globalMouse: Any?

    /// `demo`: on the right edge and nothing saved, so trying it never moves your real bar.
    init(store: Store, demo: Bool = false) {
        self.store = store
        ui = demo ? UIState(persists: false, edge: .right) : UIState()
        keys = HubKeys(store: store, ui: ui, hub: hub)
        // The screen you're looking at: the one with the mouse.
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        window = PillPanel(size: NSSize(width: 100, height: 100))
        window.allowsKey = true
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true
        host = NSHostingView(rootView: HubRoot(store: store, ui: ui, hub: hub, layout: layout, maxLength: 600))
        host.sizingOptions = []
        window.contentView = host
        keys.onClose = { [weak self] in self?.giveFocusBack() }
        window.onCancel = { [weak self] in
            guard let self, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, characters: "\u{1b}",
                                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            else { return }
            _ = self.keys.key(esc)
        }
        trigger.onHover = { [weak self] in self?.mouseMoved() }
        layout.onFrame = { [weak self] in self?.syncTrigger() }
        window.canDrag = { [weak self] p in self?.isOnBar(p) ?? false }
        window.onDragChanged = { [weak self] in self?.dragChanged(to: $0) }
        window.onDragEnded = { [weak self] in self?.dragEnded(at: $0) }
        dock()
        window.orderFrontRegardless()
        watchMouse()
        syncTrigger()
        watchKeys()
        observe()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !NSScreen.screens.contains(self.screen) { self.screen = NSScreen.main ?? NSScreen.screens[0] }
                self.dock()
            }
        }
    }

    // MARK: Window

    /// The window along the edge, deep enough for the expanded hub and its shadow.
    private func dockFrame() -> (NSRect, CGFloat) {
        let vf = screen.visibleFrame
        switch ui.edge {
        case .right, .left:
            let depth = LookoutHub.cell + LookoutHub.detail + 40
            let x = ui.edge == .right ? vf.maxX - depth : vf.minX
            return (NSRect(x: x, y: vf.minY, width: depth, height: vf.height), vf.height - 12)
        case .top, .bottom:
            let depth = min(vf.height, 780)
            let y = ui.edge == .top ? vf.maxY - depth : vf.minY
            return (NSRect(x: vf.minX, y: y, width: vf.width, height: depth), depth - 40)
        }
    }

    private func dock() {
        let (frame, maxLength) = dockFrame()
        layout.floating = false
        host.rootView = HubRoot(store: store, ui: ui, hub: hub, layout: layout, maxLength: maxLength)
        window.setFrame(frame, display: true)
        syncTrigger()
    }

    /// The hub's frame on screen (AppKit coordinates).
    private var hubScreenFrame: NSRect { screenFrame(layout.frame) }

    /// A frame in the window (top-left origin) on screen.
    private func screenFrame(_ f: CGRect) -> NSRect {
        let w = window.frame
        return NSRect(x: w.minX + f.minX, y: w.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// The bar itself (where a drag can start), in window coordinates (bottom-left origin).
    private func isOnBar(_ p: NSPoint) -> Bool {
        guard hub.page == .main else { return false }
        let f = layout.frame
        let h = window.frame.height
        let hubRect = NSRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
        guard hubRect.contains(p) else { return false }
        if layout.floating || !hub.expanded { return true }
        let d = ui.edge.isHorizontal ? Theme.Metrics.bar : LookoutHub.cell
        return switch ui.edge {
        case .right: p.x >= hubRect.maxX - d
        case .left: p.x <= hubRect.minX + d
        case .top: p.y >= hubRect.maxY - d
        case .bottom: p.y <= hubRect.minY + d
        }
    }

    // MARK: Mouse

    /// The window only takes the mouse over the hub; hovering it opens it after a beat, leaving closes it.
    /// At rest nothing watches the mouse system-wide: a tracking area over the bar (`HoverTrigger`) notices the
    /// pointer arriving. The global monitor, to notice it leaving, runs only while the window takes the mouse.
    private func watchMouse() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(local) }
    }

    /// Whether the window takes the mouse (the pointer is on the hub). A window-server call, so only on change.
    private func setAcceptsMouse(_ accepts: Bool) {
        if window.ignoresMouseEvents == accepts { window.ignoresMouseEvents = !accepts }
        syncTrigger()
    }

    /// While the window takes the mouse: the global monitor runs (to notice the pointer leaving) and the arming
    /// window is away. Otherwise the arming window sits over the hub and nothing else watches.
    private func syncTrigger() {
        if !window.ignoresMouseEvents {
            if globalMouse == nil {
                globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.mouseMoved() }
                }
            }
            if trigger.isVisible { trigger.orderOut(nil) }
            return
        }
        if let global = globalMouse {
            NSEvent.removeMonitor(global)
            globalMouse = nil
        }
        guard layout.frame != .zero, dragStart == nil else { return }
        let frame = hubScreenFrame.insetBy(dx: -1, dy: -1)
        if trigger.frame != frame { trigger.setFrame(frame, display: false) }
        if !trigger.isVisible { trigger.orderFrontRegardless() }
        // The hub may have grown or moved under a still pointer.
        if frame.contains(NSEvent.mouseLocation) { mouseMoved() }
    }

    private func mouseMoved() {
        guard dragStart == nil else { return }
        let mouse = NSEvent.mouseLocation
        let inside = hubScreenFrame.insetBy(dx: -1, dy: -1).contains(mouse)
            || (hub.panelFrame != .zero && screenFrame(hub.panelFrame).insetBy(dx: -2, dy: -2).contains(mouse))
        // A window-server call, so only when it changes.
        setAcceptsMouse(inside)
        if inside == hub.hovering {
            // Closed from the keyboard with the pointer outside: the next entry may show a panel again.
            if !inside, hub.quiet { hub.quiet = false }
            if pendingHover != nil { hoverTask?.cancel(); pendingHover = nil }
            return
        }
        if pendingHover == inside { return }
        hoverTask?.cancel()
        // Passing over the bar on the way somewhere else shouldn't open it; nor should a drag from elsewhere.
        guard !inside || NSEvent.pressedMouseButtons == 0 else { pendingHover = nil; return }
        pendingHover = inside
        let delay: Duration = inside ? .zero : .milliseconds(120)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingHover = nil
            self.hub.hovering = inside
            if !inside {
                self.hub.cancelDwell()
                self.hub.section = nil
                self.hub.quiet = false
                self.closedByLeaving()
            }
        }
    }

    /// Mouse gone and not pinned: back to the bar, and the keyboard back to whatever had it.
    private func closedByLeaving() {
        guard !hub.pinned else { return }
        // Unpinned on a page and left: next time it opens on the main view.
        hub.go(.main)
        hub.selection = nil
        hub.query = ""
        if window.isKeyWindow { giveFocusBack() }
    }

    // MARK: Keys and focus

    private func watchKeys() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            // Only a Bool crosses the isolation hop: NSEvent is not Sendable.
            let consumed = MainActor.assumeIsolated {
                guard self.window.isKeyWindow, !self.store.isRecordingShortcut else { return false }
                // A tooltip on screen takes the first Esc.
                return TipCenter.dismissVisible(for: event) || self.keys.key(event)
            }
            return consumed ? nil : event
        }) { monitors.append(local) }
    }

    /// The keep-open shortcut (right ⌘, say): opens and keeps it open, or closes it.
    func toggleShortcut() {
        keys.toggleTap()
    }

    /// The session switcher shortcut: open on the sessions, the first one that needs you picked.
    func showSessions() {
        guard store.agents.enabled else { return }
        hub.go(.main)
        hub.pinned = true
        let rows = store.agentRows
        if let first = (rows.kept + rows.pending).first(where: { $0.unread && !$0.session.running }) ?? rows.kept.first {
            keys.select("a:" + first.id)
        }
    }

    /// A summary banner's click: the full view on the inbox, to see what arrived.
    func showInbox() {
        hub.go(.main)
        hub.focus = .inbox
        hub.pinned = true
    }

    private func takeFocus() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        setAcceptsMouse(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    private func giveFocusBack() {
        hub.selection = nil
        let app = previousApp ?? NSWorkspace.shared.frontmostApplication
        previousApp = nil
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
        window.resignKey()
        mouseMoved()
    }

    /// Pinning takes the keyboard; unpinning gives it back.
    private func observe() {
        withObservationTracking {
            _ = hub.pinned
            _ = ui.edge
            _ = hub.section
            _ = hub.quiet
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Keyboard focus moves only when pinning changes: a panel closing under a pinned hub must not steal it back.
                let pinnedChanged = self.hub.pinned != self.lastPinned
                self.lastPinned = self.hub.pinned
                if !pinnedChanged {
                } else if self.hub.pinned, !self.window.isKeyWindow {
                    self.takeFocus()
                } else if !self.hub.pinned, !self.hub.hovering, self.window.isKeyWindow {
                    self.giveFocusBack()
                }
                self.mouseMoved()
                self.reportOpen()
                self.observe()
            }
        }
    }

    /// Tells the store when the hub is more than the bare bar (a panel or the full view), so it refreshes stale
    /// data and polls faster meanwhile; warms the avatars the inbox is about to show.
    private func reportOpen() {
        let open = hub.pinned || (hub.section != nil && !hub.quiet)
        guard open != reportedOpen else { return }
        reportedOpen = open
        store.setHubOpen(open)
        if open {
            // Every author in the inbox (not just the newest items: the view may list another filter or a search),
            // and the account's own picture in Settings.
            var urls = Array(Set(store.items.compactMap(\.avatar))).prefix(60).compactMap { Avatar.sizedURL($0, size: 22) }
            if let me = Avatar.sizedURL(store.me?.avatarUrl, size: 30) { urls.append(me) }
            ImageCache.shared.prefetch(urls)
        }
    }

    func agentsChanged() {}

    // MARK: Dragging to another edge

    private func dragChanged(to mouse: NSPoint) {
        if dragStart == nil {
            hoverTask?.cancel()
            pendingHover = nil
            hub.cancelDwell()
            hub.section = nil
            // Back to the bar at once (no closing animation), and carry just the bar, under the cursor where you
            // grabbed it.
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) {
                hub.pinned = false
                hub.hovering = false
                hub.page = .main
                layout.floating = true
            }
            let rest = layout.restSize == .zero ? hubScreenFrame.size : layout.restSize
            let resting = restFrame(size: rest, in: screen.visibleFrame)
            let grip = NSPoint(x: min(max(mouse.x - resting.minX, 10), rest.width - 10),
                               y: min(max(mouse.y - resting.minY, 10), rest.height - 10))
            let bar = NSRect(origin: NSPoint(x: mouse.x - grip.x, y: mouse.y - grip.y), size: rest)
            window.setFrame(bar, display: true)
            dragStart = (mouse, bar.origin)
            hub.dragging = true
        }
        guard let start = dragStart else { return }
        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded(at mouse: NSPoint) {
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? screen
        let vf = screen.visibleFrame
        (ui.edge, ui.position) = EdgeSnap.snap(window.frame, in: vf)
        // Let SwiftUI lay the bar out for its new edge (it may turn), then glide it into place and dock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            let size = self.host.fittingSize
            let target = self.restFrame(size: size, in: vf)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.window.animator().setFrame(target, display: true)
            }, completionHandler: {
                MainActor.assumeIsolated {
                    self.dragStart = nil
                    self.hub.dragging = false
                    self.dock()
                    self.mouseMoved()
                }
            })
        }
    }

    /// Where the bar rests on its edge: the same place `EdgeLayout` puts it once docked.
    private func restFrame(size: NSSize, in vf: NSRect) -> NSRect {
        let position = store.settings.centerPill == true ? 0.5 : ui.position
        let (dock, _) = dockFrame()
        let inset: CGFloat = 6
        switch ui.edge {
        case .right, .left:
            let top = min(max(dock.height * position - size.height / 2, inset), dock.height - size.height - inset)
            let x = ui.edge == .right ? vf.maxX - size.width : vf.minX
            return NSRect(x: x, y: dock.maxY - top - size.height, width: size.width, height: size.height)
        case .top, .bottom:
            let left = min(max(dock.width * position - size.width / 2, inset), dock.width - size.width - inset)
            let y = ui.edge == .top ? vf.maxY - size.height : vf.minY
            return NSRect(x: dock.minX + left, y: y, width: size.width, height: size.height)
        }
    }
}
