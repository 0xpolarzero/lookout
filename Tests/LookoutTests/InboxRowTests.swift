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
