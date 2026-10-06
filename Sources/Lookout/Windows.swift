import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class UIState {
    /// Session row hovered anywhere in the hub (or picked with the keys).
    var drawerSelection: String?
    var edge: DockEdge = DockEdge(rawValue: UserDefaults.standard.string(forKey: "pill.edge") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "pill.onLeft") ? .left : .right) {
        didSet { if persists { UserDefaults.standard.set(edge.rawValue, forKey: "pill.edge") } }
    }
    /// Position of the hub along its edge, as a fraction of that edge's length.
    var position: Double = UserDefaults.standard.object(forKey: "pill.y") as? Double ?? 0.5 {
        didSet { if persists { UserDefaults.standard.set(position, forKey: "pill.y") } }
    }
    /// Off for screenshots, so rendering never moves the real hub.
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
        // Dark only: AppKit's own pieces (context menus, pop-ups, the field editor, selection) follow.
        appearance = NSAppearance(named: .darkAqua)
        // Lookout is an accessory app, inactive most of the time: without this, `.help` tooltips never show.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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

/// Where the hub docks: the closest screen edge to a dropped window, and where along it.
enum EdgeSnap {
    /// Closest screen edge to the dropped window, and where along that edge it sits (0…1).
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
}
