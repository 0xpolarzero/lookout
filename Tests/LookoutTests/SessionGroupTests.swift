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
}
