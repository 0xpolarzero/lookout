import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

/// Where the hub sits on its edge (DESIGN.md 5.3, 8 gate 2): the arithmetic, and the real views at rest and kept open.
@Suite struct HubPlacement {
    private let window = CGRect(x: 0, y: 0, width: 1280, height: 800)
    private let size = CGSize(width: 466, height: 600)

    @Test func theBarStaysWhereItIsAsTheViewOpens() {
        // 400 tall at rest, centred a third of the way down the edge.
        let rest = HubGeometry.origin(edge: .right, position: 0.3, restLength: 400, size: CGSize(width: 46, height: 400), in: window)
        let open = HubGeometry.origin(edge: .right, position: 0.3, restLength: 400, size: size, in: window)
        #expect(rest.y == open.y)
        #expect(rest.x + 46 == open.x + size.width)
        for edge in [DockEdge.left, .top, .bottom] {
            let restOrigin = HubGeometry.origin(edge: edge, position: 0.3, restLength: 400, size: CGSize(width: edge.isHorizontal ? 400 : 46, height: edge.isHorizontal ? 46 : 400), in: window)
            let openOrigin = HubGeometry.origin(edge: edge, position: 0.3, restLength: 400, size: edge.isHorizontal ? CGSize(width: 832, height: 500) : size, in: window)
            if edge.isHorizontal { #expect(restOrigin.x == openOrigin.x, "\(edge)") } else { #expect(restOrigin.y == openOrigin.y, "\(edge)") }
        }
    }

    @Test func onlyTheScreensEndMovesItAndByTheLeast() {
        // Too long to fit below where the bar starts: it moves up by exactly what it overhangs, to the inset.
        let tall = CGSize(width: 466, height: 700)
        let y = HubGeometry.origin(edge: .right, position: 0.7, restLength: 400, size: tall, in: window).y
        #expect(y == window.height - tall.height - HubGeometry.inset)
        // Never above the top inset, and a hub taller than the screen starts at it.
        let first = HubGeometry.origin(edge: .left, position: 0.0, restLength: 400, size: size, in: window).y
        #expect(first == HubGeometry.inset)
        let huge = HubGeometry.origin(edge: .left, position: 0.5, restLength: 400, size: CGSize(width: 466, height: 900), in: window).y
        #expect(huge == HubGeometry.inset)
    }

    @Test func theFullViewFitsAnyScreen() {
        // The longest it may be leaves both insets; along the top and bottom it never outgrows the screen's width.
        #expect(HubGeometry.maxLength(visibleHeight: 695) == 683)
        #expect(HubGeometry.stripWidth(focus: nil, sessions: true, room: 1280) == 832)
        #expect(HubGeometry.stripWidth(focus: nil, sessions: true, room: 700) == 688)
        #expect(HubGeometry.stripWidth(focus: nil, sessions: false, room: 1280) == 420)
        #expect(HubGeometry.stripWidth(focus: .inbox, sessions: true, room: 1280) == 560)
        #expect(HubGeometry.firstCellCenter == HubGeometry.lead + Theme.Metrics.pitch / 2)
    }
}

/// The hub in its window as the app lays it out (`HubRoot`), rendered at rest and kept open and compared pixel for
/// pixel: what the user aimed at doesn't move.
@MainActor
@Suite struct RestVersusOpen {
    private let screen = CGSize(width: 1280, height: 800)

    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
            return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
        }

        /// The amber of a tile that needs you (`Theme.amber`, as the hosting view's colour space renders it).
        func isAmber(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.a > 250 && p.r > 225 && (170...205).contains(p.g) && (50...115).contains(p.b)
        }

        /// The first amber blob, scanning the band from its start: its box in points.
        func firstAmber(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, fromTop: Bool = true) -> CGRect? {
            let xs = Int(x.lowerBound * scale)...Int(min(x.upperBound * scale, CGFloat(rep.pixelsWide - 1)))
            let ys = Int(y.lowerBound * scale)...Int(min(y.upperBound * scale, CGFloat(rep.pixelsHigh - 1)))
            var top: Int?
            for py in ys where top == nil { for px in xs where isAmber(px, py) { top = py; break } }
            guard let top else { return nil }
            let limit = top + Int(30 * scale)
            var box = CGRect.null
            for py in top...min(limit, ys.upperBound) { for px in xs where isAmber(px, py) { box = box.union(CGRect(x: px, y: py, width: 1, height: 1)) } }
            return CGRect(x: box.minX / scale, y: box.minY / scale, width: (box.width) / scale, height: (box.height) / scale)
        }

        /// The hub's first opaque column along a row (its leading edge when it hangs from the top or bottom).
        func firstOpaque(row y: CGFloat) -> CGFloat? {
            let py = Int(y * scale)
            for px in 0..<rep.pixelsWide where pixel(px, py).a > 250 { return CGFloat(px) / scale }
            return nil
        }
    }

    private func render(edge: DockEdge, open: Bool) -> Shot {
        let store = Store()
        Demo.populate(store, .agents)
        store.agents.expanded = true
        let ui = UIState(persists: false, edge: edge)
        ui.position = 0.3
        let hub = HubState()
        let layout = HubLayout()
        let root = HubRoot(store: store, ui: ui, hub: hub, layout: layout).frame(width: screen.width, height: screen.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = screen
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        func settle(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                hosting.layoutSubtreeIfNeeded()
            }
        }
        settle(0.7)
        if open {
            hub.pinned = true
            settle(1.0)
        }
        hosting.layoutSubtreeIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.orderOut(nil)
        return Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / screen.width)
    }

    @Test(arguments: [DockEdge.right, .left])
    func theInboxTileDoesNotMoveOnTheSides(edge: DockEdge) {
        let band = edge == .right ? (screen.width - 46)...screen.width : 0...46
        let rest = render(edge: edge, open: false)
        let open = render(edge: edge, open: true)
        let a = rest.firstAmber(x: band, y: 0...screen.height)
        let b = open.firstAmber(x: band, y: 0...screen.height)
        #expect(a != nil && b != nil, "\(edge): no amber tile found")
        guard let a, let b else { return }
        // Compared by centre: the tile's own size is the bar's business.
        #expect(abs(a.midX - b.midX) < 0.5 && abs(a.midY - b.midY) < 0.5, "\(edge): tile at \(a), kept open at \(b)")
    }

    @Test(arguments: [DockEdge.top, .bottom])
    func theStripsLeadingEdgeStaysPut(edge: DockEdge) {
        // Halfway through the strip's depth.
        let row = edge == .top ? Theme.Metrics.bar / 2 : screen.height - Theme.Metrics.bar / 2
        let rest = render(edge: edge, open: false)
        let open = render(edge: edge, open: true)
        let a = rest.firstOpaque(row: row)
        let b = open.firstOpaque(row: row)
        #expect(a != nil && b != nil, "\(edge): no hub found")
        guard let a, let b else { return }
        #expect(abs(a - b) < 0.5, "\(edge): strip starts at \(a), kept open at \(b)")
    }
}
