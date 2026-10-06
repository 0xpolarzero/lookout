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

/// A header says "1 waiting" or "1 failing" only when its section is nothing but the header (DESIGN.md 10.5): open, the
/// Waiting for you group and the failing rows say it.
@MainActor
@Suite struct HeaderPhrases {
    private func rig() -> (view: LookoutHub, hub: HubState) {
        let store = Store()
        Demo.populate(store, .agents)
        let hub = HubState()
        return (LookoutHub(store: store, ui: UIState(persists: false, edge: .right), hub: hub, maxLength: 700), hub)
    }

    @Test func aPeekAndTheFullViewSayNothingWhileTheirRowsDo() {
        let (view, hub) = rig()
        #expect(view.ciPhrase == nil && view.agentsStatus == nil)
        // A peek.
        hub.section = .agents
        #expect(view.ciPhrase == nil && view.agentsStatus == nil)
        // Kept open: every section shows its rows.
        hub.section = nil
        hub.pinned = true
        #expect(view.ciPhrase == nil && view.agentsStatus == nil)
    }

    @Test func aSectionShrunkToItsHeaderSaysWhatIsInIt() {
        let (view, hub) = rig()
        hub.pinned = true
        hub.focus = .inbox
        #expect(view.ciPhrase?.text == "1 failing")
        #expect(view.agentsStatus?.text == "1 waiting")
        // The focused section is not shrunk: its own rows say it.
        hub.focus = .agents
        #expect(view.agentsStatus == nil)
        #expect(view.ciPhrase?.text == "1 failing")
        hub.focus = .ci
        #expect(view.ciPhrase == nil)
    }

    @Test func aSearchCountsWhatItFoundInsteadOfWhoWaits() {
        let (view, hub) = rig()
        hub.pinned = true
        hub.query = "lcu"
        #expect(view.agentsStatus?.text == "\(view.store.hubSessions(hub).count)")
        #expect(view.ciPhrase == nil)
    }
}

/// What the keys do (DESIGN.md 6.2), one by one, on the demo data: an inbox, CI with a failing and a running repository,
/// and sessions in every state.
@MainActor
@Suite struct KeyMap {
    final class Log {
        var opened: [String] = []
        var refreshes = 0
        var gaveBack = 0
    }

    let store = Store()
    let hub = HubState()
    let keys: HubKeys
    let log = Log()

    init() {
        Demo.populate(store, .agents)
        store.agents.expanded = true
        store.undoStack.announce = { _ in }
        let log = log
        store.interceptOpen = { log.opened.append($0) }
        store.interceptRefresh = { log.refreshes += 1 }
        keys = HubKeys(store: store, ui: UIState(persists: false, edge: .right), hub: hub)
        keys.onClose = { log.gaveBack += 1 }
        hub.pinned = true
    }

    @discardableResult
    func press(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "", in window: NSWindow? = nil) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        return keys.key(event)
    }

    @discardableResult func down() -> Bool { press(kVK_DownArrow, [], "\u{F701}") }
    @discardableResult func up() -> Bool { press(kVK_UpArrow, [], "\u{F700}") }
    @discardableResult func left() -> Bool { press(kVK_LeftArrow, [], "\u{F702}") }
    @discardableResult func right() -> Bool { press(kVK_RightArrow, [], "\u{F703}") }
    @discardableResult func space(_ flags: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) -> Bool { press(kVK_Space, flags, " ", in: window) }
    @discardableResult func esc(in window: NSWindow? = nil) -> Bool { press(kVK_Escape, [], "\u{1b}", in: window) }

    /// Picks `target` as the arrows would have, and says so to the lists.
    func pick(_ target: String) { keys.select(target) }

    var firstItem: String { "i:" + store.list(.needsYou)[0].id }
    var firstSession: String { "a:" + store.hubSessions(hub)[0].id }

    // MARK: Targets

    @Test func theArrowsWalkTheInboxThenCIThenSessionsThenNewSession() {
        let targets = keys.targets()
        // Inbox rows, then CI's, then the sessions, then New session: the ranks never go back.
        let ranks = targets.map { ["i:": 0, "c:": 1, "a:": 2, "s:": 3][String($0.prefix(2))]! }
        #expect(ranks == ranks.sorted() && Set(ranks) == [0, 1, 2, 3])
        #expect(targets.last == "s:new")
        var walked: [String] = []
        for _ in targets { down(); walked.append(hub.selection ?? "") }
        #expect(walked == targets)
        // The end stops: no wrap.
        down()
        #expect(hub.selection == "s:new")
        for _ in targets { up() }
        #expect(hub.selection == targets.first)
    }

    @Test func upFromNothingPicksTheLastRowAndDownTheFirst() {
        hub.selection = nil
        up()
        #expect(hub.selection == "s:new")
        hub.selection = nil
        down()
        #expect(hub.selection == keys.targets().first)
    }

    @Test func aSectionThatCollapsesTakesItsRowsOutOfTheWalk() {
        hub.focus = .agents
        #expect(keys.targets().allSatisfy { $0.hasPrefix("a:") || $0.hasPrefix("s:") })
        hub.focus = .inbox
        #expect(keys.targets().allSatisfy { $0.hasPrefix("i:") })
        hub.focus = .ci
        #expect(keys.targets().allSatisfy { $0.hasPrefix("c:") })
        hub.focus = nil
        // CI folded to its header by the screen's room is no longer drawn: its rows are not targets.
        hub.ciFolded = true
        #expect(!keys.targets().contains { $0.hasPrefix("c:") })
        // A search leaves CI out too, and sessions have no "New session" row while they are results.
        hub.ciFolded = false
        hub.query = "zig"
        #expect(!keys.targets().contains { $0.hasPrefix("c:") } && !keys.targets().contains("s:new"))
    }

    @Test func aPickInASectionThatCollapsesMovesToTheNewSectionsFirstRow() {
        pick(firstItem)
        press(kVK_ANSI_3, .command, "3")
        #expect(hub.focus == .agents && hub.selection == keys.targets().first)
        // And the pick stays put when every section is back.
        let pick = hub.selection
        press(kVK_ANSI_0, .command, "0")
        #expect(hub.focus == nil && hub.selection == pick)
    }

    // MARK: Rows

    @Test func returnOpensWhateverIsPicked() {
        pick(firstItem)
        #expect(press(kVK_Return, [], "\r"))
        #expect(log.opened.last?.hasPrefix("Open on GitHub") == true)
        pick("c:apple/swift-format")
        press(kVK_Return, [], "\r")
        #expect(log.opened.last == "Open checks · apple/swift-format")
        pick(firstSession)
        press(kVK_Return, [], "\r")
        #expect(log.opened.last?.hasPrefix("Open in Claude") == true)
        pick("s:new")
        press(kVK_Return, [], "\r")
        #expect(log.opened.last == "New Claude session in Scratch")
    }

    @Test func returnOnPassingOpensAndClosesItInPlace() {
        pick("c:passing")
        press(kVK_Return, [], "\r")
        #expect(hub.ciPassingOpen)
        press(kVK_Return, [], "\r")
        #expect(!hub.ciPassingOpen)
    }

    @Test func spaceTogglesReadOnAnItemAndASession() {
        let item = store.list(.needsYou)[0]
        pick("i:" + item.id)
        #expect(space())
        #expect(store.items.first { $0.id == item.id }?.state == .read)
        space()
        #expect(store.items.first { $0.id == item.id }?.state == .unread)
        let row = store.hubSessions(hub).first { $0.unread }!
        pick("a:" + row.id)
        space()
        #expect(store.hubSessions(hub).first { $0.id == row.id }?.unread == false)
    }

    @Test func backspaceFinishesTheItemAndPicksTheNextAndCommandZBringsItBack() {
        let items = store.list(.needsYou)
        pick("i:" + items[0].id)
        #expect(press(kVK_Delete, [], "\u{7f}"))
        #expect(!store.list(.needsYou).contains { $0.id == items[0].id })
        #expect(hub.selection == "i:" + items[1].id)
        #expect(press(kVK_ANSI_Z, .command, "z"))
        #expect(store.list(.needsYou).contains { $0.id == items[0].id })
    }

    @Test func backspaceOnDoneRestores() {
        let item = store.list(.needsYou)[0]
        store.done(item)
        hub.filter = .done
        pick("i:" + item.id)
        press(kVK_Delete, [], "\u{7f}")
        #expect(store.list(.needsYou).contains { $0.id == item.id })
    }

    @Test func optionSpaceMarksTheListRead() {
        #expect(store.unreadCount(.needsYou) > 0)
        #expect(space(.option))
        #expect(store.unreadCount(.needsYou) == 0)
    }

    @Test func commandKKeepsAndCommandBackspaceHidesASession() {
        let new = store.agentRows.pending[0]
        pick("a:" + new.id)
        #expect(press(kVK_ANSI_K, .command, "k"))
        #expect(store.agentRows.pending.allSatisfy { $0.id != new.id } && store.agentRows.kept.contains { $0.id == new.id })
        pick("a:" + new.id)
        #expect(press(kVK_Delete, .command, "\u{7f}"))
        #expect(!store.hubSessions(hub).contains { $0.id == new.id })
        #expect(press(kVK_ANSI_Z, .command, "z"))
        #expect(store.hubSessions(hub).contains { $0.id == new.id })
    }

    @Test func optionArrowsMoveASessionAndTheListFollowsIt() {
        let group = store.sessionGroups.first { $0.rows.count > 2 && $0.kind != .newActivity }!
        let second = group.rows[1].id
        pick("a:" + second)
        #expect(press(kVK_UpArrow, .option, "\u{F700}"))
        #expect(store.sessionGroups.first { $0.id == group.id }!.rows[0].id == second)
        #expect(hub.selection == "a:" + second)
        press(kVK_DownArrow, .option, "\u{F701}")
        #expect(store.sessionGroups.first { $0.id == group.id }!.rows[1].id == second)
    }

    // MARK: Chords

    @Test func commandRChecksNowAndCommandCommaOpensSettings() {
        #expect(press(kVK_ANSI_R, .command, "r"))
        #expect(log.refreshes == 1)
        #expect(press(kVK_ANSI_Comma, .command, ","))
        #expect(hub.page == .settings)
        // From a page too.
        #expect(press(kVK_ANSI_R, .command, "r"))
        #expect(log.refreshes == 2)
    }

    @Test func commandFStartsTheSearchAndTypingDoes() {
        #expect(press(kVK_ANSI_F, .command, "f"))
        #expect(hub.inbox.searchOpen)
        hub.inbox.endSearch()
        #expect(press(kVK_ANSI_Z, [], "z"))
        #expect(hub.query == "z" && hub.inbox.searchOpen)
        // The first result is picked, so Return opens it.
        #expect(hub.selection != nil)
    }

    @Test func spaceIsNotTypedBeforeThereIsAQuery() {
        pick(firstItem)
        space()
        #expect(hub.query.isEmpty)
    }

    @Test func theFocusKeysGoByPositionSoAnAzertyKeyboardHasThem() {
        // On AZERTY ⌘1 sends "&" as its character: the key code is what counts.
        press(kVK_ANSI_1, .command, "&")
        #expect(hub.focus == .inbox)
        press(kVK_ANSI_2, .command, "é")
        #expect(hub.focus == .ci)
        press(kVK_ANSI_3, .command, "\"")
        #expect(hub.focus == .agents)
        // The same again gives the room back, and so does ⌘0.
        press(kVK_ANSI_3, .command, "\"")
        #expect(hub.focus == nil)
        press(kVK_ANSI_2, .command, "é")
        press(kVK_ANSI_0, .command, "à")
        #expect(hub.focus == nil)
    }

    // MARK: ← and →

    @Test func theArrowsSwitchTheInboxTabsAndStopAtTheEnds() {
        #expect(hub.filter == .needsYou)
        #expect(right() && hub.filter == .bots)
        #expect(right() && hub.filter == .done)
        #expect(right() && hub.filter == .done)
        #expect(left() && hub.filter == .bots)
        #expect(left() && left() && hub.filter == .needsYou)
    }

    @Test func aPickInTheInboxGoesWithItsTabButOneElsewhereStays() {
        pick(firstItem)
        right()
        #expect(hub.selection == nil)
        hub.filter = .needsYou
        pick(firstSession)
        right()
        #expect(hub.filter == .bots && hub.selection == firstSession)
    }

    @Test func theArrowsKeepTheirOwnMeaningOnPassingAndNewSession() {
        pick("c:passing")
        right()
        #expect(hub.ciPassingOpen && hub.filter == .needsYou)
        left()
        #expect(!hub.ciPassingOpen && hub.selection == "c:passing")
        pick("s:new")
        let asked = hub.projectsMenuRequest
        right()
        #expect(hub.projectsMenuRequest == asked + 1 && hub.filter == .needsYou)
    }

    @Test func theArrowsLeaveTheTabsAloneWhileThereIsAQuery() {
        hub.query = "zig"
        #expect(!right() && hub.filter == .needsYou)
    }

    @Test func theArrowsSwitchTheSettingsPane() {
        hub.go(.settings)
        #expect(hub.settingsPane == .general)
        #expect(right() && hub.settingsPane == .notifications)
        right(); right()
        #expect(hub.settingsPane == SettingsPane.allCases.last)
        right()
        #expect(hub.settingsPane == SettingsPane.allCases.last)
        left()
        #expect(hub.settingsPane == SettingsPane.allCases[SettingsPane.allCases.count - 2])
    }

    // MARK: Esc

    @Test func escapeStepsBackOneThingAtATimeAndTheFirstMatchWins() {
        hub.beginSearch()
        hub.query = "lcu"
        // ⌘3 while searching: Sessions has the room, the results stay.
        press(kVK_ANSI_3, .command, "3")
        #expect(hub.focus == .agents)
        // 1. The query (and the field).
        esc()
        #expect(hub.query.isEmpty && !hub.inbox.searchOpen && hub.focus == .agents && hub.pinned)
        // 2. The section focus.
        esc()
        #expect(hub.focus == nil && hub.pinned && log.gaveBack == 0)
        // 3. The hub, with the keyboard handed back.
        esc()
        #expect(!hub.pinned && log.gaveBack == 1)
    }

    @Test func escapeLeavesAPageBeforeTheFocusAndTheFocusBeforeTheHub() {
        hub.focus = .ci
        hub.go(.settings)
        esc()
        #expect(hub.page == .main && hub.focus == .ci && hub.pinned)
        esc()
        #expect(hub.focus == nil && hub.pinned)
        esc()
        #expect(!hub.pinned)
    }

    @Test func escapeFromRepositoriesOpenedFromSettingsGoesBackToSettings() {
        hub.go(.settings)
        hub.go(.repos)
        esc()
        #expect(hub.page == .settings)
        esc()
        #expect(hub.page == .main)
    }

    @Test func aQueryLeftBehindAPageIsNotTheNextStep() {
        hub.query = "zig"
        hub.go(.settings)
        esc()
        #expect(hub.page == .main && hub.query == "zig")
        esc()
        #expect(hub.query.isEmpty)
    }

    @Test func somethingOpenInAFieldTakesEscapeBeforeAnyOfIt() {
        hub.focus = .agents
        var closed = 0
        let id = UUID()
        EscapeRoute.register(id) { closed += 1 }
        defer { EscapeRoute.unregister(id) }
        #expect(esc())
        #expect(closed == 1 && hub.focus == .agents && hub.pinned)
        EscapeRoute.unregister(id)
        esc()
        #expect(hub.focus == nil)
    }

    // MARK: Controls and fields

    @Test func aControlTheTabRingIsOnKeepsSpaceAndReturn() {
        pick(firstItem)
        let item = store.list(.needsYou)[0]
        let control = UUID()
        hub.controls.set(control, focused: true)
        #expect(!space() && !press(kVK_Return, [], "\r"))
        #expect(store.items.first { $0.id == item.id }?.state == .unread && log.opened.isEmpty)
        // The arrows and the chords are not the control's.
        #expect(down())
        #expect(press(kVK_ANSI_R, .command, "r"))
        hub.controls.set(control, focused: false)
        #expect(space())
    }

    /// A window with a text field being edited, as the search field is: its field editor is the first responder.
    private func editingWindow(_ text: String = "") -> (window: NSWindow, field: NSTextField) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        field.stringValue = text
        window.contentView?.addSubview(field)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        window.makeFirstResponder(field)
        return (window, field)
    }

    @Test func aTextFieldKeepsWhatItTypesAndTheHubKeepsItsChords() {
        let (window, _) = editingWindow()
        defer { window.close() }
        pick(firstItem)
        let item = store.list(.needsYou)[0]
        #expect(window.firstResponder is NSText)
        // Typing, Space, ⌫ and the arrows are the field's.
        #expect(!press(kVK_ANSI_A, [], "a", in: window))
        #expect(!space(in: window) && !press(kVK_Delete, [], "\u{7f}", in: window) && !press(kVK_LeftArrow, [], "\u{F702}", in: window))
        #expect(store.items.first { $0.id == item.id }?.state == .unread && hub.query.isEmpty && hub.filter == .needsYou)
        // ⌘Z is the field's undo.
        #expect(!press(kVK_ANSI_Z, .command, "z", in: window))
        // But Check now, Settings and the focus keys are not text.
        #expect(press(kVK_ANSI_R, .command, "r", in: window) && log.refreshes == 1)
        #expect(press(kVK_ANSI_1, .command, "&", in: window) && hub.focus == .inbox)
        #expect(press(kVK_ANSI_Comma, .command, ",", in: window) && hub.page == .settings)
    }

    @Test func aCheckNowBoundToAPlainKeyIsTypedInAFieldNotRun() {
        store.setShortcut(Shortcut(keyCode: UInt16(kVK_ANSI_R)), for: .refresh)
        let (window, _) = editingWindow()
        defer { window.close() }
        #expect(!press(kVK_ANSI_R, [], "r", in: window) && log.refreshes == 0)
    }

    @Test func escapeInAFieldLeavesTheFieldFirst() {
        let (window, field) = editingWindow()
        defer { window.close() }
        hub.focus = .agents
        #expect(esc(in: window))
        #expect(window.firstResponder !== field.currentEditor() && hub.focus == .agents && hub.pinned)
    }

    @Test func aKeyDuringCompositionIsTheInputMethods() {
        let (window, field) = editingWindow()
        defer { window.close() }
        let editor = field.currentEditor() as! NSTextView
        editor.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.hasMarkedText())
        hub.focus = .agents
        pick(firstSession)
        // Esc cancels the composition, Return commits it, the arrows pick a candidate: none is the hub's.
        #expect(!esc(in: window) && !press(kVK_Return, [], "\r", in: window) && !press(kVK_DownArrow, [], "\u{F701}", in: window))
        #expect(hub.focus == .agents && hub.pinned && log.opened.isEmpty)
    }

    @Test func theSearchFieldHasTheArrowsAndReturnAndKeepsSpaceForItself() {
        let (window, _) = editingWindow("zig")
        defer { window.close() }
        hub.query = "zig"
        hub.inbox.searchOpen = true
        hub.inbox.searchFocused = true
        let first = keys.targets().first!
        keys.select(first)
        // ↓ walks the results, ↩ opens the pick.
        #expect(press(kVK_DownArrow, [], "\u{F701}", in: window))
        #expect(hub.selection != first)
        #expect(press(kVK_Return, [], "\r", in: window))
        #expect(log.opened.count == 1)
        // Space is typed, ⌫ edits.
        #expect(!space(in: window) && !press(kVK_Delete, [], "\u{7f}", in: window))
        // Esc clears the search and leaves the field in one step.
        #expect(esc(in: window))
        #expect(hub.query.isEmpty && !hub.inbox.searchOpen)
    }

    // MARK: Menus

    @Test func theKeysDoNothingWhileNothingIsKept() {
        hub.pinned = false
        #expect(!down() && !space() && !press(kVK_Return, [], "\r"))
    }

    @Test func thePointerLeavingARowStopsTheKeysActingOnIt() {
        // A key never acts on a row the pointer left (DESIGN.md 3.5): the row clears its own pick.
        hub.pointer(true, over: "c:b/bad", ui: UIState(persists: false, edge: .right))
        hub.pointer(false, over: "c:b/bad", ui: UIState(persists: false, edge: .right))
        #expect(hub.selection == nil)
    }
}
