import AppKit
import Testing
@testable import Lookout

@MainActor
@Suite struct PillDrag {
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func panel() -> (PillPanel, () -> [String]) {
        let panel = PillPanel(size: NSSize(width: 44, height: 120))
        panel.setFrameOrigin(NSPoint(x: 500, y: 500))
        var log: [String] = []
        panel.onDragChanged = { p in log.append("changed \(Int(p.x)),\(Int(p.y))") }
        panel.onDragEnded = { p in log.append("ended \(Int(p.x)),\(Int(p.y))") }
        return (panel, { log })
    }

    @Test func dragAnywhereMovesPill() {
        let (panel, log) = panel()
        panel.sendEvent(event(.leftMouseDown, 20, 60, in: panel))
        panel.sendEvent(event(.leftMouseDragged, 20, 80, in: panel))
        panel.sendEvent(event(.leftMouseUp, 20, 90, in: panel))
        #expect(log() == ["changed 520,560", "changed 520,580", "ended 520,590"])
    }

    @Test func clickIsNotADrag() {
        let (panel, log) = panel()
        panel.sendEvent(event(.leftMouseDown, 20, 60, in: panel))
        panel.sendEvent(event(.leftMouseDragged, 21, 61, in: panel))  // jitter under the threshold
        panel.sendEvent(event(.leftMouseUp, 21, 61, in: panel))
        #expect(log().isEmpty)
    }
}

@Suite struct Snapping {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private func pill(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x - 20, y: y - 20, width: 40, height: 40) }

    @Test func snapsToNearestEdge() {
        #expect(EdgeSnap.snap(pill(30, 500), in: screen).0 == .left)
        #expect(EdgeSnap.snap(pill(1490, 500), in: screen).0 == .right)
        #expect(EdgeSnap.snap(pill(700, 920), in: screen).0 == .top)
        #expect(EdgeSnap.snap(pill(700, 25), in: screen).0 == .bottom)
    }

    @Test func positionFollowsTheEdge() {
        let (edge, position) = EdgeSnap.snap(pill(378, 920), in: screen)
        #expect(edge == .top)
        #expect(abs(position - 0.25) < 0.001)
        let (side, height) = EdgeSnap.snap(pill(1490, 472), in: screen)
        #expect(side == .right)
        #expect(abs(height - 0.5) < 0.001)
    }
}

/// Settings places the bar as a drop would (WCAG 2.5.7): the same limits along an edge, and the same place for it to rest.
@MainActor
@Suite struct Placing {
    @Test func theSpotsRunBetweenTheDropsOwnLimitsAndNameTheWayTheEdgeRuns() {
        for edge in DockEdge.allCases {
            let spots = EdgeSnap.spots(edge)
            let range = EdgeSnap.positions(edge)
            #expect(spots.map(\.position) == [range.lowerBound, 0.25, 0.5, 0.75, range.upperBound])
            // Dropping the bar on a spot's place snaps to that edge and that place.
            let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
            let at: (Double) -> NSRect = { p in
                switch edge {
                case .left: NSRect(x: 0, y: 800 * p - 20, width: 40, height: 40)
                case .right: NSRect(x: 960, y: 800 * p - 20, width: 40, height: 40)
                case .top: NSRect(x: 1000 * p - 20, y: 760, width: 40, height: 40)
                case .bottom: NSRect(x: 1000 * p - 20, y: 0, width: 40, height: 40)
                }
            }
            for spot in spots {
                let (snapped, position) = EdgeSnap.snap(at(spot.position), in: screen)
                #expect(snapped == edge && abs(position - spot.position) < 0.001, "\(edge) \(spot.title)")
            }
        }
        #expect(EdgeSnap.spots(.right).map(\.title) == ["Top", "Upper", "Centre", "Lower", "Bottom"])
        #expect(EdgeSnap.spots(.top).map(\.title).first == "Left")
    }

    @Test func withoutAWindowPlacingRemembersTheEdgeAndThePosition() {
        let ui = UIState(persists: false, edge: .right)
        ui.place(BarPlacement(edge: .top))
        ui.place(BarPlacement(position: 0.25))
        #expect(ui.edge == .top && ui.position == 0.25)
        var placed: [BarPlacement] = []
        ui.onPlace = { placed.append($0) }
        ui.place(BarPlacement(edge: .left, display: "Studio"))
        // The controller does the moving: what is remembered is its to set.
        #expect(placed.count == 1 && placed[0].edge == .left && placed[0].display == "Studio" && ui.edge == .top)
    }
}
