import Foundation
import Testing
@testable import Lookout

/// The Router as the store runs it: the feed after each read, the cards' actions, and the switch with its hook.
@MainActor
@Suite struct RouterStore {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, turns: Int, focused: Double = -60, summary: String? = "Done it") -> ClaudeSession {
        ClaudeSession(id: id, title: "Session \(id)", folder: "/code/app", completedTurns: turns,
                      lastActivity: now.addingTimeInterval(-60), lastFocused: now.addingTimeInterval(focused * 60),
                      lastUserMessage: now.addingTimeInterval(-120), summary: summary.map { .init(blocked: false, detail: $0) },
                      cliID: "cli-\(id)")
    }

    /// Sessions and Router on, the Router's files in `dir`, every session seen once.
    private func store(_ dir: TempDir, _ sessions: [ClaudeSession]) -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Lookout.app/Contents/MacOS/Lookout"
        s.interceptOpen = { _ in }
        s.claudeIsFrontmost = { false }
        s.claudeLink = .ok
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: [], claudeFrontmost: false, now: now)
        s.setRouterEnabled(true, now: now)
        return s
    }

    @Test func theFeedMakesCardsFromWhatTheStoreRead() async {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1), session("local_b", turns: 1)])
        await s.routerHookWork?.value
        var fresh: [RouterCard] = []
        s.onNewRouterCards = { fresh += $0 }
        #expect(s.router.cards.isEmpty)
        s.ingest([session("local_a", turns: 2), session("local_b", turns: 2, summary: nil)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(1))
        #expect(fresh.map(\.id).sorted() == ["local_a#t2", "local_b#t2"])
        #expect(s.routerCounts.done == 2 && s.routerCounts.needsYou == 0)

        // Not again for the same read; nothing while the sessions extension is off.
        fresh = []
        s.feedRouter(now: now.addingTimeInterval(2))
        #expect(fresh.isEmpty)
        s.agents.enabled = false
        s.ingest([session("local_a", turns: 3)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(3))
        #expect(s.router.cards.count == 2)
    }

    @Test func cardsAreListedOpenFirstNewestFirstAndCanBeMarked() async {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1), session("local_b", turns: 1)])
        await s.routerHookWork?.value
        s.ingest([session("local_a", turns: 2), session("local_b", turns: 1)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(1))
        s.ingest([session("local_a", turns: 2), session("local_b", turns: 2)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(2))
        #expect(s.routerCards.map(\.id) == ["local_b#t2", "local_a#t2"])
        s.setCardAddressed("local_b#t2", true, now: now.addingTimeInterval(3))
        #expect(s.routerCards.map(\.id) == ["local_a#t2", "local_b#t2"])
        #expect(s.openRouterCards.map(\.id) == ["local_a#t2"])
        #expect(s.router.cards.first { $0.id == "local_b#t2" }?.addressedBy == .you)
        s.setCardAddressed("local_b#t2", false)
        #expect(s.openRouterCards.count == 2)

        s.addressCards(forSession: "local_b", by: .router)
        #expect(s.router.cards.first { $0.id == "local_b#t2" }?.addressedBy == .router)
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        s.openCard("local_a#t2")
        #expect(opened == ["Open in Claude · Session local_a"])
        #expect(s.router.cards.first { $0.id == "local_a#t2" }?.addressedBy == .opened)
        #expect(s.openRouterCards.isEmpty)
    }

    @Test func switchingItOnInstallsTheHookAndOffRemovesIt() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        let installer = FormHookInstaller(claudeDir: paths.claudeDir)
        #expect(s.routerHookStatus == .installed && s.routerHookError == nil)
        #expect(installer.status(executable: "/Applications/Lookout.app/Contents/MacOS/Lookout") == .installed)
        #expect(FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))
        #expect(s.router.enabled && s.router.enabledAt == now)

        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        #expect(s.routerHookStatus == .notInstalled && s.routerHookError == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.forms.appendingPathComponent(".enabled").path))
        #expect(!FileManager.default.fileExists(atPath: installer.script.path))
    }

    @Test func aHookThatCantBeInstalledSaysWhy() async throws {
        let dir = TempDir()
        try FileManager.default.createDirectory(at: dir.path("claude"), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.path("claude/settings.json"))
        let s = store(dir, [])
        await s.routerHookWork?.value
        #expect(s.routerHookError?.contains("valid JSON") == true)
        #expect(s.routerHookStatus == .notInstalled)
        #expect(try Data(contentsOf: dir.path("claude/settings.json")) == Data("{ nope".utf8))
    }

    @Test func atLaunchAnOutdatedHookIsInstalledAgain() async throws {
        let dir = TempDir()
        let s = store(dir, [])
        await s.routerHookWork?.value
        let installer = FormHookInstaller(claudeDir: dir.path("claude"))
        // The app moved.
        let moved = Store()
        moved.persists = false
        moved.routerPaths = s.routerPaths
        moved.routerExecutable = "/Users/me/Applications/Lookout.app/Contents/MacOS/Lookout"
        moved.router.enabled = true
        moved.startRouter()
        await moved.routerHookWork?.value
        #expect(installer.status(executable: "/Users/me/Applications/Lookout.app/Contents/MacOS/Lookout") == .installed)
        #expect(moved.routerHookStatus == .installed)

        // Not installed (you took it out yourself): launch leaves it so.
        try installer.uninstall()
        let again = Store()
        again.persists = false
        again.routerPaths = s.routerPaths
        again.routerExecutable = moved.routerExecutable
        again.router.enabled = true
        again.startRouter()
        await again.routerHookWork?.value
        #expect(again.routerHookStatus == .notInstalled)
    }

    @Test func pendingFormsArePublishedForTheirCards() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        let forms = try #require(s.routerPaths?.forms)
        s.formBridge.isAlive = { _ in true }
        let pending: [String: Any] = ["key": "cli-local_a-1-1", "session_id": "cli-local_a", "transcript_path": "",
                                      "tool_input": sampleInput, "created_at": 1, "pid": 1]
        try JSONSerialization.data(withJSONObject: pending).write(to: forms.appendingPathComponent("cli-local_a-1-1.json"))
        s.formBridge.refresh()
        await waitUntil { !s.pendingForms.isEmpty }
        #expect(s.pendingForms["cli-local_a"]?.questions.count == 2)
        let form = try #require(s.pendingForms["cli-local_a"])
        try s.formBridge.answer(form, answers: ["Which database?": "SQLite", "Which features?": "Auth"])
        #expect(FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: forms).path))

        s.setRouterEnabled(false)
        #expect(s.pendingForms.isEmpty)
    }

    private func asking(_ s: Store, _ id: String, since: Date, call: String = "toolu_1", turns: Int = 1) {
        var running = session(id, turns: turns)
        running.running = true
        running.summary = nil
        s.ingest([running], appUnread: [], claudeFrontmost: false, now: now)
        s.claudeActivity = [id: ClaudeActivity(text: "Which one?", since: since, waitsForYou: true, tool: "AskUserQuestion",
                                               toolUseID: call)]
    }

    /// The hook holds a form for `call` (nil: not found yet): written to the forms folder and read back by the bridge when
    /// the store has one running, else set directly.
    private func form(_ s: Store, call: String?, key: String = "k") async {
        guard s.router.enabled, let forms = s.routerPaths?.forms else {
            s.routerFormsLoaded = true
            s.pendingForms = ["cli-local_a": PendingForm(id: key, cliSessionID: "cli-local_a", transcriptPath: "",
                                                         questions: [.init(question: "Q?", header: "", multiSelect: false, options: [])],
                                                         createdAt: now, pid: 1, toolUseID: call)]
            return
        }
        await release(s)
        var record: [String: Any] = ["key": key, "session_id": "cli-local_a", "tool_input": sampleInput, "created_at": 1,
                                     "pid": Int(getpid())]
        record["tool_use_id"] = call
        try! JSONSerialization.data(withJSONObject: record).write(to: forms.appendingPathComponent("\(key).json"))
        s.formBridge.refresh()
        await waitUntil { s.pendingForms["cli-local_a"]?.id == key }
    }

    /// The hook lets go of every form.
    private func release(_ s: Store) async {
        guard let forms = s.routerPaths?.forms else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: forms, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
        s.formBridge.refresh()
        await waitUntil { s.pendingForms.isEmpty && s.routerFormsLoaded }
    }

    @Test func aFormBelongsOnlyToTheCardOfItsOwnCall() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        // The form is published before the activity read that makes the card: it binds once the card is there.
        await form(s, call: "toolu_1", key: "first")
        s.feedRouter(now: now.addingTimeInterval(9))
        #expect(s.openRouterCards.isEmpty)
        asking(s, "local_a", since: now.addingTimeInterval(10), call: "toolu_1")
        s.feedRouter(now: now.addingTimeInterval(11))
        let firstCard = try #require(s.openRouterCards.first)
        #expect(firstCard.toolUseID == "toolu_1" && s.pendingForm(for: firstCard)?.id == "first")
        // A form whose call the hook hasn't found yet isn't answerable.
        await form(s, call: nil, key: "unpinned")
        #expect(s.pendingForm(for: firstCard) == nil)

        // The same question asked again: a new call, a new card; each card only takes its own call's form.
        asking(s, "local_a", since: now.addingTimeInterval(20), call: "toolu_2")
        s.feedRouter(now: now.addingTimeInterval(21))
        await form(s, call: "toolu_2", key: "second")
        let old = try #require(s.router.cards.first { $0.id == firstCard.id })
        let current = try #require(s.openRouterCards.first)
        #expect(current.text == old.text && current.toolUseID == "toolu_2")
        #expect(s.pendingForm(for: old) == nil && s.pendingForm(for: current)?.id == "second")
        s.setCardAddressed(old.id, false)
        let reopened = try #require(s.router.cards.first { $0.id == firstCard.id })
        #expect(s.pendingForm(for: reopened) == nil)
        await form(s, call: "toolu_1", key: "stale")
        #expect(s.pendingForm(for: reopened)?.id == "stale")
        #expect(s.router.cards.first { $0.id == current.id }.map { s.pendingForm(for: $0) } == .some(nil))
    }

    /// A relaunch: the router's saved state has the question; the sessions and the forms come back in either order, and the
    /// session no longer counts as running (no activity is read for it).
    @Test(arguments: [true, false]) func aRelaunchKeepsTheQuestionAndItsForm(formsFirst: Bool) async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        asking(s, "local_a", since: now.addingTimeInterval(10), call: "toolu_1")
        s.feedRouter(now: now.addingTimeInterval(11))
        await form(s, call: "toolu_1")
        s.feedRouter(now: now.addingTimeInterval(12))
        let saved = s.router

        let next = Store()
        next.persists = false
        next.claudeIsFrontmost = { false }
        next.router = saved
        next.agents = s.agents
        let idle = session("local_a", turns: 1, summary: nil)
        func sessionsArrive() async {
            next.claudeLink = .ok
            next.ingest([idle], appUnread: [], claudeFrontmost: false, now: now)
            next.feedRouter(now: now.addingTimeInterval(7300))
        }
        func formsArrive() async {
            await form(next, call: "toolu_1")
            next.feedRouter(now: now.addingTimeInterval(7301))
        }
        if formsFirst { await formsArrive(); await sessionsArrive() } else { await sessionsArrive(); await formsArrive() }
        let card = try #require(next.openRouterCards.first)
        #expect(card.kind == .question && next.router.waits["local_a"] == card.waitMs)
        #expect(next.pendingForm(for: card)?.id == "k")
    }

    @Test func viewingIsAskedAfreshAtEachFeed() async {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        // The last full read saw the app in front, on this session; then you went to another app.
        var front = true
        s.claudeIsFrontmost = { front }
        s.ingest([session("local_a", turns: 1)], appUnread: [], claudeFrontmost: true, now: now)
        front = false
        // Only the activity changes (no full read): the question is carded.
        asking(s, "local_a", since: now.addingTimeInterval(5))
        s.feedRouter(now: now.addingTimeInterval(6))
        #expect(s.openRouterCards.map(\.kind) == [.question])

        // Watching it in the app: no card.
        front = true
        s.ingest([session("local_a", turns: 2, focused: 1)], appUnread: [], claudeFrontmost: true, now: now)
        s.claudeActivity = [:]
        s.feedRouter(now: now.addingTimeInterval(7))
        #expect(s.router.cards.count == 1)
    }

    @Test func reopeningSupersedesTheNewerCardInOneChange() async {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        s.ingest([session("local_a", turns: 2)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(1))
        s.ingest([session("local_a", turns: 3)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(2))
        let revision = s.routerRevision
        s.setCardAddressed("local_a#t2", false)
        #expect(s.routerRevision == revision + 1)
        #expect(s.openRouterCards.map(\.id) == ["local_a#t2"])
        #expect(s.router.cards.first { $0.id == "local_a#t3" }?.addressedBy == .superseded)
    }

    @Test func turningItOffAndOnSettlesWhatHappenedMeanwhile() async {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1), session("local_b", turns: 1)])
        await s.routerHookWork?.value
        s.ingest([session("local_a", turns: 2), session("local_b", turns: 2)], appUnread: [], claudeFrontmost: false, now: now)
        s.feedRouter(now: now.addingTimeInterval(1))
        #expect(s.openRouterCards.count == 2)
        s.setRouterEnabled(false)
        // Off: you open a in the app; b's turn stays unseen.
        s.ingest([session("local_a", turns: 2, focused: 1), session("local_b", turns: 2)], appUnread: [], claudeFrontmost: false, now: now)
        s.setRouterEnabled(true, now: now.addingTimeInterval(120))
        await s.routerHookWork?.value
        #expect(s.openRouterCards.map(\.id) == ["local_b#t2"])
        #expect(s.router.cards.first { $0.id == "local_a#t2" }?.addressedBy == .opened)
    }

    @Test func aFormGoingAwayAnswersItsCard() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        asking(s, "local_a", since: now.addingTimeInterval(10))
        s.feedRouter(now: now.addingTimeInterval(11))
        await form(s, call: "toolu_1")
        // Past the running timeout: the session isn't running, its form is still held.
        s.ingest([session("local_a", turns: 1, summary: nil)], appUnread: [], claudeFrontmost: false, now: now)
        s.claudeActivity = [:]
        s.feedRouter(now: now.addingTimeInterval(7300))
        #expect(s.openRouterCards.map(\.kind) == [.question])
        await release(s)
        s.feedRouter(now: now.addingTimeInterval(7301))
        #expect(s.openRouterCards.isEmpty)
        #expect(s.router.cards.first?.addressedBy == .answered)
    }

    @Test func turningItOnWithAnIdleSessionAndALiveFormKeepsTheWait() async throws {
        let dir = TempDir()
        let s = store(dir, [session("local_a", turns: 1)])
        await s.routerHookWork?.value
        asking(s, "local_a", since: now.addingTimeInterval(10))
        s.feedRouter(now: now.addingTimeInterval(11))
        await form(s, call: "toolu_1")
        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        s.ingest([session("local_a", turns: 1, summary: nil)], appUnread: [], claudeFrontmost: false, now: now)
        s.claudeActivity = [:]
        s.setRouterEnabled(true, now: now.addingTimeInterval(7300))
        await s.routerHookWork?.value
        // The hook still holds the form: the bridge reads it again.
        await waitUntil { !s.pendingForms.isEmpty }
        s.feedRouter(now: now.addingTimeInterval(7301))
        let card = try #require(s.openRouterCards.first)
        #expect(card.kind == .question && s.router.waits["local_a"] == card.waitMs && s.pendingForm(for: card) != nil)
    }
}
