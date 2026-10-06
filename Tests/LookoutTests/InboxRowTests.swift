import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

/// Eighteen items, a minute apart, the newest first.
private func eighteenItems() -> [InboxItem] {
    (0..<18).map { i in inboxItem("\(i)", kind: .issueOpened, number: i, title: "Item \(i)", at: Date().addingTimeInterval(-Double(i) * 60)) }
}

@MainActor
@Suite struct InboxRowHeight {
    private func item(_ state: ItemState, kind: EventKind = .issueComment, author: String = "someone", title: String = "A title") -> InboxItem {
        inboxItem(repo: "apple/swift-format", kind: kind, number: 1042, title: title, author: author, state: state)
    }

    /// The height a row settles at in a column `width` wide.
    private func height(of item: InboxItem, filter: InboxFilter = .needsYou, query: String = "", width: CGFloat = 400) -> CGFloat {
        let store = Store.unsaved()
        let hub = HubState()
        hub.filter = filter
        hub.query = query
        let row = InboxRow(item: item, store: store, ui: UIState(), hub: hub).frame(width: width)
        let hosting = NSHostingView(rootView: row)
        let window = NSWindow.offscreen(hosting, size: CGSize(width: width, height: 400))
        defer { window.dismiss() }
        hosting.settle(turns: 4, interval: 0.03)
        return hosting.fittingSize.height
    }

    @Test func everyKindOfRowIsExactlyTheSameHeight() {
        let rows: [(String, CGFloat)] = [
            ("unread", height(of: item(.unread))),
            ("read", height(of: item(.read))),
            ("bot", height(of: item(.unread, author: "coderabbitai[bot]"))),
            ("done", height(of: item(.discarded), filter: .done)),
            ("addressed", height(of: item(.addressed), filter: .done)),
            ("resolved", height(of: item(.resolved, kind: .reviewComment), filter: .done)),
            ("done in search", height(of: item(.discarded), filter: .done, query: "a")),
            ("addressed in needs you", height(of: item(.addressed, kind: .reviewRequested))),
            ("long title", height(of: item(.unread, title: String(repeating: "Respect trailing comma ", count: 8)))),
            ("narrow", height(of: item(.addressed, author: "jessesquires"), filter: .done, width: 240)),
        ]
        for (name, h) in rows { #expect(abs(h - Theme.Metrics.twoLineRow) < 0.5, "\(name): \(h)") }
    }
}

@MainActor
@Suite struct InboxRowAges {
    /// Where, in points from the row's leading edge, the rightmost thing a row at rest draws ends: its age.
    private func ageEnd(title: String, width: CGFloat = 560) -> CGFloat {
        let store = Store.unsaved()
        let hub = HubState()
        let item = inboxItem(repo: "apple/swift-format", number: 1042, title: title, author: "someone", at: Date().addingTimeInterval(-18 * 60))
        let hosting = NSHostingView(rootView: InboxRow(item: item, store: store, ui: UIState(), hub: hub).frame(width: width))
        let window = NSWindow.offscreen(hosting, size: CGSize(width: width, height: 100))
        defer { window.dismiss() }
        hosting.settle(turns: 6, interval: 0.03)
        hosting.frame.size = hosting.fittingSize
        let rep = PlaygroundShots.bitmap(of: window)!
        var edge = 0
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) where (0..<rep.pixelsHigh).contains(where: { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.3 }) {
            edge = x
            break
        }
        return CGFloat(edge) * hosting.bounds.width / CGFloat(rep.pixelsWide)
    }

    @Test func aWideRowAndOneThatFellBackToTwoLinesEndTheirAgeInOneColumn() {
        // 560 wide: a short title keeps one line, a long one goes back to the two-line stack (DESIGN 5.4).
        let wide = ageEnd(title: "Short title")
        let stacked = ageEnd(title: String(repeating: "A very long title that cannot share its line ", count: 3))
        #expect(wide > 400 && stacked > 400)
        #expect(abs(wide - stacked) < 0.75, "wide \(wide), stacked \(stacked)")
    }
}

@MainActor
@Suite struct InboxListWindow {
    private let pitch = InboxList.pitch

    @Test func rowsFitWholeAndTheListIsCutOnlyPastThem() {
        #expect(pitch == 45)
        // Five rows are 224 pt (a point between each).
        #expect(InboxList.rowsFitting(224) == 5)
        #expect(InboxList.rowsFitting(223) == 4)
        #expect(InboxList.rowsFitting(10) == 1)
        #expect(!InboxList.isCut(count: 5, cap: 224))
        #expect(InboxList.isCut(count: 6, cap: 224))
    }

    @Test func theCountBelowFollowsTheScroll() {
        // 18 rows, 4 showing: 14 below at the top, fewer as the list scrolls, none at the end.
        #expect(InboxList.hiddenBelow(count: 18, offset: 0, rows: 4) == 14)
        #expect(InboxList.hiddenBelow(count: 18, offset: pitch, rows: 4) == 13)
        // Part way through a row: it is not wholly shown yet.
        #expect(InboxList.hiddenBelow(count: 18, offset: pitch + 20, rows: 4) == 13)
        let end = 18 * pitch - 1 - (4 * pitch - 1)
        #expect(InboxList.hiddenBelow(count: 18, offset: end, rows: 4) == 0)
        #expect(InboxList.hiddenBelow(count: 18, offset: -30, rows: 4) == 14)
    }
}

@MainActor
@Suite struct InboxListHosted {
    @Test func aListCutShortCountsTheRowsBelow() {
        let store = Store.unsaved()
        store.items = eighteenItems()
        let hub = HubState()
        let items = store.list(.needsYou)
        let list = InboxList(items: items, cap: 224, listKey: .init(revision: 0, filter: .needsYou, query: ""), scopeID: "needsYou",
                             store: store, ui: UIState(), hub: hub)
            .frame(width: 400)
        let hosting = NSHostingView(rootView: list)
        let window = NSWindow.offscreen(hosting, size: CGSize(width: 400, height: 400))
        defer { window.dismiss() }
        hosting.settle(turns: 10, display: true)
        // 224 less the line is 4 rows: 14 below (as the list scrolls the count follows: see `theCountBelowFollowsTheScroll`).
        #expect(hub.inbox.hiddenBelow == 14)
        // Four whole rows and the line, never past the cap.
        #expect(abs(hosting.fittingSize.height - (4 * InboxList.pitch - 1 + InboxList.moreHeight)) < 1)
    }
}

@MainActor
@Suite struct InboxBodyBudget {
    /// The body of an inbox with many rows, a banner and an undo line, in a column 400 wide given `cap` to stay within.
    private func height(cap: CGFloat, banner: Bool, undo: Bool) -> CGFloat {
        let store = Store.unsaved()
        store.undoStack.announce = { _ in }
        store.repos = [RepoConfig(fullName: "a/b")]
        store.lastSync = Date()
        store.items = eighteenItems()
        if banner { store.repoErrors = ["a/b": "Forbidden"] }
        if undo { store.done(store.items[0]) }
        let hub = HubState()
        let view = LookoutHub(store: store, ui: UIState(), hub: hub, maxLength: 700).inboxBody(cap: cap).frame(width: 400)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow.offscreen(hosting, size: CGSize(width: 400, height: 900))
        defer { window.dismiss() }
        hosting.settle(turns: 10, display: true)
        return hosting.fittingSize.height
    }

    @Test func theBannerAndTheUndoLineComeOutOfTheListsRoom() {
        let cap: CGFloat = 330
        for (banner, undo) in [(false, false), (true, false), (false, true), (true, true)] {
            let h = height(cap: cap, banner: banner, undo: undo)
            #expect(h <= cap + 0.5, "banner \(banner), undo \(undo): \(h)")
        }
        // The list is not shrunk past what the extras take: it still fills whole rows of what is left.
        #expect(height(cap: cap, banner: true, undo: true) > cap - InboxList.pitch)
    }
}

@MainActor
@Suite struct InboxRowActionRoom {
    private func item() -> InboxItem {
        inboxItem(repo: "apple/swift-format", kind: .reviewComment, number: 1042, title: "Respect trailing comma",
                  author: "coderabbitai[bot]", authorIsApp: true, state: .resolved)
    }

    /// How far right line 2's text reaches (in points), with the row at rest or picked (its action showing).
    private func reach(picked: Bool, width: CGFloat) -> CGFloat {
        let store = Store.unsaved()
        let hub = HubState()
        hub.filter = .done
        if picked { hub.selection = "i:1" }
        let hosting = NSHostingView(rootView: InboxRow(item: item(), store: store, ui: UIState(), hub: hub).frame(width: width, height: 44)
            .background(Theme.bg).environment(\.colorScheme, .dark))
        let window = NSWindow.offscreen(hosting, size: CGSize(width: width, height: 44))
        defer { window.dismiss() }
        hosting.settle(turns: 6, interval: 0.04, display: true)
        let rep = PlaygroundShots.bitmap(of: window)!
        let scale = CGFloat(rep.pixelsWide) / width
        var right = 0
        // Line 2 is the lower half's text; the pick's accent bar is on the left, the action (when shown) on the right.
        for y in Int(26 * scale)..<Int(36 * scale) {
            for x in Int(16 * scale)..<Int((width - Theme.Metrics.rowPadding - (picked ? Theme.Metrics.iconButton : 0)) * scale)
            where (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.5 { right = max(right, x) }
        }
        return CGFloat(right) / scale
    }

    @Test func theMetaLineStopsBeforeTheActionsRoomAndReadsTheSameWithOrWithoutIt() {
        // Narrow enough that the line is cut: what it keeps must not depend on the action appearing. Picked,
        // only what lies left of the action's own 24 pt is measured.
        for width in [260, 300, 400] as [CGFloat] {
            let rest = reach(picked: false, width: width)
            let picked = reach(picked: true, width: width)
            #expect(rest > 100, "width \(width): nothing drawn")
            #expect(abs(rest - picked) < 1, "width \(width): \(rest) at rest, \(picked) picked")
            // At rest too, nothing is drawn where the action will be.
            #expect(rest <= width - Theme.Metrics.rowPadding - Theme.Metrics.iconButton, "width \(width): \(rest)")
        }
    }
}
