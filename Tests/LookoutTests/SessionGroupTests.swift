import AppKit
import Carbon
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct SessionGroups {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, folder: String? = "/code/app", minutesAgo: Double = 5, blocked: Bool = false,
                         running: Bool = false) -> ClaudeSession {
        ClaudeSession(id: id, title: "Session \(id)", folder: folder, completedTurns: 3,
                      lastActivity: now.addingTimeInterval(-minutesAgo * 60), lastFocused: now.addingTimeInterval(-3600),
                      lastUserMessage: now.addingTimeInterval(-(minutesAgo + 1) * 60),
                      summary: running ? nil : .init(blocked: blocked, detail: "Detail \(id)"), running: running)
    }

    /// A store that lists `sessions`: the ids in `kept` kept (in that order), the rest new activity, `unread` unread.
    private func store(_ sessions: [ClaudeSession], kept: [String] = [], unread: Set<String> = [],
                       asking: Set<String> = []) -> Store {
        let s = Store()
        s.persists = false
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
        // Eleven in New activity (three behind "+N more"), and a pending one waiting on you: not under New activity.
        let sessions = [session("ask", minutesAgo: 30, blocked: true)] + (0..<11).map { session("n\($0)", minutesAgo: Double($0 + 1)) }
        let s = store(sessions, unread: ["ask"])
        #expect(ids(s)["waiting"] == ["ask"] && ids(s)["new"]?.count == 11)
        #expect(s.listedGroups(expanded: false).hidden == 3)
        s.keepAllAgents()
        #expect(s.agentRows.pending.map(\.id) == ["ask"])
        #expect(s.agentRows.kept.count == 11)
        #expect(ids(s)["waiting"] == ["ask"])
        #expect(s.sessionGroups.map(\.id) == ["waiting", "project:/code/app"])
    }

    @Test func hideAndMuteOfferAnUndo() {
        let s = store([session("a"), session("b", folder: "/code/other")], kept: ["a"])
        var offered: [(String, () -> Void)] = []
        s.offerUndo = { offered.append(($0, $1)) }
        s.dismissAgent("a")
        #expect(s.agentRows.kept.isEmpty)
        #expect(offered.last?.0 == "Hidden \u{201C}Session a\u{201D}")
        offered.last?.1()
        #expect(s.agentRows.kept.map(\.id) == ["a"])
        s.muteFolder("/code/other")
        #expect(s.agents.mutedFolders == ["/code/other"] && s.agentRows.pending.isEmpty)
        #expect(offered.last?.0 == "Muted other")
        offered.last?.1()
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
        // Waiting for you, the project, then eight of New activity; the rest behind "+N more", then New session.
        #expect(Array(shown.prefix(2)) == ["ask", "x1"])
        #expect(shown.count == 2 + SessionGroup.newActivityCap)
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
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union([.numericPad, .function]), timestamp: 0,
                                windowNumber: 0, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                isARepeat: false, keyCode: UInt16(code))!
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
        // Only on that row.
        hub.selection = "a:x1"
        #expect(!keys.key(key(kVK_RightArrow)))
        #expect(hub.projectsMenuRequest == 1)
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
}
