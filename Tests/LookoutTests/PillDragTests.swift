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
