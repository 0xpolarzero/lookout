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

    @Test func aSideDropDocksAtTheHeightItWasDroppedAt() {
        // Along a side the position counts from the top, as the bar rests: the upper quarter stays the upper quarter.
        let (upper, fromTop) = EdgeSnap.snap(pill(30, 944 * 0.75), in: screen)
        #expect(upper == .left && abs(fromTop - 0.25) < 0.001)
        let (lower, below) = EdgeSnap.snap(pill(1490, 944 * 0.2), in: screen)
        #expect(lower == .right && abs(below - 0.8) < 0.001)
    }
}
