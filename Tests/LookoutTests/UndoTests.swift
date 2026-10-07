import Foundation
import Testing
@testable import Lookout

/// A stand-in for `Task.sleep` that waits until it is woken, and says when it has started waiting.
@MainActor
final class Sleeper {
    private(set) var durations: [Duration] = []
    private var sleeping: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async {
        durations.append(duration)
        started?.resume()
        started = nil
        await withCheckedContinuation { sleeping = $0 }
    }

    func waitUntilSleeping() async {
        if durations.isEmpty { await withCheckedContinuation { started = $0 } }
    }

    func wake() {
        sleeping?.resume()
        sleeping = nil
    }
}

@MainActor
@Suite struct Undo {
    private func item(_ id: String, _ state: ItemState = .unread, at: Double = 1000, author: String = "x",
                      kind: EventKind = .issueComment) -> InboxItem {
        inboxItem(id, kind: kind, title: id, author: author, at: Date(timeIntervalSince1970: at), state: state)
    }

    private func store(_ items: [InboxItem]) -> Store {
        let s = Store.unsaved()
        s.undoStack.announce = { _ in }
        s.repos = [RepoConfig(fullName: "a/b")]
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

    @Test func clearDoneClearsReviewRequestsToo() {
        // Remembered by id apart from the rows, so GitHub's search, still listing it, doesn't bring it back as new.
        let s = store([item("rr#1", .discarded, kind: .reviewRequested), item("2", .discarded)])
        #expect(s.hasClearableDone)
        s.clearDone()
        #expect(s.items.isEmpty)
        #expect(s.droppedRequests == ["rr#1"])
        #expect(!s.hasClearableDone)
        #expect(s.undoLast())
        #expect(Set(ids(s.items)) == ["rr#1", "2"])
        #expect(s.droppedRequests.isEmpty)
    }

    @Test func onlyReviewRequestsNobodyAnsweredAreRemembered() {
        let s = store([item("rr#1", .addressed, kind: .reviewRequested)])
        s.clearDone()
        #expect(s.items.isEmpty)
        #expect(s.droppedRequests.isEmpty)
    }

    @Test func droppedRequestsSurviveARestart() throws {
        var state = PersistedState(repos: [], items: [], ci: [:], settings: AppSettings(), agents: nil, mutedCI: nil,
                                   droppedRequests: ["rr#1"])
        let data = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(PersistedState.self, from: data)
        #expect(state.droppedRequests == ["rr#1"])
    }

    // MARK: Cleared events stay cleared

    private nonisolated static func reply(_ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// A store watching a/b's new issues, whose issues list answers with issue 7 (opened now, then commented on, so listed again).
    private func syncing(_ items: [InboxItem]) -> Store {
        let s = store(items)
        s.repos = [RepoConfig(fullName: "a/b", events: [.issueOpened])]
        s.settings.reviewRequests = false
        s.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        let now = ISO8601DateFormatter().string(from: Date())
        let issue = """
        [{"id": 7, "number": 7, "title": "Opened", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
          "html_url": "https://github.com/a/b/issues/7", "created_at": "\(now)", "updated_at": "\(now)", "pull_request": null}]
        """
        s.gh.transport = { request in Undo.reply(request.url!.path == "/repos/a/b/issues" ? issue : "[]") }
        return s
    }

    @Test func aClearedEventListedAgainByGitHubDoesNotComeBackUnread() async {
        let s = syncing([item("a/b#issueOpened#7", .discarded, at: Date().timeIntervalSince1970, kind: .issueOpened)])
        s.clearDone()
        #expect(s.clearedConversations.keys.sorted() == ["a/b#issueOpened#7"])
        await s.pollAll()
        #expect(s.items.isEmpty)
    }

    @Test func anUndoneClearIsTheRowAgainAndNotAddedTwice() async {
        let s = syncing([item("a/b#issueOpened#7", .discarded, at: Date().timeIntervalSince1970, kind: .issueOpened)])
        s.clearDone()
        #expect(s.undoLast())
        #expect(s.clearedConversations.isEmpty)
        await s.pollAll()
        #expect(ids(s.items) == ["a/b#issueOpened#7"] && s.items[0].state == .discarded)
    }

    @Test func clearedEventsAreForgottenAfterFourteenDaysAndSurviveARestart() throws {
        let s = store([item("1", .discarded), item("2", .discarded)])
        s.clearDone()
        s.clearedConversations["1"] = Date().addingTimeInterval(-15 * 86400)
        s.prune()
        #expect(s.clearedConversations.keys.sorted() == ["2"])
        let data = try JSONEncoder().encode(PersistedState(repos: [], items: [], ci: [:], settings: AppSettings(), agents: nil,
                                                           mutedCI: nil, clearedConversations: s.clearedConversations))
        #expect(try JSONDecoder().decode(PersistedState.self, from: data).clearedConversations == s.clearedConversations)
    }

    // MARK: Review requests beyond the first page

    private func request(_ id: Int) -> GHIssue {
        let json = """
        {"id": \(id), "number": \(id), "title": "PR \(id)", "body": null, "user": {"login": "x", "avatar_url": null, "type": "User"},
         "html_url": "https://github.com/a/b/pull/\(id)", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
         "pull_request": null, "repository_url": "https://api.github.com/repos/a/b"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(GHIssue.self, from: Data(json.utf8))
    }

    @Test func aClearedRequestKeepsItsSuppressionWhileOffThePageFetched() {
        let s = store([])
        s.settings.didInitialReviewSync = true
        s.applyReviewRequests([request(1), request(2)], complete: true)
        s.discard(s.items[0])
        s.clearDone()
        #expect(s.droppedRequests == ["rr#1"])
        // It slides off the page that was fetched, then back on: still cleared, not unread again.
        s.applyReviewRequests([request(2)], complete: false)
        #expect(s.droppedRequests == ["rr#1"])
        s.applyReviewRequests([request(1), request(2)], complete: true)
        #expect(s.droppedRequests == ["rr#1"])
        #expect(!s.items.contains { $0.id == "rr#1" })
    }

    @Test func aRequestOffThePageFetchedIsNotMarkedAddressed() {
        let s = store([])
        s.settings.didInitialReviewSync = true
        s.applyReviewRequests([request(1), request(2)], complete: true)
        s.applyReviewRequests([request(2)], complete: false)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .unread)
        s.applyReviewRequests([request(2)], complete: true)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .addressed)
    }

    @Test func aRequestListedAgainAfterItWasAddressedReturnsToNeedsYou() {
        let s = store([])
        s.settings.didInitialReviewSync = true
        s.applyReviewRequests([request(1), request(2)], complete: true)
        s.discard(s.items[1])
        s.applyReviewRequests([], complete: true)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .addressed)
        let pulse = s.pulse
        s.applyReviewRequests([request(1), request(2)], complete: true)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .unread)
        #expect(s.pulse == pulse + 1)
        // The one dismissed while it stayed outstanding is still in Done.
        #expect(s.items.first { $0.id == "rr#2" }?.state == .discarded)
    }

    @Test func aSuppressionEndsOnceTheSearchListedEverythingWithoutIt() {
        let s = store([])
        s.settings.didInitialReviewSync = true
        s.applyReviewRequests([request(1)], complete: true)
        s.discard(s.items[0])
        s.clearDone()
        #expect(s.droppedRequests == ["rr#1"])
        s.applyReviewRequests([], complete: true)
        #expect(s.droppedRequests.isEmpty)
        // The same PR asks for a review again.
        s.applyReviewRequests([request(1)], complete: true)
        #expect(s.items.first { $0.id == "rr#1" }?.state == .unread)
    }

    // MARK: Undo after the configuration changed

    private func configured() -> Store {
        store([item("1", .discarded), item("2", .discarded, kind: .reviewComment), item("rr#1", .discarded, kind: .reviewRequested)])
    }

    @Test func undoingClearDoneDoesNotBringBackAWatchedRepoRemoved() {
        let s = configured()
        s.clearDone()
        s.removeRepo(s.repos[0])
        #expect(s.undoLast())
        // The repository's items stay gone; the review request, which belongs to no repository, comes back.
        #expect(ids(s.items) == ["rr#1"])
    }

    @Test func undoingClearDoneDoesNotBringBackAnEventTurnedOff() {
        let s = configured()
        s.clearDone()
        s.toggle(.reviewComment, on: s.repos[0])
        #expect(s.undoLast())
        #expect(ids(s.items).sorted() == ["1", "rr#1"])
    }

    @Test func undoingClearDoneDoesNotBringBackWhatAllCommentsOffDrops() {
        var other = item("3", .discarded)
        other.forYou = false
        let s = store([item("1", .discarded), other])
        s.repos = [RepoConfig(fullName: "a/b", allComments: true)]
        s.clearDone()
        s.toggleAllComments(s.repos[0])
        #expect(s.undoLast())
        #expect(ids(s.items) == ["1"])
    }

    @Test func undoingClearDoneDoesNotBringBackReviewRequestsTurnedOff() {
        let s = configured()
        s.clearDone()
        s.settings.reviewRequests = false
        #expect(s.undoLast())
        #expect(!ids(s.items).contains("rr#1"))
        #expect(s.droppedRequests.isEmpty)
    }

    // MARK: Polling

    @Test func pollingKeepsAnItemThroughItsUndoWindow() {
        // Closed items go 14 days after they arrived: one marked Done today, 15 days on, must still be undoable.
        let old = Date().addingTimeInterval(-15 * 86400).timeIntervalSince1970
        let s = store([item("1", at: old)])
        s.done(s.items[0])
        s.prune()
        #expect(ids(s.items) == ["1"])
        #expect(s.undoLast())
        #expect(s.items[0].state == .unread)
    }

    @Test func pollingPrunesItOnceTheWindowHasPassed() {
        let old = Date().addingTimeInterval(-15 * 86400).timeIntervalSince1970
        let s = store([item("1", at: old)])
        s.done(s.items[0])
        s.prune(now: Date().addingTimeInterval(UndoStack.validFor + 1))
        #expect(s.items.isEmpty)
    }

    @Test func theItemCapKeepsWhatUndoCouldStillRestore() {
        // The oldest of a full inbox marked Done, then one new item: the cap would drop exactly the cleared row.
        let now = Date()
        let base = now.addingTimeInterval(-3600).timeIntervalSince1970
        let s = store((0..<Store.itemCap).map { item("\($0)", at: base + Double($0)) })
        s.done(s.items[0])
        s.items.append(item("new", at: now.timeIntervalSince1970))
        s.prune(now: now)
        #expect(s.items.contains { $0.id == "0" })
        #expect(s.items.contains { $0.id == "new" })
        #expect(s.undoLast())
        #expect(s.items.first { $0.id == "0" }?.state == .unread)
        // Once the window has passed, the cap applies to it like any other row.
        s.done(s.items.first { $0.id == "0" }!)
        s.prune(now: now.addingTimeInterval(UndoStack.validFor + 1))
        #expect(s.items.count == Store.itemCap)
        #expect(!s.items.contains { $0.id == "0" })
    }

    @Test func aWholeInboxMarkedDoneStaysUndoableAndStillTakesNewItems() {
        let now = Date()
        let base = now.addingTimeInterval(-3600).timeIntervalSince1970
        let s = store((0..<Store.itemCap).map { item("\($0)", .read, at: base + Double($0)) })
        s.doneAllRead(.needsYou)
        s.items.append(item("new", at: now.timeIntervalSince1970))
        s.prune(now: now)
        #expect(s.items.count == Store.itemCap + 1)
        #expect(s.undoLast())
        #expect(s.items.filter { $0.state == .read }.count == Store.itemCap)
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

    @Test func theLineGoesAwayOnItsOwnTimer() async {
        let s = store([item("1")])
        let sleeper = Sleeper()
        s.undoStack.sleep = { await sleeper.sleep($0) }
        s.done(s.items[0])
        #expect(s.undoStack.visible(in: .inbox) != nil)
        // Once the timer is waiting, let it finish and wait for it to act: no wall-clock time involved.
        await sleeper.waitUntilSleeping()
        #expect(sleeper.durations == [UndoStack.lineLifetime])
        #expect(s.undoStack.visible(in: .inbox) != nil)
        sleeper.wake()
        await s.undoStack.timer?.value
        #expect(s.undoStack.visible(in: .inbox) == nil)
        #expect(s.undoStack.entries.count == 1)
    }

    @Test func aNewerLineIsNotDismissedByTheOlderTimer() async {
        let s = store([item("1"), item("2")])
        let first = Sleeper(), second = Sleeper()
        s.undoStack.sleep = { await first.sleep($0) }
        s.done(s.items[0])
        let older = s.undoStack.timer
        await first.waitUntilSleeping()
        s.undoStack.sleep = { await second.sleep($0) }
        s.done(s.items[1])
        await second.waitUntilSleeping()
        // The first timer is cancelled by the second line; waking it must leave the second showing.
        first.wake()
        await older?.value
        #expect(s.undoStack.visible(in: .inbox) != nil)
        second.wake()
        await s.undoStack.timer?.value
        #expect(s.undoStack.visible(in: .inbox) == nil)
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
