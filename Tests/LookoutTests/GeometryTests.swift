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

    @Test func aShorterHubStaysWhereTheBarIsEvenWhenTheBarIsClamped() {
        // A bar resting against the screen's end is clamped; a hub shorter than it keeps that place (it never drifts
        // down to where an unclamped start would be).
        let rest = HubGeometry.origin(edge: .right, position: 0.95, restLength: 400, size: CGSize(width: 46, height: 400), in: window).y
        let short = HubGeometry.origin(edge: .right, position: 0.95, restLength: 400, size: CGSize(width: 466, height: 300), in: window).y
        #expect(rest == window.height - 400 - HubGeometry.inset)
        #expect(short == rest)
    }

    @Test func theSidesFullViewStaysBelowWhereTheBarStartsAtRest() {
        // 800 high, 0.7 down, a 400 bar: it starts at 360, so the view may take what lies below, less the inset.
        let room = HubGeometry.sideLength(visibleHeight: 800, position: 0.7, restLength: 400)
        #expect(room == 800 - 360 - HubGeometry.inset)
        // Given that room, the hub's start is the bar's: nothing moves.
        let rest = HubGeometry.origin(edge: .right, position: 0.7, restLength: 400, size: CGSize(width: 46, height: 400), in: window).y
        let open = HubGeometry.origin(edge: .right, position: 0.7, restLength: 400, size: CGSize(width: 466, height: room), in: window).y
        #expect(rest == 360 && open == rest)
        // A bar clamped at the end has the room it rests in; one at the start has all that is left of the screen.
        #expect(HubGeometry.sideLength(visibleHeight: 800, position: 0.95, restLength: 400) == 400)
        #expect(HubGeometry.sideLength(visibleHeight: 800, position: 0.0, restLength: 400) == 800 - 2 * HubGeometry.inset)
    }

    @Test func aPanelFromALowCellMovesUpByWhatHangsPastTheScreen() {
        // A 720 screen leaves 714 to the panel: from a cell 90 above it, 130 of header and rows is 40 too many.
        #expect(HubGeometry.peekStart(624, length: 130, reach: 714) == 584)
        // Room enough, and it stays level with its cell; too long for any room, and it starts at the bar's start.
        #expect(HubGeometry.peekStart(300, length: 130, reach: 714) == 300)
        #expect(HubGeometry.peekStart(300, length: 900, reach: 714) == 0)
    }

    @Test func theSessionsColumnIsCutToTheInboxColumnsHeight() {
        // 500 of room; CI's block takes 150 and the inbox's rows 270 of what is left: the column is 420 tall.
        let inbox = ListHeights(shown: 270, content: 270)
        let rows = ListHeights(shown: 400, content: 800)
        let caps = HubGeometry.stripCaps(room: 500, leftFixed: 150, inbox: inbox, rightFixed: 36, sessions: rows)
        #expect(caps.inbox == 350.0)
        // The sessions' list gets what is left of that column's height after New session.
        #expect(caps.sessions == 384.0)
        // A column that would end within a row of the first one is left whole.
        let near = HubGeometry.stripCaps(room: 500, leftFixed: 150, inbox: inbox, rightFixed: 36, sessions: ListHeights(shown: 400, content: 400))
        #expect(near.sessions == 464.0)
        // Never cut to less than two rows and the "+N more" line; never more than the room.
        let tiny = HubGeometry.stripCaps(room: 500, leftFixed: 150, inbox: ListHeights(shown: 20, content: 20), rightFixed: 36, sessions: rows)
        #expect(tiny.sessions == 134.0)
        let least = HubGeometry.stripCaps(room: 500, leftFixed: 100, inbox: ListHeights(shown: 20, content: 20), rightFixed: 36, sessions: rows)
        #expect(least.sessions == 2 * Theme.Metrics.twoLineRow + Theme.Metrics.pitch)
        // The sessions never cut the inbox: it has what CI leaves, a longer list of them or not.
        let long = HubGeometry.stripCaps(room: 500, leftFixed: 150, inbox: ListHeights(shown: 350, content: 3000), rightFixed: 36,
                                         sessions: ListHeights(shown: 40, content: 40))
        #expect(long.inbox == 350.0 && long.sessions == 464.0)
        // Before the lists are measured, both are taken to use all their room.
        #expect(HubGeometry.stripCaps(room: 500, leftFixed: 150, inbox: nil, rightFixed: 36, sessions: nil).sessions == 464.0)
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

/// The hub in its window as the app lays it out (`HubRoot`) at rest and kept open, compared as the user sees it: what they
/// aimed at doesn't move, and nothing leaves the screen.
@MainActor
@Suite struct RestVersusOpen {
    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        /// The hub's frame in the window (`HubLayout`), top-left origin.
        let frame: CGRect
        /// The hover panel's, when one is open (zero otherwise).
        let panel: CGRect

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
            return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
        }

        /// A tile that needs you is the one saturated colour in the first cells: any hue, so a new tile colour doesn't
        /// break this (greys, the white count and the rail all sit far below it).
        func isColoured(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return p.a > 250 && max(p.r, p.g, p.b) - min(p.r, p.g, p.b) > 80
        }

        /// The first coloured blob, scanning the band from its start: its box in points.
        func firstTile(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> CGRect? {
            let xs = Int(x.lowerBound * scale)...Int(min(x.upperBound * scale, CGFloat(rep.pixelsWide - 1)))
            let ys = Int(y.lowerBound * scale)...Int(min(y.upperBound * scale, CGFloat(rep.pixelsHigh - 1)))
            var top: Int?
            for py in ys where top == nil { for px in xs where isColoured(px, py) { top = py; break } }
            guard let top else { return nil }
            let limit = top + Int(30 * scale)
            var box = CGRect.null
            for py in top...min(limit, ys.upperBound) { for px in xs where isColoured(px, py) { box = box.union(CGRect(x: px, y: py, width: 1, height: 1)) } }
            return CGRect(x: box.minX / scale, y: box.minY / scale, width: (box.width) / scale, height: (box.height) / scale)
        }

        /// How far above `y` (points) the nearest row with anything drawn over the surface colour is, within `x`.
        func gapAbove(y: CGFloat, x: ClosedRange<CGFloat>, surface: (r: Int, g: Int, b: Int, a: Int)) -> CGFloat? {
            let xs = Int(x.lowerBound * scale)...Int(x.upperBound * scale)
            var py = Int(y * scale) - 1
            while py >= 0 {
                for px in xs {
                    let p = pixel(px, py)
                    if abs(p.r - surface.r) + abs(p.g - surface.g) + abs(p.b - surface.b) > 24 { return y - CGFloat(py) / scale }
                }
                py -= 1
            }
            return nil
        }

        /// How far below `y` (points) the nearest row with anything drawn over the surface colour is, within `x`.
        func gapBelow(y: CGFloat, x: ClosedRange<CGFloat>, surface: (r: Int, g: Int, b: Int, a: Int)) -> CGFloat? {
            let xs = Int(x.lowerBound * scale)...Int(x.upperBound * scale)
            var py = Int(y * scale) + 1
            while py < rep.pixelsHigh {
                for px in xs {
                    let p = pixel(px, py)
                    if abs(p.r - surface.r) + abs(p.g - surface.g) + abs(p.b - surface.b) > 24 { return CGFloat(py) / scale - y }
                }
                py += 1
            }
            return nil
        }

        /// Whether a light glyph (a quiet one's pixels are at least this bright) is drawn within `rect` (points).
        func hasGlyph(in rect: CGRect) -> Bool {
            for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    let p = pixel(px, py)
                    if p.a > 250, min(p.r, p.g, p.b) > 120 { return true }
                }
            }
            return false
        }

        /// Whether anything is drawn over `surface` in the rows `ys` (points), within `x`.
        func hasContent(rows ys: ClosedRange<CGFloat>, x: ClosedRange<CGFloat>, surface: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            for py in Int(ys.lowerBound * scale)...Int(ys.upperBound * scale) {
                for px in Int(x.lowerBound * scale)...Int(x.upperBound * scale) {
                    let p = pixel(px, py)
                    if abs(p.r - surface.r) + abs(p.g - surface.g) + abs(p.b - surface.b) > 24 { return true }
                }
            }
            return false
        }

        /// The first row at or below `y` (points) that a hairline crosses: every sample along `x` is a little off `surface`.
        func hairline(from y: CGFloat, to end: CGFloat, x: ClosedRange<CGFloat>, surface: (r: Int, g: Int, b: Int, a: Int)) -> CGFloat? {
            let samples = stride(from: x.lowerBound, through: x.upperBound, by: 24).map { Int($0 * scale) }
            for py in Int(y * scale)...Int(end * scale) {
                let all = samples.allSatisfy { px in
                    let p = pixel(px, py)
                    return abs(p.r - surface.r) + abs(p.g - surface.g) + abs(p.b - surface.b) > 20
                }
                if all { return CGFloat(py) / scale }
            }
            return nil
        }

        /// The hub's first opaque column along a row (its leading edge when it hangs from the top or bottom).
        func firstOpaque(row y: CGFloat) -> CGFloat? {
            let py = Int(y * scale)
            for px in 0..<rep.pixelsWide where pixel(px, py).a > 250 { return CGFloat(px) / scale }
            return nil
        }
    }

    /// The hub at rest, then kept open (on `page` when one is given, with `focus` on a section) or, given a `section`,
    /// with just that panel open as when it is hovered, in a window of `screen`.
    private func render(edge: DockEdge, position: Double, screen: CGSize, page: HubPage? = nil, scenario: Demo.Scenario = .agents,
                        focus: HubSection? = nil, section: HubSection? = nil, setup: ((Store) -> Void)? = nil) -> (rest: Shot, open: Shot) {
        let store = Store()
        Demo.populate(store, scenario)
        store.agents.expanded = true
        setup?(store)
        let ui = UIState(persists: false, edge: edge)
        ui.position = position
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
        func capture() -> Shot {
            hosting.layoutSubtreeIfNeeded()
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return Shot(rep: rep, scale: CGFloat(rep.pixelsWide) / screen.width, frame: layout.frame, panel: hub.panelFrame)
        }
        settle(0.7)
        let rest = capture()
        if let section { hub.section = section } else { hub.pinned = true }
        if let page { hub.page = page }
        if let focus { hub.focus = focus }
        settle(1.0)
        let open = capture()
        window.contentView = nil
        window.orderOut(nil)
        return (rest, open)
    }

    /// The hub never leaves the screen: both insets along the edge, and across it the screen's own edge.
    private func expectInside(_ frame: CGRect, edge: DockEdge, screen: CGSize, _ label: String) {
        let inset = HubGeometry.inset
        let along = edge.isHorizontal ? (frame.minX, frame.maxX, screen.width) : (frame.minY, frame.maxY, screen.height)
        let across = edge.isHorizontal ? (frame.minY, frame.maxY, screen.height) : (frame.minX, frame.maxX, screen.width)
        #expect(along.0 >= inset - 0.5 && along.1 <= along.2 - inset + 0.5, "\(label): \(frame) along the edge in \(screen)")
        #expect(across.0 >= -0.5 && across.1 <= across.2 + 0.5, "\(label): \(frame) across the edge in \(screen)")
    }

    /// The inbox tile: the first coloured blob in the rail's column (for the sides).
    private func tile(_ shot: Shot, edge: DockEdge, screen: CGSize) -> CGRect? {
        let band = edge == .right ? (screen.width - 46)...screen.width : 0...46
        return shot.firstTile(x: band, y: 0...screen.height)
    }

    private nonisolated static let sides = [DockEdge.right, .left].flatMap { edge in [0.3, 0.7].map { (edge, $0) } }

    /// The tile and the hub's start are where they were at rest, and the hub is on the screen.
    private func expectTileStays(edge: DockEdge, position: Double, screen: CGSize, scenario: Demo.Scenario = .agents,
                                 setup: ((Store) -> Void)? = nil) {
        let (rest, open) = render(edge: edge, position: position, screen: screen, scenario: scenario, setup: setup)
        #expect(abs(rest.frame.minY - open.frame.minY) < 0.5, "\(edge) \(position): the hub starts at \(rest.frame.minY), kept open at \(open.frame.minY)")
        let a = tile(rest, edge: edge, screen: screen)
        let b = tile(open, edge: edge, screen: screen)
        #expect(a != nil && b != nil, "\(edge): no inbox tile found")
        guard let a, let b else { return }
        // Compared by centre: the tile's own size is the bar's business.
        #expect(abs(a.midX - b.midX) < 0.5 && abs(a.midY - b.midY) < 0.5, "\(edge) \(position): tile at \(a), kept open at \(b)")
        expectInside(open.frame, edge: edge, screen: screen, "\(edge) \(position)")
    }

    @Test(arguments: sides)
    func theInboxTileDoesNotMoveOnTheSides(edge: DockEdge, position: Double) {
        expectTileStays(edge: edge, position: position, screen: CGSize(width: 1280, height: 800))
    }

    /// Many inbox items, so the list is cut wherever the room is short.
    private func longInbox(_ store: Store, count: Int = 30) {
        let base = store.items
        store.items += (0..<count).map { i in
            var item = base[i % base.count]
            item.id = "long-\(i)"
            item.state = .unread
            return item
        }
    }

    /// With the sessions off the bar at rest is only as long as its few cells, and a bar resting at its end leaves the hub
    /// no more room than that: lower than 0.8 even the fixed parts of the full view do not fit, and it moves up.
    private nonisolated static let lowSides: [(DockEdge, Double, CGFloat)] = [DockEdge.right, .left].flatMap { edge in
        [0.7, 0.8].flatMap { position in [CGFloat(720), 800].map { (edge, position, $0) } }
    }

    @Test(arguments: lowSides)
    func theInboxTileStaysWithSessionsOffAndNoCIOnALowBar(edge: DockEdge, position: Double, height: CGFloat) {
        // The fixed parts are fewest here, so the lists' own minimum was what pushed the hub past the room under the bar.
        expectTileStays(edge: edge, position: position, screen: CGSize(width: 1280, height: height), scenario: .noCI) {
            $0.agents.enabled = false
            longInbox($0, count: 8)
        }
    }

    @Test(arguments: lowSides)
    func theInboxTileStaysWithSessionsOffAndCIOnALowBar(edge: DockEdge, position: Double, height: CGFloat) {
        expectTileStays(edge: edge, position: position, screen: CGSize(width: 1280, height: height)) {
            $0.agents.enabled = false
            longInbox($0, count: 8)
        }
    }

    private nonisolated static let strips = [DockEdge.top, .bottom].flatMap { edge in [0.3, 0.5].map { (edge, $0) } }

    @Test(arguments: strips)
    func theStripsLeadingEdgeStaysPut(edge: DockEdge, position: Double) {
        let screen = CGSize(width: 1280, height: 800)
        // Halfway through the strip's depth.
        let row = edge == .top ? Theme.Metrics.bar / 2 : screen.height - Theme.Metrics.bar / 2
        let (rest, open) = render(edge: edge, position: position, screen: screen)
        #expect(rest.frame.minX == open.frame.minX, "\(edge) \(position): the strip starts at \(rest.frame.minX), kept open at \(open.frame.minX)")
        let a = rest.firstOpaque(row: row)
        let b = open.firstOpaque(row: row)
        #expect(a != nil && b != nil, "\(edge): no hub found")
        guard let a, let b else { return }
        #expect(abs(a - b) < 0.5, "\(edge) \(position): strip starts at \(a), kept open at \(b)")
        expectInside(open.frame, edge: edge, screen: screen, "\(edge) \(position)")
    }

    @Test(arguments: [DockEdge.top, .bottom])
    func aStripTooNearTheEndIsMovedByTheLeast(edge: DockEdge) {
        let screen = CGSize(width: 1280, height: 800)
        let (rest, open) = render(edge: edge, position: 0.9, screen: screen)
        // At rest it is clamped against the end; kept open it is wider, so it ends at the inset instead.
        #expect(open.frame.maxX == screen.width - HubGeometry.inset, "\(edge): opens to \(open.frame)")
        #expect(open.frame.minX < rest.frame.minX && open.frame.width > rest.frame.width, "\(edge): \(rest.frame) then \(open.frame)")
        expectInside(open.frame, edge: edge, screen: screen, "\(edge) 0.9")
    }

    @Test func theBottomColumnsRestOnTheStripTheirHeadersAreIn() {
        // The inbox has fewer rows than the sessions need: its rows still sit on their header, not a band above it.
        let screen = CGSize(width: 1280, height: 800)
        let (_, open) = render(edge: .bottom, position: 0.3, screen: screen)
        let stripTop = open.frame.maxY - Theme.Metrics.bar
        let surface = open.pixel(Int((open.frame.minX + 100) * open.scale), Int((open.frame.minY + 4) * open.scale))
        // A few points above the hairline over the strip, in each column.
        let left = open.gapAbove(y: stripTop - 3, x: (open.frame.minX + 24)...(open.frame.minX + 380), surface: surface)
        let right = open.gapAbove(y: stripTop - 3, x: (open.frame.minX + 460)...(open.frame.maxX - 24), surface: surface)
        #expect(left != nil && left! < 16, "inbox rows end \(left ?? -1)pt above the strip")
        #expect(right != nil && right! < 16, "session rows end \(right ?? -1)pt above the strip")
    }

    private nonisolated static let columnScreens: [(DockEdge, CGFloat, Demo.Scenario)] = [DockEdge.top, .bottom].flatMap { edge in
        [CGFloat(800), 720].flatMap { height in [Demo.Scenario.agents, .sessions12].map { (edge, height, $0) } }
    }

    @Test(arguments: columnScreens)
    func noGapOpensBetweenTheFooterAndEitherColumnsFirstContent(edge: DockEdge, height: CGFloat, scenario: Demo.Scenario) {
        // The far end of the columns is where their slack ends up: the taller column is cut to whole rows, so what is
        // left is under one row (the tallest, a session with its task line), never a void beside the footer.
        let screen = CGSize(width: 1280, height: height)
        let (_, open) = render(edge: edge, position: 0.3, screen: screen, scenario: scenario)
        let surface = open.pixel(Int((open.frame.minX + 100) * open.scale), Int((open.frame.minY + 4) * open.scale))
        let lead = HubGeometry.lead, footer = Theme.Metrics.pitch
        let columns = [("inbox", (open.frame.minX + 24)...(open.frame.minX + 380)), ("sessions", (open.frame.minX + 460)...(open.frame.maxX - 24))]
        for (name, x) in columns {
            let gap = edge == .top
                ? open.gapAbove(y: open.frame.maxY - lead - footer - 1, x: x, surface: surface)
                : open.gapBelow(y: open.frame.minY + lead + footer + 1, x: x, surface: surface)
            #expect(gap != nil && gap! <= 60, "\(edge) \(scenario) \(height): \(name) column starts \(gap ?? -1)pt from the footer's hairline")
        }
    }

    private nonisolated static let foldedInboxes = [DockEdge.right, .left].flatMap { edge in [HubSection.ci, .agents].map { (edge, $0) } }

    @Test(arguments: foldedInboxes)
    func theDividerUnderAFoldedInboxDoesNotCrossItsCount(edge: DockEdge, focus: HubSection) {
        let screen = CGSize(width: 1280, height: 800)
        let (_, open) = render(edge: edge, position: 0.3, screen: screen, focus: focus)
        guard let tile = tile(open, edge: edge, screen: screen) else { Issue.record("\(edge): no inbox tile"); return }
        let railSurface = open.pixel(Int(tile.midX * open.scale), Int((tile.maxY + 3) * open.scale))
        let detail = edge == .right ? (open.frame.minX + 200)...(open.frame.maxX - 46 - 40) : (open.frame.minX + 46 + 200)...(open.frame.maxX - 40)
        let bg = open.pixel(Int(detail.lowerBound * open.scale), Int((tile.midY + 30) * open.scale))
        // The hairline under the header, below the tile's own row.
        guard let line = open.hairline(from: tile.midY + 19, to: tile.midY + 120, x: detail, surface: bg) else {
            Issue.record("\(edge) \(focus): no hairline under the inbox"); return
        }
        // The count hangs under the tile: it ends clear above the hairline, and nothing in the rail is drawn across it.
        let column = (tile.midX - 8)...(tile.midX + 8)
        #expect(!open.hasContent(rows: (line - 3)...(line - 1), x: column, surface: railSurface), "\(edge) \(focus): the count touches the hairline at \(line)")
        #expect(!open.hasContent(rows: (line + 1)...(line + 8), x: column, surface: railSurface), "\(edge) \(focus): the count runs past the hairline at \(line)")
    }

    @Test(arguments: [DockEdge.right, .left, .top, .bottom])
    func theViewFitsA720ScreenOnEveryEdge(edge: DockEdge) {
        let screen = CGSize(width: 1280, height: 720)
        // The default bar, and one with twelve sessions: its tiles are cut to the screen, and the gear (its last cell, the
        // controls' anchor) is drawn on it.
        for scenario in [Demo.Scenario.agents, .sessions12] {
            for position in [0.3, 0.9] {
                let (rest, open) = render(edge: edge, position: position, screen: screen, scenario: scenario)
                expectInside(rest.frame, edge: edge, screen: screen, "\(edge) \(scenario) \(position) at rest")
                expectInside(open.frame, edge: edge, screen: screen, "\(edge) \(scenario) \(position) open")
                let end = edge.isHorizontal ? CGRect(x: rest.frame.maxX - 44, y: rest.frame.minY, width: 42, height: rest.frame.height)
                                            : CGRect(x: rest.frame.minX, y: rest.frame.maxY - 44, width: rest.frame.width, height: 42)
                #expect(rest.hasGlyph(in: end), "\(edge) \(scenario) \(position): no gear at the bar's end \(rest.frame)")
            }
        }
    }

    @Test(arguments: [DockEdge.right, .left, .top, .bottom])
    func aPageKeepsTheBarWhereItIs(edge: DockEdge) {
        let screen = CGSize(width: 1280, height: 720)
        let (rest, open) = render(edge: edge, position: 0.5, screen: screen, page: .settings)
        if edge.isHorizontal { #expect(rest.frame.minX == open.frame.minX, "\(edge): \(rest.frame) then \(open.frame)") }
        else { #expect(rest.frame.minY == open.frame.minY, "\(edge): \(rest.frame) then \(open.frame)") }
        expectInside(open.frame, edge: edge, screen: screen, "\(edge) with a page")
    }

    /// A hover panel stays on the screen, whatever it hangs from.
    private nonisolated static let peeks = [DockEdge.right, .left].flatMap { edge in
        [0.7, 0.9].flatMap { position in [HubSection.inbox, .ci, .agents].map { (edge, position, $0) } }
    }

    @Test(arguments: peeks)
    func aPeekFromALowCellStaysOnTheScreen(edge: DockEdge, position: Double, section: HubSection) {
        let screen = CGSize(width: 1280, height: 720)
        // Sessions off, so the CI cell is the last the bar has and the panel has the least room under it.
        let (_, open) = render(edge: edge, position: position, screen: screen, scenario: section == .ci ? .allPassing : .agents, section: section) {
            $0.agents.enabled = section == .agents
        }
        let panel = open.panel
        #expect(panel.height > 0, "\(edge) \(position) \(section): no panel")
        #expect(panel.minY >= HubGeometry.inset - 0.5 && panel.maxY <= screen.height - HubGeometry.inset + 0.5,
                "\(edge) \(position) \(section): the panel is at \(panel) in \(screen)")
    }

    @Test(arguments: [DockEdge.top, .bottom])
    func aFocusedSessionsListFitsWithItsNewSessionRowAndNotice(edge: DockEdge) {
        let screen = CGSize(width: 1280, height: 720)
        let (_, open) = render(edge: edge, position: 0.3, screen: screen, scenario: .sessions12, focus: .agents) { $0.claudeLink = .missing }
        expectInside(open.frame, edge: edge, screen: screen, "\(edge) focused sessions")
        // The list takes what the screen leaves, whole rows to within one of them.
        #expect(open.frame.height > screen.height - 2 * HubGeometry.inset - 70, "\(edge): \(open.frame)")
    }

    @Test(arguments: [DockEdge.right, .left])
    func theSidesListsUseWhatTheScreenLeaves(edge: DockEdge) {
        // Both lists are cut here; each ends on a whole row, so what is left under the hub is less than one.
        let screen = CGSize(width: 1280, height: 720)
        let (_, open) = render(edge: edge, position: 0.3, screen: screen, scenario: .sessions12)
        expectInside(open.frame, edge: edge, screen: screen, "\(edge)")
        let left = screen.height - HubGeometry.inset - open.frame.maxY
        #expect(left >= -0.5 && left < 2 * Theme.Metrics.twoLineRow, "\(edge): \(left)pt unused under \(open.frame)")
    }
}
