import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Undo {
    private func item(_ id: String, _ state: ItemState = .unread, at: Double = 1000, author: String = "x",
                      kind: EventKind = .issueComment) -> InboxItem {
        InboxItem(id: id, repo: "a/b", kind: kind, number: 1, title: id, snippet: "", author: author, avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/a/b")!, createdAt: Date(timeIntervalSince1970: at),
                  state: state)
    }

    private func store(_ items: [InboxItem]) -> Store {
        let s = Store()
        s.persists = false
        s.undoStack.announce = { _ in }
        s.items = items
        return s
    }

    private func ids(_ items: [InboxItem]) -> [String] { items.map(\.id) }

    // MARK: Done order

    @Test func doneIsOrderedByWhenItWasCleared() {
        let s = store([item("old", at: 100), item("new", at: 300), item("mid", at: 200)])
        // Cleared in the opposite order to their age: the last cleared leads.
        s.discard(s.items[0])
        s.items[0].clearedAt = Date(timeIntervalSince1970: 5000)
        s.discard(s.items[2])
        s.items[2].clearedAt = Date(timeIntervalSince1970: 6000)
        s.discard(s.items[1])
        s.items[1].clearedAt = Date(timeIntervalSince1970: 4000)
        #expect(ids(s.list(.done)) == ["mid", "old", "new"])
    }

    @Test func doneWithoutAClearTimeFallsBackToWhenItArrived() {
        var legacy = item("legacy", .discarded, at: 5500)
        legacy.clearedAt = nil
        var stamped = item("stamped", .discarded, at: 100)
        stamped.clearedAt = Date(timeIntervalSince1970: 5000)
        var older = item("older", .discarded, at: 4000)
        older.clearedAt = nil
        let s = store([stamped, older, legacy])
        #expect(ids(s.list(.done)) == ["legacy", "stamped", "older"])
    }

    @Test func otherTabsStayNewestFirst() {
        let s = store([item("a", at: 100), item("b", at: 300), item("c", at: 200)])
        #expect(ids(s.list(.needsYou)) == ["b", "c", "a"])
    }

    // MARK: Undo

    @Test func doneThenUndoRestoresTheStateItHad() {
        let s = store([item("1"), item("2", .read)])
        s.done(s.items[0])
        s.done(s.items[1])
        #expect(s.list(.done).count == 2)
        #expect(s.undoLast())
        #expect(s.items[1].state == .read)
        #expect(s.items[1].clearedAt == nil)
        #expect(s.items[0].state == .discarded)
        #expect(s.undoLast())
        #expect(s.items[0].state == .unread)
        #expect(!s.undoLast())
    }

    @Test func doneAllReadMovesOnlyTheReadOnesAndUndoesTogether() {
        let s = store([item("1"), item("2", .read), item("3", .read)])
        s.doneAllRead(.needsYou)
        #expect(ids(s.list(.needsYou)) == ["1"])
        #expect(s.undoStack.entries.count == 1)
        #expect(s.undoLast())
        #expect(s.list(.needsYou).count == 3)
        #expect(s.items.filter { $0.state == .read }.count == 2)
    }

    @Test func doneAllReadWithNothingReadRegistersNothing() {
        let s = store([item("1")])
        s.doneAllRead(.needsYou)
        #expect(s.undoStack.entries.isEmpty)
    }

    @Test func clearDoneDropsItemsAndUndoBringsThemBack() {
        let s = store([item("1"), item("2", .discarded), item("3", .addressed)])
        s.clearDone()
        #expect(ids(s.items) == ["1"])
        #expect(s.undoLast())
        #expect(Set(ids(s.items)) == ["1", "2", "3"])
        #expect(s.list(.done).count == 2)
    }

    @Test func clearDoneKeepsAnAnsweredForNothingReviewRequest() {
        // GitHub's search would hand a dropped, still-pending request back as new.
        let s = store([item("rr", .discarded, kind: .reviewRequested), item("2", .discarded)])
        #expect(s.hasClearableDone)
        s.clearDone()
        #expect(ids(s.items) == ["rr"])
        #expect(!s.hasClearableDone)
    }

    @Test func undoSkipsAnItemSomethingElseHasChanged() {
        let s = store([item("1")])
        s.done(s.items[0])
        // Restored by hand meanwhile, then read: undo must not flip it back to unread.
        s.restore(s.items[0])
        s.markRead(s.items[0])
        s.undoLast()
        #expect(s.items[0].state == .read)
    }

    @Test func anActionOlderThanThirtySecondsCannotBeUndone() {
        let s = store([item("1")])
        s.done(s.items[0])
        #expect(!s.undoStack.undo(now: Date().addingTimeInterval(UndoStack.validFor + 1)))
        #expect(s.items[0].state == .discarded)
    }

    @Test func theLineShowsForTheNewestActionInItsSection() {
        let s = store([item("1"), item("2")])
        s.done(s.items[0])
        #expect(s.undoStack.visible(in: .inbox)?.message == "Moved to Done")
        #expect(s.undoStack.visible(in: .ci) == nil)
        s.done(s.items[1])
        #expect(s.undoStack.entries.count == 2)
        #expect(s.undoStack.visible(in: .inbox)?.id == s.undoStack.entries.last?.id)
    }

    @Test func dismissingTheLineKeepsCommandZ() {
        let s = store([item("1")])
        s.done(s.items[0])
        s.undoStack.dismiss()
        #expect(s.undoStack.visible(in: .inbox) == nil)
        #expect(s.undoLast())
        #expect(s.items[0].state == .unread)
    }

    @Test func theLineGoesAwayOnItsOwnTimer() async throws {
        let s = store([item("1")])
        s.undoStack.lifetime = .milliseconds(30)
        s.done(s.items[0])
        #expect(s.undoStack.visible(in: .inbox) != nil)
        // Other suites may keep the main actor busy for a while: wait for the line, not for a fixed time.
        let deadline = ContinuousClock.now + .seconds(30)
        while s.undoStack.visible(in: .inbox) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(s.undoStack.visible(in: .inbox) == nil)
        #expect(s.undoStack.entries.count == 1)
    }

    @Test func theStackKeepsTheLastTen() {
        let s = store((0..<12).map { item("\($0)") })
        for i in 0..<12 { s.done(s.items[i]) }
        #expect(s.undoStack.entries.count == UndoStack.depth)
    }

    @Test func registeringAnythingElseUsesTheSameStack() {
        let s = store([])
        var undone = false
        s.registerUndo("Hid a session", in: .agents) { undone = true }
        #expect(s.undoStack.visible(in: .agents)?.message == "Hid a session")
        #expect(s.undoLast())
        #expect(undone)
    }
}
