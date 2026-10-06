import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct Bar {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func status(_ state: CIState, sha: String = "a1", minutesAgo: Double = 10) -> CIStatus {
        CIStatus(state: state, branch: "main", sha: sha, failing: state == .failure ? ["build"] : [],
                 checkedAt: now, updatedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func summary(_ states: [String: CIStatus], muted: [String: String] = [:]) -> CIBarSummary {
        CIBarSummary.make(repos: states.keys.sorted().map { RepoConfig(fullName: "o/\($0)") },
                          status: Dictionary(uniqueKeysWithValues: states.map { ("o/\($0.key)", $0.value) }), muted: muted)
    }

    // MARK: CI cell

    @Test func worstStateDecidesTheGlyph() {
        #expect(summary(["a": status(.success), "b": status(.pending)]).worst == .pending)
        #expect(summary(["a": status(.success), "b": status(.pending), "c": status(.failure)]).worst == .failure)
        #expect(summary(["a": status(.success)]).worst == .success)
        #expect(summary(["a": status(.none)]).worst == .none)
    }

    @Test func ciGlyphIsOneTileWhateverItSays() {
        // The first failure, or a second digit, never widens it: it stays the 26pt footprint of the other cells.
        let tile = CGSize(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
        for (worst, failing) in [(CIState.failure, 1), (.failure, 12), (.failure, 123), (.pending, 0), (.success, 0), (.none, 0)] {
            let face = CIBarCell.Face(worst: worst, failing: failing, hovering: false)
            #expect(NSHostingView(rootView: face).fittingSize == tile)
        }
    }

    /// The brightest grey the bar's CI cell draws in a shot of this scenario (0...255): the real hub, on its edge, as the
    /// playground renders it.
    private func ciGlyphBrightness(_ scenario: Demo.Scenario, contrast: Bool = false) async -> Int? {
        var shot = Shot(name: "ci-glyph", scenario: scenario)
        if contrast { shot.environment = .contrast }
        guard let rep = await PlaygroundShots.render(shot) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / shot.size.width
        func red(_ x: Int, _ y: Int) -> Int { Int(((rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0) * 255).rounded()) }
        let x0 = Int((shot.size.width - Theme.Metrics.bar) * scale)
        // The inbox tile is the bar's first amber mark: the CI cell is the one slot under its own.
        guard let tileTop = (0..<rep.pixelsHigh).first(where: { y in (x0..<rep.pixelsWide).contains { x in red(x, y) > 240 && (rep.colorAt(x: x, y: y)?.blueComponent ?? 1) < 0.4 } })
        else { return nil }
        let top = tileTop - Int(((Theme.Metrics.pitch - Theme.Metrics.tile) / 2) * scale) + Int(Theme.Metrics.pitch * scale)
        var best = 0
        for y in top..<(top + Int(Theme.Metrics.pitch * scale)) {
            for x in x0..<rep.pixelsWide { best = max(best, red(x, y)) }
        }
        return best
    }

    /// The quietest states are the quietest marks on the bar (DESIGN.md 5.1): passing and no runs draw `tertiary`,
    /// running `secondary`, and none reaches the white of a tile's letters. (Measured in the shot, where the two outline
    /// symbols once drew pure white whatever their style said.)
    @Test func ciGlyphsDrawTheirOwnTokenNotWhite() async throws {
        let passing = try #require(await ciGlyphBrightness(.allPassing))
        let noRuns = try #require(await ciGlyphBrightness(.ciNoRuns))
        let running = try #require(await ciGlyphBrightness(.ciRunning))
        #expect(passing == noRuns)
        #expect(passing < running, "passing draws \(passing), running \(running)")
        #expect(running < 215, "running draws \(running)")
        // 3:1 against the rail, from the pixels' own luminance.
        func luminance(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let rail = 30
        #expect((luminance(passing) + 0.05) / (luminance(rail) + 0.05) >= 3)
    }

    @Test func clickOpensTheWorstReposNewestChecks() {
        let s = summary(["a": status(.failure, minutesAgo: 90), "b": status(.failure, minutesAgo: 5), "c": status(.pending, minutesAgo: 1)])
        #expect(s.open?.name == "b")
        #expect(s.failing == 2)
        #expect(s.value == "2 failing, 1 running")
    }

    @Test func mutedRepoLeavesTheWorstStateUntilItsCommitChanges() {
        let states = ["a": status(.failure, sha: "s1"), "b": status(.success)]
        let muted = summary(states, muted: ["o/a": "s1"])
        #expect(muted.worst == .success)
        #expect(muted.failing == 0)
        #expect(muted.muted == 1)
        #expect(muted.value == "1 passing, 1 muted")
        // A new commit on the muted repo: the mute is for the old one.
        #expect(summary(["a": status(.failure, sha: "s2"), "b": status(.success)], muted: ["o/a": "s1"]).worst == .failure)
    }

    // MARK: Inbox cell

    @Test func inboxValueSaysWhatNeedsYouAndTheBots() {
        #expect(InboxBarCell.value(needsYou: 5, bots: 2) == "5 need you, 2 bot items")
        #expect(InboxBarCell.value(needsYou: 0, bots: 0) == "Nothing needs you")
        #expect(InboxBarCell.value(needsYou: 0, bots: 1) == "Nothing needs you, 1 bot item")
    }

    // MARK: Gear

    @Test func syncFaultsRankSignInFirstAndHealthyHasNone() {
        let s = Store()
        s.persists = false
        #expect(s.syncFault(stale: false) == nil)
        #expect(s.syncFault(stale: true) == .stale)
        s.rateRemaining = 0
        #expect(s.syncFault(stale: true) == .rateLimited)
        s.repoErrors = ["o/a": "Not found"]
        #expect(s.syncFault(stale: false) == .partial)
        s.authError = "No token"
        #expect(s.syncFault(stale: false) == .signIn)
        #expect(SyncFault.signIn.tint == Theme.red)
        #expect(SyncFault.partial.tint == Theme.amber)
    }

    // MARK: Sessions

    private func session(_ id: String, folder: String? = "/code/app", blocked: Bool = false, running: Bool = false,
                         minutesAgo: Double = 5) -> ClaudeSession {
        ClaudeSession(id: id, title: "Session \(id)", folder: folder, completedTurns: 3,
                      lastActivity: now.addingTimeInterval(-minutesAgo * 60), lastFocused: now.addingTimeInterval(-3600),
                      lastUserMessage: now.addingTimeInterval(-(minutesAgo + 1) * 60),
                      summary: running ? nil : .init(blocked: blocked, detail: "Detail \(id)"), running: running)
    }

    private func store(_ sessions: [ClaudeSession]) -> Store {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: [], claudeFrontmost: false, now: now)
        return s
    }

    @Test func tileMarksAreShapesAndWaitingNeverShowsAnArc() {
        let s = store([session("blocked", blocked: true), session("done"), session("busy", running: true)])
        for id in ["blocked", "done", "busy"] { s.agents.entries[s.agents.entries.firstIndex { $0.id == id }!].unread = true }
        let rows = Dictionary(uniqueKeysWithValues: s.allAgentRows.map { ($0.id, $0.tileMarks) })
        #expect(rows["blocked"] == TileMarks(waiting: true, working: false, unread: false))
        #expect(rows["done"] == TileMarks(waiting: false, working: false, unread: true))
        #expect(rows["busy"] == TileMarks(waiting: false, working: true, unread: true))
    }

    @Test func voiceOverValueIsStateProjectAndAge() {
        let s = store([session("blocked", folder: "/code/lcu", blocked: true, minutesAgo: 4)])
        s.agents.entries[0].unread = true
        let row = s.allAgentRows[0]
        #expect(row.tileValue(now: now) == "waiting for you, lcu, 4 minutes")
        #expect(row.tileHint == "Detail blocked")
    }

    private func slot(_ id: String, _ group: String = "p:a", waiting: Bool = false) -> BarSessions.Slot {
        BarSessions.Slot(id: id, group: group, waiting: waiting)
    }

    @Test func cappedAtEightWithTheRestInAMoreTile() {
        let slots = (0..<12).map { slot("s\($0)") }
        let (shown, hidden) = BarSessions.arrange(slots, frozen: nil)
        #expect(shown.count == 8)
        #expect(hidden == 4)
    }

    @Test func oneOverShowsItsTileInsteadOfPlusOne() {
        let (shown, hidden) = BarSessions.arrange((0..<9).map { slot("s\($0)") }, frozen: nil)
        #expect(shown.count == 9)
        #expect(hidden == 0)
    }

    @Test func waitingSessionsAreNeverCollapsed() {
        let slots = (0..<12).map { slot("s\($0)", "waiting", waiting: $0 < 10) }
        let (shown, hidden) = BarSessions.arrange(slots, frozen: nil)
        #expect(shown.count == 10)
        #expect(hidden == 2)
        // Even when the frozen order has it far down the list.
        let late = (0..<12).map { slot("s\($0)", waiting: $0 == 11) }
        let frozen = (0..<12).map { slot("s\($0)") }
        let arranged = BarSessions.arrange(late, frozen: frozen)
        #expect(arranged.shown.contains { $0.id == "s11" })
        #expect(arranged.shown.count == 9)
    }

    @Test func slotsPutWaitingFirstThenProjectsThenNewActivity() {
        let s = store([session("a"), session("w", blocked: true), session("b", folder: "/code/other")])
        s.agents.entries[s.agents.entries.firstIndex { $0.id == "w" }!].unread = true
        for index in s.agents.entries.indices { s.agents.entries[index].kept = true }
        let rows = s.agentRows
        let slots = BarSessions.slots(kept: rows.kept, pending: rows.pending)
        #expect(slots.map(\.id) == ["w", "a", "b"])
        #expect(slots.map(\.group) == ["waiting", "p:/code/app", "p:/code/other"])
    }

    @Test func frozenOrderHoldsWhileSessionsReorderAndNewOnesJoinTheEnd() {
        let now = [slot("c"), slot("a"), slot("b"), slot("d")]
        let (shown, _) = BarSessions.arrange(now, frozen: [slot("a"), slot("b"), slot("c"), slot("gone")])
        #expect(shown.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func frozenGroupsHoldWhileAMarkChanges() {
        // The second of one project's two sessions starts waiting: it keeps its place and its gap while frozen.
        let frozen = [slot("a", "p:x"), slot("b", "p:x"), slot("c", "p:y")]
        let now = [slot("b", "waiting", waiting: true), slot("a", "p:x"), slot("c", "p:y")]
        let (shown, _) = BarSessions.arrange(now, frozen: frozen)
        #expect(shown.map(\.id) == ["a", "b", "c"])
        #expect(shown.indices.map { BarSessions.gap(shown, before: $0) } == [0, 0, BarSessions.groupGap])
        // Thawed, it moves up into its own group.
        let (thawed, _) = BarSessions.arrange(now, frozen: nil)
        #expect(thawed.map(\.id) == ["b", "a", "c"])
        #expect(thawed.indices.map { BarSessions.gap(thawed, before: $0) } == [0, BarSessions.groupGap, BarSessions.groupGap])
    }
}
