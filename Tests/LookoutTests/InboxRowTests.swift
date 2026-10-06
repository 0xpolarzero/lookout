import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct InboxRowHeight {
    private func item(_ state: ItemState, kind: EventKind = .issueComment, author: String = "someone", title: String = "A title") -> InboxItem {
        InboxItem(id: "1", repo: "apple/swift-format", kind: kind, number: 1042, title: title, snippet: "", author: author, avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/a/b")!, createdAt: Date(), state: state)
    }

    /// The height a row settles at in a column `width` wide.
    private func height(of item: InboxItem, filter: InboxFilter = .needsYou, query: String = "", width: CGFloat = 400) -> CGFloat {
        let store = Store()
        store.persists = false
        let hub = HubState()
        hub.filter = filter
        hub.query = query
        let row = InboxRow(item: item, store: store, ui: UIState(), hub: hub).frame(width: width)
        let hosting = NSHostingView(rootView: row)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        for _ in 0..<4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            hosting.layoutSubtreeIfNeeded()
        }
        let h = hosting.fittingSize.height
        window.contentView = nil
        window.orderOut(nil)
        return h
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
        let store = Store()
        store.persists = false
        store.items = (0..<18).map { i in
            InboxItem(id: "\(i)", repo: "a/b", kind: .issueOpened, number: i, title: "Item \(i)", snippet: "", author: "x", avatar: nil,
                      authorIsApp: false, url: URL(string: "https://github.com/a/b")!,
                      createdAt: Date().addingTimeInterval(-Double(i) * 60), state: .unread)
        }
        let hub = HubState()
        let items = store.list(.needsYou)
        let list = InboxList(items: items, cap: 224, listKey: .init(revision: 0, filter: .needsYou, query: ""), scopeID: "needsYou",
                             store: store, ui: UIState(), hub: hub)
            .frame(width: 400)
        let hosting = NSHostingView(rootView: list)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        func settle() { for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded() } }
        settle()
        // 224 less the line is 4 rows: 14 below (as the list scrolls the count follows: see `theCountBelowFollowsTheScroll`).
        #expect(hub.inbox.hiddenBelow == 14)
        // Four whole rows and the line, never past the cap.
        #expect(abs(hosting.fittingSize.height - (4 * InboxList.pitch - 1 + InboxList.moreHeight)) < 1)
        window.contentView = nil
        window.orderOut(nil)
    }
}
