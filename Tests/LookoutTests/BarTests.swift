import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct Bar {
    private let now = sessionsNow

    // MARK: CI cell

    @Test func ciGlyphIsOneTileWhateverItSays() {
        // The first failure, or a second digit, never widens it: it stays the 26pt footprint of the other cells.
        let tile = CGSize(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
        for (worst, failing) in [(CIState.failure, 1), (.failure, 12), (.failure, 123), (.pending, 0), (.success, 0), (.none, 0)] {
            let face = CIBarCell.Face(worst: worst, failing: failing, hovering: false)
            #expect(NSHostingView(rootView: face).fittingSize == tile)
        }
        #expect(NSHostingView(rootView: CIBarCell.Face(worst: .none, failing: 0, unchecked: true, hovering: false)).fittingSize == tile)
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
    /// running `secondary`, and none reaches the white of a tile's letters. Measured in the shot: a symbol drawn with its
    /// own style can come out white whatever the style says.
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
        // Increase Contrast raises both to their stronger set.
        let strongPassing = try #require(await ciGlyphBrightness(.allPassing, contrast: true))
        let strongRunning = try #require(await ciGlyphBrightness(.ciRunning, contrast: true))
        #expect(strongPassing > passing && strongRunning > running)
    }

    // MARK: Inbox cell

    @Test func inboxValueSaysWhatNeedsYouAndTheBots() {
        #expect(InboxBarCell.value(needsYou: 5, bots: 2) == "5 need you, 2 bot items")
        #expect(InboxBarCell.value(needsYou: 0, bots: 0) == "Nothing needs you")
        #expect(InboxBarCell.value(needsYou: 0, bots: 1) == "Nothing needs you, 1 bot item")
    }

    // MARK: Gear

    @Test func syncFaultsRankSignInFirstAndHealthyHasNone() {
        let s = Store.unsaved()
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

    private func store(_ sessions: [ClaudeSession], seeded: Bool = false) -> Store {
        let s = Store.unsaved()
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.agents.seeded = seeded
        s.ingest(sessions, appUnread: [], claudeFrontmost: false, now: now)
        return s
    }

    @Test func tileMarksAreShapesAndWaitingNeverShowsARing() {
        let s = store([session("blocked", blocked: true), session("done"), session("busy", running: true)])
        for id in ["blocked", "done", "busy"] { s.agents.entries[s.agents.entries.firstIndex { $0.id == id }!].unread = true }
        let rows = Dictionary(uniqueKeysWithValues: s.allAgentRows.map { ($0.id, $0.tileMarks) })
        #expect(rows["blocked"] == TileMarks(waiting: true, working: false, unread: false))
        #expect(rows["done"] == TileMarks(waiting: false, working: false, unread: true))
        #expect(rows["busy"] == TileMarks(waiting: false, working: true, unread: true))
    }

    @Test func voiceOverValueIsStateProjectAndAge() {
        let s = store([session("blocked", folder: "/code/lcu", minutesAgo: 4, blocked: true)])
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
        #expect(hidden.count == 4)
    }

    @Test func oneOverShowsItsTileInsteadOfPlusOne() {
        let (shown, hidden) = BarSessions.arrange((0..<9).map { slot("s\($0)") }, frozen: nil)
        #expect(shown.count == 9)
        #expect(hidden.isEmpty)
    }

    @Test func waitingSessionsAreNeverCollapsed() {
        let slots = (0..<12).map { slot("s\($0)", "waiting", waiting: $0 < 10) }
        let (shown, hidden) = BarSessions.arrange(slots, frozen: nil)
        #expect(shown.count == 10)
        #expect(hidden.count == 2)
        // Even when the frozen order has it far down the list: it takes the last other tile's place, so no tile is added.
        let late = (0..<12).map { slot("s\($0)", waiting: $0 == 11) }
        let frozen = (0..<12).map { slot("s\($0)") }
        let arranged = BarSessions.arrange(late, frozen: frozen)
        #expect(arranged.shown.contains { $0.id == "s11" })
        #expect(arranged.shown.count == 8)
    }

    @Test func aLateWaitingSessionTakesTheLastTilesPlaceAndTheRunKeepsItsLength() {
        // Twelve of one project, held in order by the pointer; the twelfth then waits. The bar and the side panel arrange
        // the same way: its tile and its row stand where the eighth did, the "+4" stays the "+4", and nothing after it
        // (the "+", update, gear) moves under the pointer.
        let frozen = (0..<12).map { slot("s\($0)") }
        let late = (0..<12).map { $0 == 11 ? slot("s11", "waiting", waiting: true) : slot("s\($0)") }
        let before = BarSessions.arrange(frozen, frozen: frozen)
        let after = BarSessions.arrange(late, frozen: frozen)
        #expect(after.shown.map(\.id) == (0..<7).map { "s\($0)" } + ["s11"])
        #expect(after.shown.last?.group == "p:a")
        #expect(after.hidden.map(\.id) == ["s7", "s8", "s9", "s10"])
        // The "+N" cell starts where it did, and the run ends where it did: so do the "+", the update and the gear.
        #expect(BarSessions.length(after.shown, more: false) == BarSessions.length(before.shown, more: false))
        #expect(BarSessions.length(after.shown, more: true) == BarSessions.length(before.shown, more: true))
        #expect(after.shown.indices.map { BarSessions.gap(after.shown, before: $0) }
                == before.shown.indices.map { BarSessions.gap(before.shown, before: $0) })
    }

    @Test func aLateWaiterFromAnotherProjectKeepsTheTilesGaps() {
        // Its own project differs from the tile it replaces: the gaps are the held ones, not its own.
        let frozen = (0..<8).map { slot("a\($0)", "p:a") } + (0..<4).map { slot("b\($0)", "p:b") }
        var late = frozen
        late[11] = slot("b3", "p:b", waiting: true)
        let after = BarSessions.arrange(late, frozen: frozen)
        #expect(after.shown.map(\.id) == (0..<7).map { "a\($0)" } + ["b3"])
        #expect(after.shown.indices.allSatisfy { BarSessions.gap(after.shown, before: $0) == 0 })
        #expect(after.hidden.count == 4)
    }

    @Test func aLateWaiterWithNoOtherTileToTakeIsAddedAndTheRoomCutsTheRest() {
        // Every tile shown already waits: there is nothing to give up, so it joins them (the room has the last word).
        let frozen = (0..<12).map { slot("w\($0)", "waiting", waiting: $0 < 10) }
        let late = (0..<12).map { slot("w\($0)", "waiting", waiting: true) }
        #expect(BarSessions.arrange(late, frozen: frozen).shown.count == 12)
        #expect(BarSessions.arrange(late, frozen: frozen, room: 6 * Theme.Metrics.pitch).shown.count == 5)
    }

    /// Twelve sessions nobody kept, one project; the oldest is the one that waits.
    private func pendingStore() -> Store {
        let s = store((0..<12).map { session("p\($0)", minutesAgo: Double($0 + 1), blocked: $0 == 11) }, seeded: true)
        s.agents.entries.indices.forEach { s.agents.entries[$0].unread = true }
        return s
    }

    @Test func theMoreTileAndTheSessionsShowRouteListEveryPendingSession() throws {
        let s = pendingStore()
        let hub = HubState()
        let ui = UIState(persists: false, edge: .right)
        let keys = HubKeys(store: s, ui: ui, hub: hub)
        let rows = s.agentRows
        #expect(rows.kept.isEmpty)
        #expect(rows.pending.count == 12)
        // The bar: waiting first (the oldest), then the newest seven, and a "+4" for the rest.
        let (shown, hidden) = BarSessions.arrange(s.barSlots, frozen: nil)
        #expect(shown.count == 8)
        #expect(hidden.count == 4)
        // The hub, left alone, lists the same eight (the rest are behind "+4 more", the bar's "+4"), and the keys walk
        // through those and the list's own rows.
        #expect(s.hubSessions(hub).count == 8)
        #expect(s.hubSessions(hub).map(\.id) == shown.map(\.id))
        #expect(s.listedGroups(expanded: false).hidden == hidden.count)
        #expect(keys.targets() == s.hubSessions(hub).map { "a:" + $0.id } + ["s:more", "s:new"])
        let unlisted = try #require(hidden.last)
        #expect(!keys.targets().contains("a:" + unlisted.id))

        // The "+4" stands for the first of these, which the list leaves out too: showing it lists them all, and the keys
        // reach it.
        let first = try #require(hidden.first)
        hub.showSession(first.id, store: s, ui: ui)
        #expect(hub.sessionsExpanded)
        #expect(hub.selection == "a:" + first.id)
        hub.sessionsExpanded = false
        hub.showSession(unlisted.id, store: s, ui: ui)
        #expect(hub.sessionsExpanded)
        #expect(s.hubSessions(hub).count == 12)
        #expect(keys.targets() == s.hubSessions(hub).map { "a:" + $0.id } + ["s:new"])
        #expect(hub.selection == "a:" + unlisted.id)
        #expect(hub.keyboardSelection?.id == "a:" + unlisted.id)
        #expect(ui.drawerSelection == unlisted.id)
        for slot in hidden + shown { #expect(keys.targets().contains("a:" + slot.id)) }

        // Closing puts the hub's list back to what it lists unasked.
        hub.pinned = true
        hub.pinned = false
        #expect(s.hubSessions(hub).count == 8)
    }

    @Test func aTilePastTheListsCutoffIsShownByItsOwnRoute() throws {
        let s = pendingStore()
        let hub = HubState()
        let ui = UIState(persists: false, edge: .right)
        let new = try #require(s.sessionGroups.first { $0.kind == .newActivity }).rows
        // A tile the list shows needs nothing more.
        hub.showSession(new[1].id, store: s, ui: ui)
        #expect(!hub.sessionsExpanded)
        #expect(hub.selection == "a:" + new[1].id)
        // The oldest is behind "+4 more": its Show lists all.
        let oldest = try #require(new.last)
        #expect(!s.hubSessions(hub).contains { $0.id == oldest.id })
        hub.showSession(oldest.id, store: s, ui: ui)
        #expect(s.hubSessions(hub).contains { $0.id == oldest.id })
        #expect(hub.selection == "a:" + oldest.id)
        // A search narrows the list; showing a session leaves it.
        hub.query = "Session p3"
        hub.showSession(oldest.id, store: s, ui: ui)
        #expect(hub.query.isEmpty)
    }

    @Test func theMoreTileListsEverySessionEvenWhenItsFirstOneIsAlreadyListed() throws {
        let s = pendingStore()
        let hub = HubState()
        let ui = UIState(persists: false, edge: .right)
        // The bar's room hid a session the list shows anyway: the "+N" still opens the sessions with every row.
        let listed = try #require(s.hubSessions(hub).last)
        hub.showSession(listed.id, store: s, ui: ui)
        #expect(!hub.sessionsExpanded)
        hub.showSession(listed.id, store: s, ui: ui, listingAll: true)
        #expect(hub.sessionsExpanded && s.hubSessions(hub).count == 12)
        #expect(hub.selection == "a:" + listed.id)
    }

    @Test func theEdgesRoomCutsTheTilesAndTheMoreCellTakesOneSlot() {
        let pitch = Theme.Metrics.pitch
        let slots = (0..<12).map { slot("s\($0)") }
        // Room for five cells: four tiles and the "+8".
        let (shown, hidden) = BarSessions.arrange(slots, frozen: nil, room: 5 * pitch)
        #expect(shown.map(\.id) == ["s0", "s1", "s2", "s3"])
        #expect(hidden.count == 8)
        // Plenty of room changes nothing: the eight and a "+4".
        #expect(BarSessions.arrange(slots, frozen: nil, room: 40 * pitch).hidden.count == 4)
    }

    @Test func waitingSessionsAreTheLastToLoseTheirTileToTheEdgesRoom() {
        let pitch = Theme.Metrics.pitch
        // Three waiting, then ten others: room for six cells keeps all three waiting and two others, never the reverse.
        let slots = (0..<3).map { slot("w\($0)", "waiting", waiting: true) } + (0..<10).map { slot("s\($0)") }
        let (shown, hidden) = BarSessions.arrange(slots, frozen: nil, room: 6 * pitch + BarSessions.groupGap)
        #expect(shown.map(\.id) == ["w0", "w1", "w2", "s0", "s1"])
        #expect(hidden.count == 8)
        // Twenty waiting on a short screen: the first ten show, the rest are behind a "+10" that knows they wait.
        let many = (0..<20).map { slot("w\($0)", "waiting", waiting: true) }
        let cut = BarSessions.arrange(many, frozen: nil, room: 11 * pitch)
        #expect(cut.shown.count == 10)
        #expect(cut.hidden.count == 10)
        #expect(cut.hidden.allSatisfy { $0.waiting })
    }

    @Test func oneOverStillShowsItsTileWhenTheRoomHasIt() {
        let pitch = Theme.Metrics.pitch
        let slots = (0..<9).map { slot("s\($0)") }
        #expect(BarSessions.arrange(slots, frozen: nil, room: 9 * pitch).hidden.isEmpty)
        // Not when the tile needs a gap the room lacks: the "+1" holds it instead.
        let two = (0..<8).map { slot("s\($0)") } + [slot("t", "p:b")]
        #expect(BarSessions.arrange(two, frozen: nil, room: 9 * pitch).hidden.count == 1)
    }

    @Test func slotsPutWaitingFirstThenProjectsThenNewActivity() {
        let s = store([session("a"), session("w", blocked: true), session("b", folder: "/code/other")])
        s.agents.entries[s.agents.entries.firstIndex { $0.id == "w" }!].unread = true
        for index in s.agents.entries.indices { s.agents.entries[index].kept = true }
        let slots = s.barSlots
        #expect(slots.map(\.id) == ["w", "a", "b"])
        #expect(slots.map(\.group) == ["waiting", "project:/code/app", "project:/code/other"])
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
