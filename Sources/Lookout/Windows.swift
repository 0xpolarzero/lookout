import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class UIState {
    var isOpen = false
    var tab: PanelTab = .inbox
    var filter: InboxFilter = .needsYou
    var onLeft = UserDefaults.standard.bool(forKey: "pill.onLeft") {
        didSet { UserDefaults.standard.set(onLeft, forKey: "pill.onLeft") }
    }
    /// Vertical position of the pill as a fraction of the screen height.
    var pillY: Double = UserDefaults.standard.object(forKey: "pill.y") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(pillY, forKey: "pill.y") }
    }
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
    private var monitor: Any?

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
        let x = ui.onLeft ? vf.minX + 2 : vf.maxX - size.width - 2
        let y = min(max(vf.minY + vf.height * ui.pillY - size.height / 2, vf.minY), vf.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func layoutPill() {
        guard dragStart == nil else { return }
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
        ui.onLeft = pill.frame.midX < vf.midX
        ui.pillY = min(max((pill.frame.midY - vf.minY) / vf.height, 0.05), 0.95)
        let target = pillTarget()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pill.animator().setFrame(target, display: true)
        }
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
        let x = ui.onLeft ? pf.maxX + gap - pad : pf.minX - gap - size.width + pad
        let y = min(max(pf.midY - size.height / 2, vf.minY - pad), vf.maxY - size.height + pad)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func showPanel() {
        positionPanel()
        if !ui.isOpen {
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
