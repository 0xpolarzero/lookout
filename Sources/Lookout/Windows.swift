import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class UIState {
    /// Session row hovered anywhere in the hub (or picked with the keys). A row asks `hot(_:)`, not this.
    var drawerSelection: String? {
        didSet { drawerLights.current = drawerSelection }
    }
    @ObservationIgnored let drawerLights = Lights()

    /// Whether this session's row is the one hovered or picked anywhere: read by the row alone.
    func hot(_ id: String) -> Bool { drawerLights.isOn(id) }
    var edge: DockEdge = DockEdge(rawValue: UserDefaults.standard.string(forKey: "pill.edge") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "pill.onLeft") ? .left : .right) {
        didSet { if persists { UserDefaults.standard.set(edge.rawValue, forKey: "pill.edge") } }
    }
    /// Position of the hub along its edge, as a fraction of that edge's length.
    var position: Double = UserDefaults.standard.object(forKey: "pill.y") as? Double ?? 0.5 {
        didSet { if persists { UserDefaults.standard.set(position, forKey: "pill.y") } }
    }
    /// The display the bar is on, for Settings' placement controls.
    var display: CGDirectDisplayID = NSScreen.main?.displayID ?? 0
    /// Off for screenshots, so rendering never moves the real hub.
    @ObservationIgnored var persists = true
    /// Moves the bar for real (its window, its screen): set by the controller. Without one, only what is remembered changes.
    @ObservationIgnored var onPlace: ((BarPlacement) -> Void)?

    /// Where Settings puts the bar, what dragging it does with the mouse: another edge, a place along it, another display.
    func place(_ placement: BarPlacement) {
        if let onPlace { return onPlace(placement) }
        if let edge = placement.edge { self.edge = edge }
        if let position = placement.position { self.position = position }
    }

    init() {}

    init(persists: Bool, edge: DockEdge) {
        self.persists = persists
        self.edge = edge
    }
}

/// A change of where the bar rests: any of the three, the others as they are.
struct BarPlacement {
    var edge: DockEdge?
    var position: Double?
    /// A display's `displayID`: two monitors of one model share their name, never their identity.
    var display: CGDirectDisplayID?
}

/// A display Settings can put the bar on: what identifies it, and what the pop-up calls it.
struct DisplayChoice: Hashable {
    let id: CGDirectDisplayID
    let title: String

    /// Titles for `screens` in their order: the name, with a number after each of the ones that share it.
    static func list(_ screens: [(id: CGDirectDisplayID, name: String)]) -> [DisplayChoice] {
        var seen: [String: Int] = [:]
        return screens.map { screen in
            let same = screens.filter { $0.name == screen.name }.count
            seen[screen.name, default: 0] += 1
            return DisplayChoice(id: screen.id, title: same > 1 ? "\(screen.name) (\(seen[screen.name]!))" : screen.name)
        }
    }

    @MainActor static var connected: [DisplayChoice] { list(NSScreen.screens.map { ($0.displayID, $0.localizedName) }) }
}

extension NSScreen {
    /// The identity of the display, which its name is not.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum DockEdge: String, CaseIterable {
    case left, right, top, bottom

    var isHorizontal: Bool { self == .top || self == .bottom }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
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
    /// How far along its edge the bar may rest (a fraction of it): the drag's own limits.
    nonisolated static func positions(_ edge: DockEdge) -> ClosedRange<Double> { edge.isHorizontal ? 0.03...0.97 : 0.05...0.95 }

    /// The places Settings offers along an edge, named for the way it runs: the two ends (the drag's own limits), the middle,
    /// and between.
    nonisolated static func spots(_ edge: DockEdge) -> [(title: String, position: Double)] {
        let range = positions(edge)
        let titles = edge.isHorizontal ? ["Left", "Left of centre", "Centre", "Right of centre", "Right"]
            : ["Top", "Upper", "Centre", "Lower", "Bottom"]
        return zip(titles, [range.lowerBound, 0.25, 0.5, 0.75, range.upperBound]).map { ($0, $1) }
    }

    /// Closest screen edge to the dropped window, and where along that edge it sits (0…1, from the left or from the top, as
    /// the bar rests).
    nonisolated static func snap(_ f: NSRect, in vf: NSRect) -> (DockEdge, Double) {
        let distances: [(DockEdge, CGFloat)] = [
            (.left, f.midX - vf.minX), (.right, vf.maxX - f.midX), (.top, vf.maxY - f.midY), (.bottom, f.midY - vf.minY),
        ]
        let edge = distances.min { $0.1 < $1.1 }!.0
        let along = edge.isHorizontal ? (f.midX - vf.minX) / vf.width : (vf.maxY - f.midY) / vf.height
        let limits = positions(edge)
        return (edge, min(max(along, limits.lowerBound), limits.upperBound))
    }
}
