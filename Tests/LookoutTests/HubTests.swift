import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@Suite struct CappedScrollFit {
    @Test func stopsOnTheLastRowThatFits() {
        #expect(CappedScrollSpace.fit(cap: 100, edges: [36, 72, 108, 144]) == 72)
        #expect(CappedScrollSpace.fit(cap: 108, edges: [36, 72, 108, 144]) == 108)
        // Rows measured only up to the cap: the cut is unmeasured, so the cap stands.
        #expect(CappedScrollSpace.fit(cap: 300, edges: [43, 87]) == 300)
    }

    @Test func theCueCountsTheRowsBelowTheViewport() {
        let edges: [CGFloat] = [44, 88, 132, 176, 220, 264, 308]
        // Three whole rows showing: four end below.
        #expect(CappedScrollSpace.rowsBelow(edges: edges, offset: 0, viewport: 132) == 4)
        // Scrolled to row three's top, the viewport reaches row five's bottom.
        #expect(CappedScrollSpace.rowsBelow(edges: edges, offset: 88, viewport: 132) == 2)
        #expect(CappedScrollSpace.rowsBelow(edges: edges, offset: 176, viewport: 132) == 0)
    }

    @Test func theCueScrollsToTheLastRowOfTheNextPage() {
        let edges: [CGFloat] = [44, 88, 132, 176, 220, 264, 308]
        // From the top, one more page of 132 ends on row six (264); the next row if none fits whole.
        #expect(CappedScrollSpace.nextPage(edges: edges, offset: 0, viewport: 132) == 5)
        #expect(CappedScrollSpace.nextPage(edges: edges, offset: 88, viewport: 132) == 6)
        #expect(CappedScrollSpace.nextPage(edges: edges, offset: 0, viewport: 20) == 0)
        #expect(CappedScrollSpace.nextPage(edges: edges, offset: 176, viewport: 132) == nil)
    }

    @Test func fallsBackToTheCap() {
        #expect(CappedScrollSpace.fit(cap: 20, edges: [36, 72]) == 20)
        #expect(CappedScrollSpace.fit(cap: 100, edges: []) == 100)
    }

    @Test func lazyFitSnapsToWholeRows() {
        // Realized rows all end within the cap: the rest repeat the pitch (here 41 with spacing).
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 294, edges: [48, 89, 130, 171, 212]) == 294)
        #expect(CappedScrollSpace.fitLazy(cap: 100, edges: [48, 89, 130]) == 89)
        // Rows of different heights can't be extrapolated: the cap stands.
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [30, 70, 110, 140, 180]) == 300)
        // Never below the first row; no pitch with one edge.
        #expect(CappedScrollSpace.fitLazy(cap: 30, edges: [48, 89]) == 30)
        #expect(CappedScrollSpace.fitLazy(cap: 300, edges: [48]) == 300)
    }
}

@MainActor
@Suite struct CappedScrollHosted {
    @Observable final class Count { var n: Int; init(_ n: Int) { self.n = n } }

    private struct Changing: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(count.n)) {
                AdaptiveStack(count: count.n, spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func rowCountChangesResizeTheList() {
        let count = Count(3)
        let hosting = NSHostingView(rootView: Changing(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        func settle() -> CGFloat {
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            return hosting.fittingSize.height
        }
        #expect(abs(settle() - 120) < 1)
        count.n = 100
        let grown = settle()
        #expect(grown >= 280 && grown <= 300, "grown: \(grown)")
        count.n = 2
        #expect(abs(settle() - 80) < 1)
        window.contentView = nil
        window.orderOut(nil)
    }

    private func height<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        let h = hosting.fittingSize.height
        window.contentView = nil
        window.orderOut(nil)
        return h
    }

    private func rows(_ n: Int) -> some View {
        ForEach(0..<n, id: \.self) { i in Text("row \(i)").frame(height: 40).frame(maxWidth: .infinity).capEdge() }
    }

    @Test func shortListIsAsTallAsItsContent() {
        #expect(abs(height(of: CappedScroll(cap: 300) { VStack(spacing: 0) { rows(3) } }) - 120) < 1)
    }

    @Test func overflowingListsFillTheCapWhateverTheStack() {
        for n in [8, 61, 200] {
            let eager = height(of: CappedScroll(cap: 300, lazy: AdaptiveStack<EmptyView>.isLazy(n)) { AdaptiveStack(count: n) { rows(n) } })
            #expect(eager >= 280 && eager <= 300, "adaptive \(n): \(eager)")
            let lazy = height(of: CappedScroll(cap: 300, lazy: true) { LazyVStack(spacing: 0) { rows(n) } })
            #expect(lazy >= 280 && lazy <= 300, "lazy \(n): \(lazy)")
            let grid = height(of: CappedScroll(cap: 300, lazy: true) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) { rows(n * 2) }
            })
            #expect(grid >= 280 && grid <= 300, "grid \(n): \(grid)")
        }
    }

    private struct LazyRows: View {
        let count: Count
        let grid: Bool
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                if grid {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
                        ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 41).frame(maxWidth: .infinity).capEdge() }
                    }.padding(.vertical, 8)
                } else {
                    AdaptiveStack(count: count.n, spacing: 1) {
                        ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 41).frame(maxWidth: .infinity).capEdge() }
                    }.padding(.vertical, 8)
                }
            }
        }
    }

    /// Hosts the list, settles it, and returns its height after each row-count change.
    private func heights(grid: Bool, counts: [Int]) -> [CGFloat] {
        let count = Count(counts[0])
        let hosting = NSHostingView(rootView: LazyRows(count: count, grid: grid).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in counts {
            count.n = n
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            out.append(hosting.fittingSize.height)
        }
        window.contentView = nil
        window.orderOut(nil)
        return out
    }

    /// Whole rows: 8 of padding at the top, then rows of 41 with 1 of spacing between them.
    private func onRowBoundary(_ h: CGFloat) -> Bool {
        let rowsHigh = (h - 8 + 1) / 42
        return abs(rowsHigh - rowsHigh.rounded()) < 0.03 && rowsHigh.rounded() >= 1
    }

    @Test func lazyListEndsOnAWholeRow() {
        let h = heights(grid: false, counts: [200])[0]
        #expect(h <= 300.5 && h >= 250 && onRowBoundary(h), "lazy: \(h)")
    }

    @Test func lazyGridEndsOnAWholeGridRow() {
        let h = heights(grid: true, counts: [400])[0]
        #expect(h <= 300.5 && h >= 250 && onRowBoundary(h), "grid: \(h)")
    }

    @Test func lazyListsResizeAcrossRowCountChanges() {
        for grid in [false, true] {
            let r = heights(grid: grid, counts: [3, 400, 2])
            let per = grid ? 2 : 1
            let short = { (n: Int) in 16 + CGFloat((n + per - 1) / per) * 42 - 1 }
            #expect(abs(r[0] - short(3)) < 1.5, "grid \(grid) 3: \(r)")
            #expect(r[1] <= 300.5 && r[1] >= 250 && onRowBoundary(r[1]), "grid \(grid) 400: \(r)")
            #expect(abs(r[2] - short(2)) < 1.5, "grid \(grid) 2: \(r)")
        }
    }

    @Test func lazyListsShrinkFromOverflowToShort() {
        for grid in [false, true] {
            let r = heights(grid: grid, counts: [400, 4])
            let rows = grid ? 2 : 4
            #expect(abs(r[1] - (16 + CGFloat(rows) * 42 - 1)) < 1.5, "grid \(grid): \(r)")
        }
    }

    private struct VariableRows: View {
        let count: Count
        var body: some View {
            CappedScroll(cap: 300, lazy: true) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<count.n, id: \.self) { i in Text("row \(i)").frame(height: 30 + CGFloat(i % 3) * 10).frame(maxWidth: .infinity).capEdge() }
                }
            }
        }
    }

    @Test func variableRowHeightsStillRegrow() {
        let count = Count(200)
        let hosting = NSHostingView(rootView: VariableRows(count: count).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        var out: [CGFloat] = []
        for n in [200, 3, 200] {
            count.n = n
            for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
            out.append(hosting.fittingSize.height)
        }
        window.contentView = nil
        window.orderOut(nil)
        #expect(abs(out[1] - 120) < 1.5, "\(out)")
        // Cut at a measured row edge (not through a row), and regrown to the same height.
        #expect(out[0] >= 260 && out[0] <= 300.5 && abs(out[2] - out[0]) < 1.5, "\(out)")
    }
}

/// What the keys act on while a section has the room (DESIGN.md 6.2): only rows that are showing.
@MainActor
@Suite struct SectionFocusKeys {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys
    private let box = Box()

    final class Box { var opened: [String] = [] }

    init() {
        Demo.populate(store, .agents)
        store.agents.expanded = true
        let ui = UIState(persists: false, edge: .right)
        keys = HubKeys(store: store, ui: ui, hub: hub)
        let box = box
        store.interceptOpen = { box.opened.append($0) }
        hub.pinned = true
    }

    @discardableResult
    private func press(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: UInt16(code))!
        return keys.key(event)
    }

    private func focus(_ number: Int) { press([1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 0: kVK_ANSI_0][number]!, .command, "\(number)") }
    private func down() { press(kVK_DownArrow, [], "\u{F701}") }
    private func up() { press(kVK_UpArrow, [], "\u{F700}") }
    private func enter() -> Bool { press(kVK_Return, [], "\r") }

    @Test func downAfterFocusingTheSessionsPicksASession() {
        focus(3)
        down()
        #expect(hub.selection?.hasPrefix("a:") == true, "\(hub.selection ?? "nothing")")
        #expect(enter())
        #expect(box.opened.last?.hasPrefix("Open in Claude") == true, "\(box.opened)")
    }

    @Test func focusingMovesAHiddenPickIntoTheSection() {
        let item = store.list(.needsYou)[0]
        hub.selection = "i:" + item.id
        focus(3)
        #expect(hub.selection?.hasPrefix("a:") == true, "\(hub.selection ?? "nothing")")
        enter()
        #expect(box.opened.allSatisfy { !$0.hasPrefix("Open on GitHub") }, "\(box.opened)")
        // And back to every section: the pick stays where it is.
        let pick = hub.selection
        focus(0)
        #expect(hub.selection == pick)
    }

    @Test func aHiddenPickIsNotActionable() {
        hub.focus = .agents
        hub.selection = "i:" + store.list(.needsYou)[0].id
        #expect(!enter())
        #expect(box.opened.isEmpty)
        #expect(!press(kVK_Space, [], " "))
    }

    @Test func theArrowsStayInsideTheFocusedSection() {
        focus(1)
        for _ in 0..<40 { down() }
        #expect(hub.selection?.hasPrefix("i:") == true, "\(hub.selection ?? "nothing")")
        focus(3)
        for _ in 0..<40 { up() }
        #expect(hub.selection?.hasPrefix("a:") == true, "\(hub.selection ?? "nothing")")
        // CI's rows are its own to pick, and no other section's.
        focus(2)
        down()
        #expect(hub.selection?.hasPrefix("c:") == true, "\(hub.selection ?? "nothing")")
    }

    @Test func markAllReadNeedsTheInboxToShow() {
        let before = store.unreadCount(.needsYou)
        focus(3)
        press(kVK_Space, .option, " ")
        #expect(store.unreadCount(.needsYou) == before)
    }
}

/// The controls menu asked for by VoiceOver or a key: it has the keyboard and walks like NSMenu (DESIGN.md 4.7).
@MainActor
@Suite struct ControlsMenuKeys {
    private let store = Store()
    private let hub = HubState()
    private let keys: HubKeys

    init() {
        Demo.populate(store, .agents)
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
    }

    @discardableResult
    private func press(_ code: Int, _ chars: String = "") -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                     keyCode: UInt16(code))!
        return keys.key(event)
    }

    @Test func showingControlsPicksTheFirstRow() {
        hub.showControls()
        #expect(hub.section == .controls && hub.menuKeys && hub.menuPick == .keepOpen)
    }

    @Test func theArrowsWalkTheRowsRound() {
        hub.showControls()
        #expect(press(kVK_DownArrow, "\u{F701}"))
        #expect(hub.menuPick == .repositories)
        press(kVK_DownArrow); press(kVK_DownArrow)
        #expect(hub.menuPick == .sync)
        press(kVK_DownArrow)
        #expect(hub.menuPick == .keepOpen)
        press(kVK_UpArrow)
        #expect(hub.menuPick == .sync)
    }

    @Test func signInTroubleLeavesNoSyncRow() {
        store.authError = "Bad credentials"
        #expect(ControlsRow.listed(store) == [.keepOpen, .repositories, .settings])
        hub.showControls()
        for _ in 0..<3 { press(kVK_DownArrow) }
        #expect(hub.menuPick == .keepOpen)
    }

    @Test func returnDoesTheRowAndLeavesTheMenu() {
        hub.showControls()
        press(kVK_DownArrow)
        #expect(press(kVK_Return, "\r"))
        #expect(hub.page == .repos && hub.pinned)
        #expect(!hub.menuKeys)
    }

    @Test func escapeClosesTheMenuAndGivesTheKeyboardBack() {
        var gaveBack = false
        keys.onClose = { gaveBack = true }
        hub.showControls()
        #expect(press(kVK_Escape, "\u{1b}"))
        #expect(hub.section == nil && !hub.menuKeys && gaveBack)
        #expect(!hub.pinned)
    }

    @Test func thePointerLeavingDoesNotCloseTheMenuTheKeysHave() {
        hub.showControls()
        #expect(!hub.closePeek())
        #expect(hub.section == .controls && hub.menuKeys)
        // A panel the pointer opened closes as it always did.
        press(kVK_Escape, "\u{1b}")
        hub.section = .inbox
        #expect(hub.closePeek() && hub.section == nil)
    }

    @Test func thePointerOnAnotherSectionLeavesTheMenuTheKeysHave() {
        hub.showControls()
        hub.enter(.inbox)
        hub.enter(.agents)
        #expect(hub.section == .controls && hub.menuKeys)
        // Once it is closed, hovering works as it always did.
        press(kVK_Escape, "\u{1b}")
        hub.section = .ci
        hub.enter(.inbox)
        #expect(hub.section == .inbox)
    }

    @Test func aFocusedControlKeepsReturnAndSpaceForItself() {
        hub.showControls()
        let control = UUID()
        hub.controls.set(control, focused: true)
        #expect(!press(kVK_Return, "\r"))
        #expect(!press(kVK_Space, " "))
        // The menu's own highlight did nothing, and keeps the keys for when the control lets go.
        #expect(!hub.pinned && hub.menuKeys)
        // The arrows are not the control's.
        #expect(press(kVK_DownArrow, "\u{F701}") && hub.menuPick == .repositories)
        hub.controls.set(control, focused: false)
        #expect(press(kVK_Return, "\r"))
        #expect(hub.page == .repos)
    }

    @Test func aMenuThatIsNotUpLeavesTheKeysAlone() {
        #expect(!press(kVK_DownArrow, "\u{F701}"))
        #expect(!press(kVK_Return, "\r"))
    }
}

/// A panel's list cut to whole rows with a "+N more" row under it (DESIGN.md 5.2): the contract every peek section
/// (inbox, CI, sessions) goes through.
@MainActor
@Suite struct PeekWholeRows {
    private func height(total: Int, cap: CGFloat) -> CGFloat {
        let rows = WholeRows(total: total, cap: cap, noun: "row", onMore: {}) {
            VStack(spacing: 0) {
                ForEach(0..<min(total, WholeRows<EmptyView>.instantiated(cap)), id: \.self) { i in
                    Text("row \(i)").frame(height: 44).frame(maxWidth: .infinity).capEdge()
                }
            }
        }
        let hosting = NSHostingView(rootView: rows.frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded() }
        let h = hosting.fittingSize.height
        window.contentView = nil
        window.orderOut(nil)
        return h
    }

    @Test func noRowsReserveNoRoom() {
        #expect(height(total: 0, cap: 300) == 0)
    }

    @Test func everythingThatFitsShowsWithoutAMoreRow() {
        #expect(abs(height(total: 3, cap: 150) - 132) < 1)
    }

    @Test func aCutListEndsOnAWholeRowAndAddsTheMoreRow() {
        // 150 less the more row's 36 leaves room for two whole rows.
        #expect(abs(height(total: 8, cap: 150) - (2 * 44 + Theme.Metrics.pitch)) < 1)
        #expect(abs(height(total: 40, cap: 150) - (2 * 44 + Theme.Metrics.pitch)) < 1)
    }
}
