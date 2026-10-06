import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct SessionGroups {
    private let now = sessionsNow

    /// A store that lists `sessions`: the ids in `kept` kept (in that order), the rest new activity, `unread` unread.
    private func store(_ sessions: [ClaudeSession], kept: [String] = [], unread: Set<String> = [],
                       asking: Set<String> = []) -> Store {
        let s = Store.unsaved()
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        // Seeded already (a first read offers only eight), so every session below is new activity.
        s.ingest([], appUnread: [], claudeFrontmost: false, now: now)
        s.ingest(sessions, appUnread: unread, claudeFrontmost: false, now: now)
        for i in s.agents.entries.indices { s.agents.entries[i].unread = unread.contains(s.agents.entries[i].id) }
        for id in kept { s.keepAgent(id) }
        // A working session that stopped on a question.
        s.claudeActivity = Dictionary(uniqueKeysWithValues: asking.map { ($0, ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)) })
        return s
    }

    private func ids(_ s: Store) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: s.sessionGroups.map { ($0.id, $0.rows.map(\.id)) })
    }

    @Test func groupsComeInPanelOrder() {
        let s = store([
            session("scratch", folder: nil), session("x1", folder: "/code/x"), session("y1", folder: "/code/y"),
            session("x2", folder: "/code/x"), session("new1", minutesAgo: 1), session("ask", folder: "/code/y", blocked: true),
        ], kept: ["scratch", "x1", "y1", "x2", "ask"], unread: ["ask"])
        #expect(s.sessionGroups.map(\.id) == ["waiting", "project:/code/x", "project:/code/y", "project:", "new"])
        #expect(ids(s)["waiting"] == ["ask"])
        #expect(ids(s)["project:/code/x"] == ["x1", "x2"])
        // A session leaves its project for Waiting for you, and doesn't count there any more.
        #expect(ids(s)["project:/code/y"] == ["y1"])
    }

    @Test func waitingSessionsAreAllInTheFirstGroupKeptOrNot() {
        let s = store([
            session("a", minutesAgo: 30, blocked: true), session("b", minutesAgo: 10, running: true),
            session("c", folder: "/code/y", minutesAgo: 20, blocked: true), session("d"),
        ], kept: ["a"], unread: ["a", "c"], asking: ["b"])
        // Most recent first; the pending ones too.
        #expect(ids(s)["waiting"] == ["b", "c", "a"])
        #expect(ids(s)["new"] == ["d"])
        #expect(s.agentCounts.blocked == 3)
    }

    @Test func theSessionsShortcutPicksTheFirstWaitingOneWorkingOrFinished() {
        // A finished, unread session and another that is mid-turn, stopped on a question: the question is the pick.
        let s = store([session("done", minutesAgo: 1), session("busy", minutesAgo: 9, running: true), session("kept", minutesAgo: 20)],
                      kept: ["done", "kept"], unread: ["done"], asking: ["busy"])
        #expect(s.sessionShortcutPick?.id == "busy")
        // Nothing waits: the first kept one.
        s.claudeActivity = [:]
        #expect(s.sessionShortcutPick?.id == "done")
        // None kept either: nothing to pick.
        #expect(store([session("n")]).sessionShortcutPick == nil)
    }

    @Test func theKeyboardsTooltipListsEveryTaskTheRowOnlyCounts() throws {
        let s = store([session("a")], kept: ["a"])
        s.claudeTasks = ["a": [ClaudeTask(id: "t1", kind: .agent, title: "Review the diff", since: now),
                               ClaudeTask(id: "t2", kind: .command, title: "swift test", since: now)]]
        let row = try #require(s.agentRows.kept.first)
        #expect(row.tasks.count == 2)
        #expect(SessionRow.tipDetail(row) == "Detail a\nReview the diff\nswift test")
    }

    @Test func aReadQuestionIsNotWaiting() {
        let s = store([session("a", blocked: true)], kept: ["a"], unread: [])
        #expect(s.sessionGroups.map(\.id) == ["project:/code/app"])
    }

    @Test func projectsKeepTheirPlaceWhenASessionStartsWaiting() {
        let sessions = [session("x1", folder: "/code/x"), session("y1", folder: "/code/y"), session("y2", folder: "/code/y")]
        let s = store(sessions, kept: ["x1", "y1", "y2"])
        #expect(s.sessionGroups.map(\.id) == ["project:/code/x", "project:/code/y"])
        // x's only session asks something: its group goes, y stays where it was.
        s.claudeActivity = ["x1": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["x1"]?.running = true
        #expect(s.sessionGroups.map(\.id) == ["waiting", "project:/code/y"])
    }

    @Test func newActivityIsCappedWithAHiddenCount() {
        let sessions = (0..<11).map { session("n\($0)", minutesAgo: Double($0 + 1)) }
        let s = store(sessions)
        let whole = s.listedGroups(expanded: true)
        #expect(whole.hidden == 0 && whole.groups.first?.rows.count == 11)
        let capped = s.listedGroups(expanded: false)
        #expect(capped.hidden == 3)
        #expect(capped.groups.first?.rows.map(\.id) == (0..<8).map { "n\($0)" })
    }

    @Test func theCapShowsEightWaitingOnesAlwaysAndNeverAPlusOne() {
        #expect(SessionCap.shown(total: 5, waiting: 0) == 5)
        #expect(SessionCap.shown(total: 8, waiting: 3) == 8)
        // One over shows in the place of its own "+1".
        #expect(SessionCap.shown(total: 9, waiting: 0) == 9)
        #expect(SessionCap.shown(total: 10, waiting: 0) == 8)
        // Ten waiting take ten slots, and one more of the others would be a "+1" again.
        #expect(SessionCap.shown(total: 12, waiting: 10) == 10)
        #expect(SessionCap.shown(total: 11, waiting: 10) == 11)
        #expect(SessionCap.shown(total: 20, waiting: 20) == 20)
    }

    @Test func theBarsPlusAndTheListsMoreAreTheSameNumber() {
        for (waiting, kept, new) in [(0, 0, 12), (1, 0, 11), (3, 4, 9), (10, 0, 2), (0, 11, 0), (2, 5, 2)] {
            let asking = (0..<waiting).map { session("w\($0)", folder: "/code/y", minutesAgo: Double($0 + 1), blocked: true) }
            let keeping = (0..<kept).map { session("k\($0)", folder: "/code/x") }
            let fresh = (0..<new).map { session("n\($0)", minutesAgo: Double($0 + 30)) }
            let s = store(asking + keeping + fresh, kept: keeping.map(\.id) + asking.map(\.id), unread: Set(asking.map(\.id)))
            let bar = BarSessions.arrange(s.barSlots, frozen: nil)
            let list = s.listedGroups(expanded: false)
            #expect(bar.hidden.count == list.hidden, "\(waiting) waiting, \(kept) kept, \(new) new")
            #expect(bar.shown.map(\.id) == list.groups.flatMap(\.rows).map(\.id))
        }
    }

    @Test func theCapIsSharedInPanelOrderAndKeepsWaitingSessionsWhole() {
        // Four waiting, one kept and eleven new: eight show, the waiting ones first, then the others in panel order.
        let waiting = (0..<4).map { session("w\($0)", folder: "/code/y", minutesAgo: Double($0 + 1), blocked: true) }
        let sessions = waiting + [session("k", folder: "/code/x")] + (0..<11).map { session("n\($0)", minutesAgo: Double($0 + 20)) }
        let s = store(sessions, kept: ["k"], unread: Set(waiting.map(\.id)))
        let listed = s.listedGroups(expanded: false)
        #expect(listed.groups.flatMap(\.rows).map(\.id) == ["w0", "w1", "w2", "w3", "k", "n0", "n1", "n2"])
        #expect(listed.hidden == 8)
        #expect(listed.groups.map(\.id) == ["waiting", "project:/code/x", "new"])
        // The groups keep their full counts, whatever is listed.
        #expect(listed.groups.map(\.total) == [4, 1, 11])
        // A cut that takes a whole group away takes its header too.
        let more = store((0..<2).map { session("k\($0)", folder: "/code/x") } + (0..<8).map { session("n\($0)", minutesAgo: Double($0 + 1)) }, kept: ["k0", "k1"])
        #expect(more.listedGroups(expanded: false).groups.map(\.id) == ["project:/code/x", "new"])
        let plenty = store((0..<9).map { session("k\($0)", folder: "/code/x") } + (0..<3).map { session("n\($0)", minutesAgo: Double($0 + 1)) },
                           kept: (0..<9).map { "k\($0)" })
        #expect(plenty.listedGroups(expanded: false).groups.map(\.id) == ["project:/code/x"])
        #expect(plenty.listedGroups(expanded: false).hidden == 4)
    }

    @Test func aPeekListsWholeRowsAndEndsWithTheCountOfTheRest() {
        let sessions = (1...3).map { session("x\($0)", folder: "/code/x") } + (0..<10).map { session("n\($0)", minutesAgo: Double($0 + 1)) }
        let s = store(sessions, kept: ["x1", "x2", "x3"])
        // Header 28 + 3 rows of 44, a gap of 8, header 28, and rows of New activity while a "+N more" line (36) still fits.
        let peek = SessionGroup.peek(s.sessionGroups, cap: 330)
        #expect(peek.groups.map(\.id) == ["project:/code/x", "new"])
        #expect(peek.groups.map(\.rows.count) == [3, 2])
        #expect(peek.hidden == 8)
        // Everything fits: nothing is left out, and no line for it.
        let all = SessionGroup.peek(s.sessionGroups, cap: 1000)
        #expect(all.hidden == 0 && all.groups.map(\.rows.count) == [3, 10])
        // Exactly full is not cut either.
        let few = SessionGroup.peek(Array(s.sessionGroups.prefix(1)), cap: 160)
        #expect(few.hidden == 0 && few.groups.first?.rows.count == 3)
        // The sessions the shared cap left out are in the count, and keep the line even when every listed row fits.
        let capped = s.listedGroups(expanded: false)
        #expect(capped.hidden == 5)
        let tall = SessionGroup.peek(capped.groups, hidden: capped.hidden, cap: 1000)
        #expect(tall.hidden == 5 && tall.groups.map(\.rows.count) == [3, 5])
        let tight = SessionGroup.peek(capped.groups, hidden: capped.hidden, cap: SessionGroup.height(capped.groups) + Theme.Metrics.pitch - 1)
        #expect(tight.hidden == 6 && tight.groups.map(\.rows.count) == [3, 4])
        // A group's header never stands alone: no room for its first row, no header.
        #expect(SessionGroup.peek(s.sessionGroups, cap: 200).groups.map(\.id) == ["project:/code/x"])
        // A row with a task line is 60 tall.
        s.claudeTasks = ["n0": [ClaudeTask(id: "a", kind: .command, title: "Run it", since: now)]]
        #expect(SessionGroup.height(of: s.agentRows.pending.first { $0.id == "n0" }!) == Theme.Metrics.taskRow)
    }

    @Test func moveUpAndDownStayInTheProject() {
        let s = store([session("x1", folder: "/code/x"), session("y1", folder: "/code/y"), session("x2", folder: "/code/x"),
                       session("y2", folder: "/code/y")], kept: ["x1", "y1", "x2", "y2"])
        #expect(!s.canMoveAgent("x1", by: -1) && s.canMoveAgent("x1", by: 1))
        s.moveAgent("x1", by: 1)
        #expect(ids(s)["project:/code/x"] == ["x2", "x1"])
        #expect(ids(s)["project:/code/y"] == ["y1", "y2"])
        s.moveAgent("y2", by: -1)
        #expect(ids(s)["project:/code/y"] == ["y2", "y1"])
        // The projects keep their order.
        #expect(s.sessionGroups.map(\.id) == ["project:/code/x", "project:/code/y"])
        // Past the end does nothing.
        s.moveAgent("x1", by: 1)
        #expect(ids(s)["project:/code/x"] == ["x2", "x1"])
    }

    @Test func moveActionsActOnTheRowsTheFrozenListShows() {
        let s = store([session("x1", folder: "/code/x"), session("x2", folder: "/code/x"), session("x3", folder: "/code/x"),
                       session("y1", folder: "/code/y")], kept: ["x1", "x2", "x3", "y1"])
        let hub = HubState()
        hub.frozenSessions = s.barSlots
        // x2 starts waiting: the list still shows it between x1 and x3, in its project, with moves of its own.
        s.claudeActivity = ["x2": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["x2"]?.running = true
        let held = s.listedGroups(hub).groups.first { $0.id == "project:/code/x" }
        #expect(held?.rows.map(\.id) == ["x1", "x2", "x3"])
        #expect(hub.canMoveSession("x2", by: 1, store: s) && !s.canMoveAgent("x2", by: 1))
        // Move down on x1 trades with x2, as it is shown, and the list shows it at once.
        hub.moveSession("x1", by: 1, store: s)
        #expect(s.listedGroups(hub).groups.first { $0.id == "project:/code/x" }?.rows.map(\.id) == ["x2", "x1", "x3"])
        #expect(s.agents.entries.map(\.id) == ["x2", "x1", "x3", "y1"])
        // A drop does the same, and a project moved is a block of the held order.
        hub.moveSession("x3", onto: "x2", store: s)
        #expect(s.listedGroups(hub).groups.first { $0.id == "project:/code/x" }?.rows.map(\.id) == ["x3", "x2", "x1"])
        hub.moveProject("/code/y", by: -1, store: s)
        #expect(s.listedGroups(hub).groups.map(\.id) == ["project:/code/y", "project:/code/x"])
        hub.frozenSessions = nil
        #expect(s.listedGroups(hub).groups.map(\.id) == ["waiting", "project:/code/y", "project:/code/x"])
    }

    @Test func moveActionsNeverTargetARowTheCutListHides() {
        let s = store((0..<12).map { session("a\($0)", folder: "/code/x") }, kept: (0..<12).map { "a\($0)" })
        let hub = HubState()
        hub.frozenSessions = s.barSlots
        // The last one starts waiting while the pointer holds the list: it takes the place of the eighth row, so the list shows
        // a0 to a6 and then a11, and a7 is behind the cut.
        s.claudeActivity = ["a11": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["a11"]?.running = true
        #expect(s.listedGroups(hub).groups.first { $0.id == "project:/code/x" }?.rows.map(\.id) == ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a11"])
        #expect(!hub.listsAllSessions)
        #expect(s.neighbour(of: "a6", 1, frozen: hub.frozenSessions) == "a7")
        #expect(s.neighbour(of: "a6", 1, frozen: hub.frozenSessions, expanded: false) == "a11")
        #expect(s.neighbour(of: "a11", -1, frozen: hub.frozenSessions, expanded: false) == "a6")
        // The keys, the menu and the VoiceOver action all ask the hub, which asks for what the list shows.
        #expect(hub.canMoveSession("a6", by: 1, store: s) && !hub.canMoveSession("a7", by: -1, store: s))
        // Move down trades a6 with a11 as the list shows them, and both stay on the screen.
        hub.moveSession("a6", by: 1, store: s)
        #expect(s.listedGroups(hub).groups.first { $0.id == "project:/code/x" }?.rows.map(\.id) == ["a0", "a1", "a2", "a3", "a4", "a5", "a11", "a6"])
        #expect(s.agents.entries.map(\.id) == ["a0", "a1", "a2", "a3", "a4", "a5", "a11", "a6", "a7", "a8", "a9", "a10"])
        // The list that shows everything has a7 beside a6.
        hub.sessionsExpanded = true
        #expect(s.neighbour(of: "a6", 1, frozen: hub.frozenSessions, expanded: hub.listsAllSessions) == "a7")
    }

    @Test func dropsOnAnotherProjectAreIgnored() {
        let s = store([session("x1", folder: "/code/x"), session("y1", folder: "/code/y")], kept: ["x1", "y1"])
        s.moveAgent("y1", onto: "x1")
        #expect(s.agents.entries.map(\.id) == ["x1", "y1"])
    }

    @Test func keepAllKeepsEveryNewActivitySession() {
        let s = store((0..<10).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        s.keepAllAgents()
        #expect(s.agentRows.pending.isEmpty)
        #expect(s.agentRows.kept.count == 10)
        #expect(s.sessionGroups.map(\.id) == ["project:/code/app"])
    }

    @Test func keepAllLeavesTheWaitingGroupAlone() {
        // Eleven in New activity, and a pending one waiting on you: not under New activity. Of the twelve, four are behind "+N more".
        let sessions = [session("ask", minutesAgo: 30, blocked: true)] + (0..<11).map { session("n\($0)", minutesAgo: Double($0 + 1)) }
        let s = store(sessions, unread: ["ask"])
        #expect(ids(s)["waiting"] == ["ask"] && ids(s)["new"]?.count == 11)
        #expect(s.listedGroups(expanded: false).hidden == 4)
        s.keepAllAgents()
        #expect(s.agentRows.pending.map(\.id) == ["ask"])
        #expect(s.agentRows.kept.count == 11)
        #expect(ids(s)["waiting"] == ["ask"])
        #expect(s.sessionGroups.map(\.id) == ["waiting", "project:/code/app"])
    }

    @Test func keepAllKeepsWhatTheFrozenHeaderListsNotWhatIsNewActivityNow() {
        // "ask" is waiting, pending, and listed under Waiting for you; the pointer is over the hub, so the list is frozen like that.
        let s = store([session("ask", minutesAgo: 30, running: true)] + (0..<3).map { session("n\($0)", minutesAgo: Double($0 + 1)) },
                      unread: ["ask"], asking: ["ask"])
        let frozen = s.barSlots
        #expect(ids(s)["waiting"] == ["ask"])
        // Then it stops waiting: it is new activity now, but the list under the pointer still has it under Waiting for you.
        s.claudeActivity = [:]
        #expect(ids(s)["waiting"] == nil && ids(s)["new"]?.contains("ask") == true)
        s.keepAllAgents(frozen: frozen)
        #expect(s.agentRows.pending.map(\.id) == ["ask"])
        #expect(s.agentRows.kept.count == 3)
    }

    @Test func hideAndMuteOfferAnUndo() {
        let s = store([session("a"), session("b", folder: "/code/other")], kept: ["a"])
        s.dismissAgent("a")
        #expect(s.agentRows.kept.isEmpty)
        #expect(s.undoStack.visible(in: .agents)?.message == "Hidden \u{201C}Session a\u{201D}")
        #expect(s.undoLast())
        #expect(s.agentRows.kept.map(\.id) == ["a"])
        s.muteFolder("/code/other")
        #expect(s.agents.mutedFolders == ["/code/other"] && s.agentRows.pending.isEmpty)
        #expect(s.undoStack.visible(in: .agents)?.message == "Muted other")
        #expect(s.undoLast())
        #expect(s.agents.mutedFolders.isEmpty && s.agentRows.pending.map(\.id) == ["b"])
    }

    @Test func statusWordsAndAges() {
        let s = store([session("w", minutesAgo: 2, blocked: true), session("r", minutesAgo: 1, running: true), session("f", minutesAgo: 4)],
                      unread: ["w"])
        let rows = Dictionary(uniqueKeysWithValues: s.agentRows.pending.map { ($0.id, $0) })
        #expect(rows["w"]?.statusLabel(now: now) == "Waiting")
        #expect(rows["r"]?.statusLabel(now: now) == "Working 2m")
        #expect(rows["f"]?.statusLabel(now: now) == "Finished 4m")
        #expect(rows["w"]?.spokenValue(now: now) == "waiting, app, 2 minutes")
        #expect(rows["f"]?.spokenValue(now: now) == "finished, app, 4 minutes")
    }

    @Test func aFinishedSessionSpeaksWhatItLeftRunning() {
        let s = store([session("f", minutesAgo: 4)], unread: ["f"])
        s.claudeTasks = ["f": [ClaudeTask(id: "a", kind: .agent, title: "Review the changes", since: now),
                               ClaudeTask(id: "b", kind: .command, title: "Run the full test suite", since: now),
                               ClaudeTask(id: "c", kind: .command, title: "Watch the build", since: now)]]
        let row = s.agentRows.pending[0]
        #expect(row.spokenValue(now: now) == "finished, unread, app, 4 minutes, 3 running")
        #expect(row.spokenHint == "Detail f Running: Review the changes, Run the full test suite, Watch the build.")
        // Nothing left running: the value and hint say nothing of it.
        s.claudeTasks = [:]
        #expect(s.agentRows.pending[0].spokenValue(now: now) == "finished, unread, app, 4 minutes")
        #expect(s.agentRows.pending[0].spokenHint == "Detail f")
    }

    @Test func theKeysWalkTheRowsInTheOrderTheyShow() {
        let sessions = [session("x1", folder: "/code/x"), session("ask", folder: "/code/y", blocked: true), session("n1", minutesAgo: 1)]
            + (2..<11).map { session("n\($0)", minutesAgo: Double($0)) }
        let s = store(sessions, kept: ["x1", "ask"], unread: ["ask"])
        let hub = HubState()
        let shown = s.hubSessions(hub).map(\.id)
        // Waiting for you, the project, then New activity, eight sessions in all; the rest behind "+N more", then New session.
        #expect(Array(shown.prefix(2)) == ["ask", "x1"])
        #expect(shown.count == SessionCap.visible)
        #expect(s.sessionExtraTargets(hub) == ["s:more", "s:new"])
        hub.sessionsExpanded = true
        #expect(s.hubSessions(hub).count == 10 + 2)
        #expect(s.sessionExtraTargets(hub) == ["s:new"])
        // A search lists matches flat and offers no New session row.
        hub.query = "session x1"
        #expect(s.sessionExtraTargets(hub).isEmpty)
    }

    /// A real key-down as the monitor sees it: arrows carry the function and numeric-pad flags, and their private-use character.
    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let arrow = [kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey][code]
            .flatMap { Unicode.Scalar($0) }.map(String.init) ?? ""
        return keyDown(code, flags.union([.numericPad, .function]), arrow)
    }

    private func hubKeys(_ s: Store) -> (HubKeys, HubState) {
        let hub = HubState()
        hub.pinned = true
        return (HubKeys(store: s, ui: UIState(), hub: hub), hub)
    }

    @Test func optionArrowsMoveThePickedSessionAndKeepThePick() {
        let s = store((1...3).map { session("x\($0)", folder: "/code/x") }, kept: ["x1", "x2", "x3"])
        let (keys, hub) = hubKeys(s)
        hub.selection = "a:x2"
        #expect(keys.key(key(kVK_UpArrow, .option)))
        #expect(ids(s)["project:/code/x"] == ["x2", "x1", "x3"])
        // Still picked, and the list is asked to scroll to it.
        #expect(hub.selection == "a:x2" && hub.keyboardSelection?.id == "a:x2")
        // At the top it stays; one down puts it back, and another goes on.
        #expect(keys.key(key(kVK_UpArrow, .option)))
        #expect(ids(s)["project:/code/x"] == ["x2", "x1", "x3"])
        #expect(keys.key(key(kVK_DownArrow, .option)))
        #expect(keys.key(key(kVK_DownArrow, .option)))
        #expect(ids(s)["project:/code/x"] == ["x1", "x3", "x2"])
        #expect(hub.selection == "a:x2")
        // Plain arrows still walk the rows.
        #expect(keys.key(key(kVK_UpArrow)))
        #expect(hub.selection == "a:x3")
        // A session outside a project has nowhere to move: the key is handled and nothing changes.
        let n = store([session("n1", minutesAgo: 1), session("n2", minutesAgo: 2)])
        let (newKeys, newHub) = hubKeys(n)
        newHub.selection = "a:n1"
        #expect(newKeys.key(key(kVK_DownArrow, .option)))
        #expect(ids(n)["new"] == ["n1", "n2"])
    }

    @Test func rightArrowOnNewSessionOpensItsMenu() {
        let s = store([session("x1", folder: "/code/x")], kept: ["x1"])
        let (keys, hub) = hubKeys(s)
        hub.selection = "s:new"
        #expect(hub.projectsMenuRequest == 0)
        #expect(keys.key(key(kVK_RightArrow)))
        #expect(hub.projectsMenuRequest == 1)
        // Only on that row: on a session, → is the inbox's next tab.
        hub.selection = "a:x1"
        #expect(keys.key(key(kVK_RightArrow)))
        #expect(hub.projectsMenuRequest == 1 && hub.filter == .bots)
    }

    @Test func theProjectsMenuListsScratchThenTheProjectsMostRecentFirst() {
        let s = store([session("a", folder: "/code/old", minutesAgo: 50), session("b", folder: "/code/new", minutesAgo: 1)])
        #expect(ProjectsMenu.make(s).items.map(\.title) == ["Scratch (no folder)", "", "new", "old"])
    }

    @Test func oneWaitingClearsASearchThatHidesItBeforePickingIt() {
        let s = store([session("ask", blocked: true), session("n1", minutesAgo: 1)], kept: ["ask"], unread: ["ask"])
        let hub = HubState(), ui = UIState()
        hub.query = "n1"
        hub.focus = .inbox
        #expect(s.hubSessions(hub).map(\.id) == ["n1"])
        hub.pickFirstWaiting(in: s, ui: ui)
        // The whole list is back, with the waiting row in it, picked and asked for.
        #expect(hub.query.isEmpty && hub.focus == nil)
        #expect(s.hubSessions(hub).map(\.id).first == "ask")
        #expect(hub.selection == "a:ask" && hub.keyboardSelection?.id == "a:ask" && ui.drawerSelection == "ask")
        // With Sessions focused already, it stays so.
        hub.focus = .agents
        hub.pickFirstWaiting(in: s, ui: ui)
        #expect(hub.focus == .agents)
    }

    @Test func openingMoreMovesThePickToTheFirstSessionItRevealed() {
        let s = store((0..<12).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let (keys, hub) = hubKeys(s)
        #expect(s.sessionExtraTargets(hub) == ["s:more", "s:new"])
        hub.selection = "s:more"
        #expect(keys.key(key(kVK_Return)))
        // The pick is on the ninth session, which is scrolled to; the arrows go on from there through the rest.
        #expect(hub.sessionsExpanded && hub.selection == "a:n8" && hub.keyboardSelection?.id == "a:n8")
        #expect(s.sessionExtraTargets(hub) == ["s:new"])
        #expect(keys.key(key(kVK_DownArrow)))
        #expect(hub.selection == "a:n9")
        #expect(keys.key(key(kVK_Return)))
        #expect(hub.selection == "a:n9")
        for expected in ["a:n10", "a:n11", "s:new"] {
            #expect(keys.key(key(kVK_DownArrow)))
            #expect(hub.selection == expected)
        }
        // A click on "+N more" opens the rest and scrolls to it without picking anything.
        let clicked = HubState()
        clicked.expandSessions(in: s, ui: UIState())
        #expect(clicked.selection == nil && clicked.keyboardSelection?.id == "a:n8")
    }

    @Test func aPickedIconStaysWhenNoneCanBePickedToReplaceIt() {
        let s = store([session("a")])
        s.agents.entries[0].icon = "hammer"
        // Icons off: the icon is kept (and shown), and cannot be repicked.
        #expect(!s.canPickIcons)
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == "hammer" && s.agents.entries[0].rejectedIcons == nil)
        s.agents.iconsEnabled = true
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == "hammer")
        // On, with a key: the old one goes, and is not offered again.
        s.hasTypesafeKey = true
        #expect(s.canPickIcons)
        s.repickIcon("a")
        #expect(s.agents.entries[0].icon == nil && s.agents.entries[0].rejectedIcons == ["hammer"])
    }

    @Test func aPeekCutsRowsButNotTheCountOfTheirProject() {
        let s = store((0..<5).map { session("x\($0)", folder: "/code/x", minutesAgo: Double($0 + 1)) }, kept: (0..<5).map { "x\($0)" })
        // Room for the header, two rows and "+N more".
        let peek = SessionGroup.peek(s.sessionGroups, cap: SessionGroup.headerHeight + 2 * Theme.Metrics.twoLineRow + Theme.Metrics.pitch)
        #expect(peek.groups[0].rows.count == 2 && peek.hidden == 3)
        #expect(peek.groups[0].total == 5)
    }

    @Test func theInboxGetsARowBeforeSessionsGetTheirMinimum() {
        let least = SessionGroup.leastHeight
        // Plenty of room: the sessions' minimum, or 45% of it when that is more.
        #expect(SessionGroup.share(of: 600) == 270 && SessionGroup.share(of: 400) == least)
        // A 560pt hub beside the bar leaves 200: the inbox keeps one row, Sessions shrinks to the rest.
        #expect(SessionGroup.share(of: 200) == 200 - SessionGroup.inboxLeast)
        for free in stride(from: 160.0, through: 700, by: 10) {
            #expect(free - SessionGroup.share(of: free) >= SessionGroup.inboxLeast)
        }
    }

    @Test func aFocusedListCountsWhatIsBelowItsViewport() {
        let s = store((0..<6).map { session("x\($0)", folder: "/code/x", minutesAgo: Double($0 + 1)) }, kept: (0..<6).map { "x\($0)" })
        let groups = s.sessionGroups
        let row = Theme.Metrics.twoLineRow
        // Header and two whole rows in view: four rows below (a row cut by the edge is not shown yet).
        #expect(SessionGroup.below(groups, hidden: 0, reach: SessionGroup.headerHeight + 2 * row) == 4)
        #expect(SessionGroup.below(groups, hidden: 0, reach: SessionGroup.headerHeight + 3 * row - 1) == 4)
        #expect(SessionGroup.below(groups, hidden: 0, reach: SessionGroup.height(groups)) == 0)
        // "+N more" counts its sessions until its own row is whole in view.
        let end = SessionGroup.height(groups)
        #expect(SessionGroup.below(groups, hidden: 3, reach: end) == 3)
        #expect(SessionGroup.below(groups, hidden: 3, reach: end + Theme.Metrics.pitch) == 0)
    }

    @Test func theKeysSkipRowsAFocusedSectionHides() {
        let s = store([session("x1", folder: "/code/x")], kept: ["x1"])
        var started: [String] = []
        s.interceptOpen = { started.append($0) }
        let (keys, hub) = hubKeys(s)
        // Inbox focused: no session row is shown, so none is a target (not even New session).
        hub.focus = .inbox
        #expect(keys.key(key(kVK_DownArrow)) && hub.selection == nil)
        #expect(keys.key(key(kVK_UpArrow)) && hub.selection == nil)
        #expect(!keys.key(key(kVK_Return)) && started.isEmpty)
        // Sessions focused: they are.
        hub.focus = .agents
        #expect(keys.key(key(kVK_DownArrow)) && hub.selection == "a:x1")
        // Focusing another section lets go of a pick it hides.
        hub.focus = .inbox
        #expect(hub.selection == nil && hub.keyboardSelection == nil)
        hub.focus = nil
        hub.selection = "a:x1"
        hub.focus = .agents
        #expect(hub.selection == "a:x1")
    }

    @Test func newSessionOffersTheMostRecentProjectFirst() {
        let s = store([session("a", folder: "/code/old", minutesAgo: 50), session("b", folder: "/code/new", minutesAgo: 1),
                       session("c", folder: nil, minutesAgo: 0)])
        #expect(s.recentFolders == ["/code/new", "/code/old"])
    }

    @Test func labelsKnowEmoji() {
        #expect(AgentLabel.isEmoji("🐧") && !AgentLabel.isEmoji("AB") && !AgentLabel.isEmoji("7") && !AgentLabel.isEmoji(""))
    }

    // MARK: Project order and frozen lists

    @Test func projectsMoveAsBlocksAndScratchStaysLast() {
        let s = store([session("x1", folder: "/code/x"), session("y1", folder: "/code/y"), session("x2", folder: "/code/x"),
                       session("z1", folder: "/code/z"), session("scratch", folder: nil)], kept: ["x1", "y1", "x2", "z1", "scratch"])
        #expect(s.projectOrder == ["/code/x", "/code/y", "/code/z"])
        #expect(!s.canMoveProject("/code/x", by: -1) && s.canMoveProject("/code/x", by: 1) && !s.canMoveProject("", by: 1))
        s.moveProject("/code/z", onto: "/code/x")
        #expect(s.sessionGroups.map(\.id) == ["project:/code/z", "project:/code/x", "project:/code/y", "project:"])
        // Each project keeps its sessions, in their own order.
        #expect(ids(s)["project:/code/x"] == ["x1", "x2"])
        s.moveProject("/code/z", by: 1)
        #expect(s.projectOrder == ["/code/x", "/code/z", "/code/y"])
        s.moveProject("/code/y", by: 1)
        #expect(s.projectOrder == ["/code/x", "/code/z", "/code/y"])
    }

    @Test func aFocusedSessionsListShowsEverySession() {
        let s = store((0..<12).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let hub = HubState()
        #expect(s.hubSessions(hub).count == SessionCap.visible)
        hub.focus = .agents
        #expect(s.hubSessions(hub).count == 12 && s.sessionExtraTargets(hub) == ["s:new"])
        hub.focus = nil
        #expect(s.hubSessions(hub).count == SessionCap.visible)
    }

    @Test func aPeekTooSmallForTheRestStillShowsARowAndSaysHowManyAreLeft() {
        let s = store((0..<5).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let peek = SessionGroup.peek(s.sessionGroups, cap: 20)
        #expect(peek.groups.flatMap(\.rows).count == 1 && peek.hidden == 4)
        // Waiting sessions among the ones left out are counted apart.
        let waiting = store([session("a", blocked: true), session("b", blocked: true), session("c")], kept: ["a", "b", "c"], unread: ["a", "b"])
        let cut = SessionGroup.peek(waiting.sessionGroups, cap: SessionGroup.leastShown)
        #expect(cut.hidden == 2 && cut.waiting == 1)
    }

    @Test func theListKeepsTheOrderTheBarTilesAreFrozenIn() {
        let s = store([session("x1", folder: "/code/x"), session("y1", folder: "/code/y"), session("y2", folder: "/code/y")],
                      kept: ["x1", "y1", "y2"])
        let frozen = s.barSlots
        // y2 starts waiting: live, it moves to Waiting for you at once; frozen, its row stays beside its tile.
        s.claudeActivity = ["y2": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["y2"]?.running = true
        #expect(s.listedGroups(expanded: false).groups.map(\.id) == ["waiting", "project:/code/x", "project:/code/y"])
        let held = s.listedGroups(expanded: false, frozen: frozen).groups
        #expect(held.map(\.id) == ["project:/code/x", "project:/code/y"])
        #expect(held[1].rows.map(\.id) == ["y1", "y2"] && held[1].rows[1].isWaiting)
    }

    @Test func aFrozenProjectGroupHoldingAnotherProjectsRowKeepsItsOwnNameAndNamesTheRow() throws {
        let s = store([session("x1", folder: "/code/x"), session("y1", folder: "/code/y")], kept: ["x1", "y1"])
        let rows = s.agentRows.kept
        let x = try #require(rows.first { $0.id == "x1" }), y = try #require(rows.first { $0.id == "y1" })
        // y's late waiter took x's only visible place under a frozen order: the group is still x's, and so are its actions.
        let group = SessionGroup(kind: .project("/code/x"), rows: [y])
        #expect(group.title(s) == "x")
        #expect(group.placement(of: y) == .waiting && group.placement(of: x) == .project)
        #expect(SessionGroup(kind: .project(""), rows: [y]).title(s) == "Scratch")
    }

    @Test func sessionsOfSameNamedProjectsSayWhichProjectTheyAreIn() throws {
        let s = store([session("a", folder: "/customer-a/app", blocked: true), session("b", folder: "/customer-b/app")],
                      kept: ["a", "b"], unread: ["a"])
        let rows = s.agentRows.kept
        let a = try #require(rows.first { $0.id == "a" }), b = try #require(rows.first { $0.id == "b" })
        #expect(s.sessionGroups.map { $0.title(s) } == ["Waiting for you", "customer-b/app"])
        #expect(a.projectName == "customer-a/app" && b.projectName == "customer-b/app")
        #expect(a.spokenValue(now: now).contains("customer-a/app") && b.tileValue(now: now).contains("customer-b/app"))
        // The name follows the folders: with the other project gone, the folder's own name is enough again.
        s.claudeSessions["a"] = nil
        #expect(s.folderName("/customer-b/app") == "app")
        #expect(try #require(s.agentRows.kept.first).projectName == "app")
        // A muted project still tells a session's project from another of its name.
        s.setFolderMuted("/customer-a/app", true)
        #expect(s.folderName("/customer-b/app") == "customer-b/app")
    }

    @Test func aWaitingSessionIsNeverCutWhereverTheFreezeLeavesIt() {
        let sessions = (0..<10).map { session("n\($0)", minutesAgo: Double($0 + 1)) }
        let s = store(sessions)
        let frozen = s.barSlots
        // The last of them, far past the eight, now asks: it is listed, whatever the frozen order says.
        s.claudeActivity = ["n9": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["n9"]?.running = true
        let listed = s.listedGroups(expanded: false, frozen: frozen)
        #expect(listed.groups.flatMap(\.rows).map(\.id).contains("n9"))
    }

    // MARK: Search, frozen counts and the spoken age

    @Test func aSearchListsEverySessionThatMatches() {
        let s = store((0..<12).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let hub = HubState()
        hub.query = "Session"
        #expect(s.hubSessions(hub).count == 12)
        #expect(s.searchSessions("Session n11").map(\.id) == ["n11"])
        // A waiting one past the eighth is found too, and reachable by the keys.
        s.claudeActivity = ["n11": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["n11"]?.running = true
        #expect(s.hubSessions(hub).map(\.id).contains("n11"))
        #expect(s.hubTargets(hub).contains("a:n11"))
    }

    @Test func aFrozenGroupCountsEverySessionItHolds() {
        let s = store((1...5).map { session("x\($0)", folder: "/code/x") } + [session("y1", folder: "/code/y")],
                      kept: ["x1", "x2", "x3", "x4", "x5", "y1"])
        let listed = s.listedGroups(expanded: false, frozen: s.barSlots)
        #expect(listed.groups.map(\.total) == [5, 1])
        #expect(listed.groups.map { $0.rows.count } == [5, 1])
    }

    @Test func aLateWaiterIsTheSameTileInTheBarAndTheList() {
        // Ten new sessions frozen in order; the ninth then asks something. The bar puts it in the last other tile's place, and
        // the list says the same, with the same number left out (DESIGN.md 10.4).
        let s = store((0..<10).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let frozen = s.barSlots
        s.claudeActivity = ["n9": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["n9"]?.running = true
        let bar = BarSessions.arrange(s.barSlots, frozen: frozen)
        let list = s.listedGroups(expanded: false, frozen: frozen)
        #expect(list.groups.flatMap(\.rows).map(\.id) == bar.shown.map(\.id))
        #expect(list.hidden == bar.hidden.count && list.hiddenIDs == bar.hidden.map(\.id))
        #expect(bar.shown.count == 8 && list.groups.flatMap(\.rows).map(\.id).contains("n9"))
        // Focused, the list is whole.
        #expect(s.listedGroups(expanded: true, frozen: frozen).groups.flatMap(\.rows).count == 10)
    }

    @Test func theCutNamesHowManyOfTheSessionsBelowWait() {
        let waiting = (0..<3).map { session("w\($0)", folder: "/code/y", minutesAgo: Double($0 + 1), blocked: true) }
        let s = store(waiting + (0..<4).map { session("n\($0)", minutesAgo: Double($0 + 20)) }, kept: waiting.map(\.id),
                      unread: Set(waiting.map(\.id)))
        let groups = s.sessionGroups
        let row = Theme.Metrics.twoLineRow
        // Only the first waiting row is whole: the other two are below, and so are the new ones.
        let reach = SessionGroup.headerHeight + row
        #expect(SessionGroup.below(groups, hidden: 0, reach: reach) == 6)
        #expect(SessionGroup.waitingBelow(groups, reach: reach) == 2)
        #expect(SessionGroup.waitingBelow(groups, reach: SessionGroup.height(groups)) == 0)
    }

    @Test func aFrozenWaiterUnderItsProjectIsStillCountedWaiting() {
        let s = store([session("x1", folder: "/code/x"), session("x2", folder: "/code/x")], kept: ["x1", "x2"])
        let frozen = s.barSlots
        s.claudeActivity = ["x2": ClaudeActivity(text: "Which one?", since: now, waitsForYou: true)]
        s.claudeSessions["x2"]?.running = true
        let held = s.listedGroups(expanded: false, frozen: frozen).groups
        #expect(held.map(\.id) == ["project:/code/x"] && SessionGroup.waiting(held) == 1)
    }

    @Test func mutingAMutedFolderAgainOffersNoUndoThatWouldUnmuteIt() {
        let s = store([session("a")], kept: ["a"])
        s.muteFolder("/code/app")
        #expect(s.agents.mutedFolders == ["/code/app"])
        s.undoLast()
        #expect(s.agents.mutedFolders.isEmpty)
        s.setFolderMuted("/code/app", true)
        s.muteFolder("/code/app")
        #expect(!s.undoLast() && s.agents.mutedFolders == ["/code/app"])
    }

    @Test func theAgeSpokenIsTheAgeShownForAWorkingSessionToo() {
        // No message of yours to count from: both fall back to the same date.
        let working = ClaudeSession(id: "r", title: "R", folder: "/code/app", lastActivity: now.addingTimeInterval(-300), running: true)
        let row = AgentRow(session: working, entry: AgentEntry(id: "r"), label: "R")
        #expect(row.statusLabel(now: now) == "Working 5m")
        #expect(row.spokenValue(now: now) == "working, app, 5 minutes")
    }
}
