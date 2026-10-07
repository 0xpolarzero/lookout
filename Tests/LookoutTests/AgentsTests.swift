import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Agents {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(_ id: String, turns: Int = 3, minutesAgo: Double = 5, messageMinutesAgo: Double? = nil,
                         focusedMinutesAgo: Double? = 60, folder: String? = "/code/app", blocked: Bool = false,
                         running: Bool = false, archived: Bool = false) -> ClaudeSession {
        ClaudeSession(id: id, title: "Session \(id)", folder: folder, isArchived: archived, completedTurns: turns,
                      lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                      lastFocused: focusedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                      lastUserMessage: now.addingTimeInterval(-(messageMinutesAgo ?? minutesAgo + 1) * 60),
                      summary: running ? nil : .init(blocked: blocked, detail: "Detail \(id)"), running: running)
    }

    /// A store that has already seen `sessions` once (seeded), so later reads are "new activity".
    private func store(_ sessions: [ClaudeSession], dots: Set<String> = []) -> Store {
        let s = Store()
        s.persists = false
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: dots, claudeFrontmost: false, now: now)
        return s
    }

    private func entry(_ s: Store, _ id: String) -> AgentEntry? { s.agents.entries.first { $0.id == id } }

    @Test func searchShowsTheSavedLabelOfAHiddenSession() {
        let s = store([session("a"), session("b")])
        s.setAgentLabel("a", "🔥")
        s.dismissAgent("a")
        #expect(s.agentRows.pending.map(\.id) == ["b"])
        #expect(s.searchSessions("session").first { $0.id == "a" }?.label == "🔥")
    }

    @Test func aLabelOnAnOldSessionFoundThroughSearchIsKept() {
        let s = store([session("a"), session("old", minutesAgo: 3 * 24 * 60)])
        s.setAgentLabel("old", "🔥")
        #expect(s.searchSessions("session old").first?.label == "🔥")
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func aLabelOnAnOldSessionSurvivesTheNextRefresh() {
        let old = session("old", minutesAgo: 45 * 24 * 60)
        let s = store([session("a"), old])
        s.setAgentLabel("old", "🔥")
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "old")?.label == "🔥")
        #expect(s.searchSessions("session old").first?.label == "🔥")
    }

    @Test func anOldSessionNobodyCustomizedIsStillForgotten() {
        let old = session("old", minutesAgo: 45 * 24 * 60)
        let s = store([session("a"), old])
        s.keepAgent("old")
        s.dismissAgent("old")
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "old") == nil)
    }

    /// Icons on and a key saved, so an icon can be asked for; the store has not read the key, so none is.
    private func keySaved(_ s: Store) {
        s.agents.iconsEnabled = true
        s.hasTypesafeKey = true
    }

    @Test func askingForAnIconOfAHiddenSessionPicksIt() {
        let s = store([session("a"), session("b")])
        s.dismissAgent("a")
        #expect(s.allAgentRows.map(\.id) == ["b"])
        keySaved(s)
        s.repickIcon("a")  // the key is not read yet, so nothing is asked for yet
        #expect(s.iconTarget()?.id == "a")
        s.agents.entries[s.agents.entries.firstIndex { $0.id == "a" }!].icon = "star"
        #expect(s.iconTarget()?.id == "b")
    }

    @Test func askingForAnIconOfAnOldSessionFoundThroughSearchPicksIt() {
        let s = store([session("a"), session("old", minutesAgo: 3 * 24 * 60)])
        #expect(entry(s, "old") == nil)
        #expect(s.searchSessions("session old").map(\.id) == ["old"])
        keySaved(s)
        s.repickIcon("old")  // the key is not read yet, so nothing is asked for yet
        #expect(s.iconTarget()?.id == "old")
        #expect(s.allAgentRows.map(\.id) == ["a"])  // still unlisted
        #expect(entry(s, "old")?.hiddenAt != nil)
    }

    /// A store that asks for icons, with the transcript and Jev stood in for: every question gets its first option.
    private func iconStore(_ sessions: [ClaudeSession], firstMessage: String? = "Fix the login form") -> Store {
        let s = store(sessions)
        s.agents.iconsEnabled = true
        s.typesafeKeyCache = "test"
        s.hasTypesafeKey = true
        s.iconFirstMessage = { _ in firstMessage }
        s.iconChooser = { options, _, _, _ in .init(choice: options[0], confidence: 1, probabilities: [options[0]: 1]) }
        return s
    }

    private func finishIcons(_ s: Store) async {
        while let task = s.iconTask { await task.value }
    }

    @Test func theIconPickedForAHiddenSessionIsKept() async {
        var hidden = session("a")
        hidden.cliID = "cli-a"
        let s = iconStore([hidden, session("b")])
        s.dismissAgent("a")
        s.repickIcon("a")
        await finishIcons(s)
        #expect(entry(s, "a")?.icon != nil)
        #expect(s.allAgentRows.map(\.id) == ["b"])
    }

    @Test func theIconPickedForAnOldSessionSurvivesTheNextRefresh() async {
        var old = session("old", minutesAgo: 45 * 24 * 60)
        old.cliID = "cli-old"
        let s = iconStore([session("a"), old])
        s.repickIcon("old")
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)  // before the icon is picked
        await finishIcons(s)
        s.ingest([session("a"), old], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "old")?.icon != nil)
    }

    @Test func theIconPickedForAnOldSessionFoundThroughSearchIsKept() async {
        var old = session("old", minutesAgo: 3 * 24 * 60)
        old.cliID = "cli-old"
        let s = iconStore([session("a"), old])
        s.repickIcon("old")
        await finishIcons(s)
        #expect(entry(s, "old")?.icon != nil)
        #expect(s.searchSessions("session old").first?.icon != nil)
        #expect(s.allAgentRows.map(\.id) == ["a"])
    }

    @Test func aSessionWithNothingToGoOnDoesNotBlockTheOthers() async {
        final class Reads: @unchecked Sendable { var ids: [String] = [] }
        let reads = Reads()
        var untitled = session("u")
        untitled.title = "Untitled session"
        untitled.cliID = "cli-u"
        let s = iconStore([untitled, session("b")])
        s.iconFirstMessage = { reads.ids.append($0); return nil }
        s.dismissAgent("u")
        s.repickIcon("u")
        await finishIcons(s)
        #expect(entry(s, "b")?.icon != nil)
        #expect(entry(s, "u")?.icon == nil)
        #expect(s.iconTarget() == nil)
        // Later reads don't look at its transcript again, until it has something new.
        s.pickIcons()
        await finishIcons(s)
        #expect(reads.ids == ["cli-u"])
        var renamed = untitled
        renamed.title = "Fix the login form"
        s.ingest([renamed, session("b")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.iconTarget()?.id == "u")
    }

    @Test func theSessionsShortcutPicksTheFirstSessionThatNeedsYou() {
        let s = store([session("done", minutesAgo: 1, running: false), session("asking", minutesAgo: 2, running: true)], dots: ["done"])
        s.keepAgent("done")
        s.keepAgent("asking")
        s.claudeActivity["asking"] = ClaudeActivity(text: "Asking you a question", since: now, waitsForYou: true)
        // Stopped on a question mid-turn counts as waiting, not as the working session it is still marked as.
        #expect(s.agentRows.kept.first { $0.id == "asking" }?.waitsForYou == true)
        #expect(s.sessionShortcutPick?.id == "done")
        // Reading the finished one leaves the question to go to, ahead of the first kept session, which needs nothing.
        s.toggleAgentRead("done")
        #expect(s.sessionShortcutPick?.id == "asking")
        // Nothing needs you: the first kept one.
        s.claudeActivity["asking"] = nil
        #expect(s.sessionShortcutPick?.id == s.agentRows.kept.first?.id)
    }

    @Test func aMutedFolderSaysSoAndMutingItAgainChangesNothing() {
        let s = store([session("a")])
        #expect(!s.isFolderMuted("/code/app"))
        s.setFolderMuted("/code/app", true)
        #expect(s.isFolderMuted("/code/app") && !s.isFolderMuted("/code/other"))
        s.setFolderMuted("/code/app", false)
        #expect(!s.isFolderMuted("/code/app"))
    }

    @Test func firstReadOffersRecentSessionsOnly() {
        let s = store([session("a", minutesAgo: 30), session("old", minutesAgo: 3 * 24 * 60)], dots: ["a"])
        #expect(s.agents.entries.map(\.id) == ["a"])
        #expect(entry(s, "a")?.kept == false)
        #expect(entry(s, "a")?.unread == true)  // the sidebar dot decides on first sight
        #expect(s.agentRows.pending.map(\.id) == ["a"])
    }

    @Test func finishedTurnMarksUnread() {
        let s = store([session("a")])
        s.toggleAgentRead("a")
        s.toggleAgentRead("a")
        #expect(entry(s, "a")?.unread == false)
        s.ingest([session("a", turns: 4, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
    }

    @Test func finishedWhileYouWatchItStaysRead() {
        let s = store([session("a", focusedMinutesAgo: 10), session("b", focusedMinutesAgo: 50)])
        s.ingest([session("a", turns: 4, minutesAgo: 0, focusedMinutesAgo: 10), session("b", focusedMinutesAgo: 50)],
                 appUnread: [], claudeFrontmost: true, now: now)
        #expect(entry(s, "a")?.unread == false)
    }

    @Test func sendingAMessageOrOpeningItMarksRead() {
        let s = store([session("a"), session("b")], dots: ["a", "b"])
        // A new message (running, no new finished turn).
        s.ingest([session("a", messageMinutesAgo: 0, running: true), session("b")], appUnread: ["a", "b"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // Focused in the app.
        s.ingest([session("a", messageMinutesAgo: 0, running: true), session("b", focusedMinutesAgo: 1)],
                 appUnread: ["a", "b"], claudeFrontmost: true, now: now)
        #expect(entry(s, "b")?.unread == false)
    }

    @Test func sidebarDotChangesWinButYourChoiceStandsOtherwise() {
        let s = store([session("a")], dots: [])
        s.ingest([session("a")], appUnread: ["a"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
        // Marked read in Lookout: the app still shows the dot, unchanged, so Lookout keeps your choice.
        s.toggleAgentRead("a")
        s.ingest([session("a")], appUnread: ["a"], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // Marked unread here, then the app clears its dot: read again.
        s.toggleAgentRead("a")
        s.ingest([session("a")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == false)
        // Unreadable dots (nil) change nothing.
        s.toggleAgentRead("a")
        s.ingest([session("a")], appUnread: nil, claudeFrontmost: false, now: now)
        #expect(entry(s, "a")?.unread == true)
    }

    @Test func dismissedPendingComesBackOnNewActivity() {
        let s = store([session("a")])
        s.dismissAgent("a")
        #expect(s.agentRows.pending.isEmpty)
        s.ingest([session("a")], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.agentRows.pending.isEmpty)
        s.ingest([session("a", turns: 4, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.agentRows.pending.map(\.id) == ["a"])
    }

    @Test func removedKeptSessionReturnsAsPending() {
        let s = store([session("a")])
        s.keepAgent("a")
        #expect(s.agentRows.kept.map(\.id) == ["a"])
        s.dismissAgent("a")
        #expect(s.agentRows.kept.isEmpty && s.agentRows.pending.isEmpty)
        s.ingest([session("a", turns: 4, minutesAgo: 0)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.agentRows.kept.isEmpty)
        #expect(s.agentRows.pending.map(\.id) == ["a"])
    }

    @Test func archivedSessionsLeave() {
        let s = store([session("a")])
        s.keepAgent("a")
        s.ingest([session("a", archived: true)], appUnread: [], claudeFrontmost: false, now: now)
        #expect(s.agents.entries.isEmpty)
        #expect(s.agentRows.kept.isEmpty)
    }

    @Test func newSessionsAfterSeedingArePendingUnlessMuted() {
        let s = store([session("a")])
        s.setFolderMuted("", true)  // scratch chats
        s.ingest([session("a"), session("new", minutesAgo: 0), session("chat", minutesAgo: 0, folder: nil)],
                 appUnread: [], claudeFrontmost: false, now: now)
        #expect(Set(s.agentRows.pending.map(\.id)) == ["a", "new"])
        #expect(entry(s, "new")?.unread == true)
        #expect(entry(s, "chat") == nil)
        // Old sessions with nothing new stay out.
        s.ingest([session("a"), session("new", minutesAgo: 0), session("stale", minutesAgo: 600)],
                 appUnread: [], claudeFrontmost: false, now: now)
        #expect(entry(s, "stale") == nil)
    }

    @Test func keepingAKeptSessionLeavesItsPlace() {
        let s = store([session("a"), session("b")])
        s.keepAgent("a")
        s.keepAgent("b")
        s.keepAgent("a")
        #expect(s.agentRows.kept.map(\.id) == ["a", "b"])
    }

    @Test func theAgeVoiceOverHearsIsTheOneTheRowShowsAndMovesWithTheClock() throws {
        let s = store([session("f", minutesAgo: 4), session("w", messageMinutesAgo: 2, running: true)])
        let rows = s.allAgentRows
        let finished = try #require(rows.first { $0.id == "f" }), working = try #require(rows.first { $0.id == "w" })
        #expect(finished.statusText(now: now) == "4m" && finished.spokenValue(now: now) == "pending, app, 4 minutes")
        #expect(working.workingText(now: now).hasSuffix("2m") && working.spokenValue(now: now) == "working, app, 2 minutes")
        // Three minutes on, both say it: the value is not the one the row was drawn with.
        let later = now.addingTimeInterval(180)
        #expect(finished.statusText(now: later) == "7m" && finished.spokenValue(now: later) == "pending, app, 7 minutes")
        #expect(working.workingText(now: later).hasSuffix("5m") && working.spokenValue(now: later) == "working, app, 5 minutes")
        #expect(AgentRow.spokenAge(20) == "just now" && AgentRow.spokenAge(3600) == "1 hour" && AgentRow.spokenAge(2 * 86400) == "2 days")
    }

    @Test func aFinishedSessionSpeaksHowManyCommandsItLeftRunningAndTheirNames() throws {
        let s = store([session("f", minutesAgo: 4)])
        s.claudeTasks = ["f": [ClaudeTask(id: "a", kind: .agent, title: "Review the changes", since: now),
                               ClaudeTask(id: "b", kind: .command, title: "Run the full test suite", since: now)]]
        let row = try #require(s.allAgentRows.first { $0.id == "f" })
        #expect(row.spokenValue(now: now) == "pending, 2 running, app, 4 minutes")
        #expect(row.spokenHint == "Opens it in Claude. Running: Review the changes, Run the full test suite.")
        // Nothing left running: neither says anything of it.
        s.claudeTasks = [:]
        let clear = try #require(s.allAgentRows.first { $0.id == "f" })
        #expect(!clear.spokenValue(now: now).contains("running") && clear.spokenHint == "Opens it in Claude")
    }

    @Test func sessionsOfSameNamedProjectsSayWhichProjectTheyAreIn() throws {
        let s = store([session("a", folder: "/customer-a/app"), session("b", folder: "/customer-b/app")])
        let rows = s.allAgentRows
        let a = try #require(rows.first { $0.id == "a" }), b = try #require(rows.first { $0.id == "b" })
        #expect(a.projectName == "customer-a/app" && b.projectName == "customer-b/app")
        #expect(s.searchSessions("customer-b").map(\.id) == ["b"])
        // Same title, same state: VoiceOver still tells them apart by project, wherever a session is shown.
        #expect(a.stateName == b.stateName && a.spokenValue() != b.spokenValue())
        #expect(a.spokenValue().contains("customer-a/app") && b.spokenValue().contains("customer-b/app"))
        // The name follows the folders: with the other project gone, the folder's own name is enough again.
        s.claudeSessions["a"] = nil
        #expect(s.folderName("/customer-b/app") == "app")
        #expect(try #require(s.allAgentRows.first).projectName == "app")
        // A muted project still tells a session's project from another of its name.
        s.setFolderMuted("/customer-a/app", true)
        #expect(s.folderName("/customer-b/app") == "customer-b/app")
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

    @Test func aRejectedTypesafeKeyIsAnnouncedWhereItHappensAndOnceWhenSettingsShowsIt() {
        let s = store([session("a")])
        var said: [String] = []
        Announce.reset()
        Announce.sink = { said.append($0) }
        defer { Announce.reset() }
        // Settings is closed: the rejection is still said, and picking waits for a new key.
        s.iconPickFailed(JevClient.Failure(message: "Invalid API key"))
        #expect(said == ["Invalid API key"] && s.iconsPausedUntil == .distantFuture)
        // Settings opened on it says the same line: not twice.
        Announce.say(s.iconError ?? "")
        #expect(said == ["Invalid API key"])
        // Another failure is retried later and not announced from here (Settings says it if it is open).
        s.iconPickFailed(JevClient.Failure(message: "TypeSafe is down"))
        #expect(said == ["Invalid API key"] && s.iconsPausedUntil < .distantFuture)
        // What Settings shows about a refused save is said by Settings alone, once.
        s.keychainWrite = { _, _ in false }
        #expect(!s.setTypesafeKey("sk-test"))
        Announce.say(s.iconError ?? "")
        #expect(said == ["Invalid API key", "Couldn't save the key in the Keychain"])
    }

    @Test func keptOrderAndReorder() {
        let s = store([session("a"), session("b"), session("c")])
        s.keepAgent("b")
        s.keepAgent("a")
        s.keepAgent("c")
        #expect(s.agentRows.kept.map(\.id) == ["b", "a", "c"])
        s.moveAgent("c", onto: "b")
        #expect(s.agentRows.kept.map(\.id) == ["c", "b", "a"])
    }

    @Test func searchAndKeepAnySession() {
        var old = session("old", minutesAgo: 3 * 24 * 60, folder: "/code/lookout")
        old.title = "Agent completion notifications"
        let s = store([session("a"), old])
        #expect(entry(s, "old") == nil)  // too old to be offered as pending
        #expect(s.agentCandidates(matching: "agent notif").map(\.id) == ["old"])
        #expect(s.agentCandidates(matching: "lookout").map(\.id) == ["old"])
        #expect(s.agentCandidates(matching: "").map(\.id) == ["a", "old"])
        s.keepAgent("old")
        #expect(s.agentRows.kept.map(\.id) == ["old"])
        #expect(s.agentCandidates(matching: "agent").isEmpty)
    }

    @Test func keptSessionsGroupByProject() {
        let s = store([session("a", folder: "/code/x"), session("b", folder: "/code/y"), session("c", folder: "/code/x")])
        for id in ["a", "b", "c"] { s.keepAgent(id) }
        #expect(s.agentRows.kept.map(\.id) == ["a", "c", "b"])
        #expect(s.groups(s.agentRows.kept).map { $0.map(\.id) } == [["a", "c"], ["b"]])
        // Each project got its own colour.
        #expect(s.agents.folderColors["/code/x"] != s.agents.folderColors["/code/y"])
        #expect(s.agentRows.kept.first?.color != nil)
    }

    @Test func searchFindsAnySessionKeptFirst() {
        var other = session("other", minutesAgo: 1, folder: "/code/sandbox")
        other.title = "Storage directory"
        var mine = session("mine", minutesAgo: 50)
        mine.title = "Sandbox on Linux"
        let s = store([other, mine])
        s.keepAgent("mine")
        #expect(s.searchSessions("sand").map(\.id) == ["mine", "other"])  // title prefix and kept first
        #expect(s.searchSessions("sto dir").map(\.id) == ["other"])
        #expect(s.searchSessions("").isEmpty)
    }

    @Test func aSearchListsEverySessionThatMatchesNotTheFirstEight() {
        let s = store((0..<12).map { session("n\($0)", minutesAgo: Double($0 + 1)) })
        let hub = HubState()
        hub.query = "Session"
        #expect(s.searchSessions("Session").count == 12 && s.hubSessions(hub).count == 12)
        #expect(s.searchSessions("Session n11").map(\.id) == ["n11"])
        // The oldest of them is reachable by the keys, so is a count of them.
        #expect(s.hubTargets(hub).contains("a:n11"))
    }

    @Test func countsSplitBlockedFromDone() {
        let s = store([session("a", blocked: true), session("b"), session("c"), session("d", running: true)], dots: ["a", "b", "d"])
        let counts = s.agentCounts
        #expect(counts.blocked == 1)
        #expect(counts.done == 1)
    }

    @Test func oldStateFilesStillLoad() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"repos":[],"items":[],"ci":{},"settings":{"botHandles":[],"treatAppsAsBots":true,"pollInterval":60,"notifications":true,"reviewRequests":true,"didInitialReviewSync":true}}"#.utf8))
        #expect(state.agents == nil)
        let partial = try JSONDecoder().decode(AgentsState.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled && !partial.expanded && partial.entries.isEmpty)
    }
}

@Suite struct AgentLabels {
    @Test func initialsThenAlternativesWhenTaken() {
        #expect(AgentLabel.candidates("CI failure diagnosis").first == "CF")
        #expect(AgentLabel.candidates("Fix the CI").first == "FC")  // "the" skipped
        let labels = AgentLabel.assign([(id: "1", title: "Lookout agents", custom: nil),
                                        (id: "2", title: "Lookout auth", custom: nil),
                                        (id: "3", title: "Anything", custom: "LA")])
        #expect(labels["3"] == "LA")
        #expect(Set(labels.values).count == 3)
        #expect(labels["1"] != "LA" && labels["2"] != "LA")
    }

    @Test func lettersSkipTheProjectName() {
        #expect(AgentLabel.candidates("LCU update notifications", folder: "lcu").first == "UN")
        #expect(AgentLabel.candidates("LCU computer use", folder: "lcu-research").first == "CU")
        #expect(AgentLabel.candidates("Lookout", folder: "lookout").first == "LO")  // nothing else to use
    }

    @Test func singleWordAndEmptyTitles() {
        let labels = AgentLabel.assign([(id: "1", title: "Zed", custom: nil), (id: "2", title: "", custom: nil),
                                        (id: "3", title: "", custom: nil)])
        #expect(labels["1"] == "ZE")
        #expect(labels["2"] != labels["3"])
    }

    @Test func sanitizeKeepsTwoLettersOrOneEmoji() {
        #expect(AgentLabel.sanitize(" ab c ") == "AB")
        #expect(AgentLabel.sanitize("🐧 linux") == "🐧")
        #expect(AgentLabel.sanitize("1") == "1")
        #expect(AgentLabel.sanitize("   ") == nil)
    }
}

@Suite struct ClaudeFiles {
    private func json(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }

    @Test func decodesFinishedSessionWithItsSummary() {
        let s = Claude.decodeSession(json([
            "sessionId": "local_1", "title": "Fix CI", "cwd": "/code/app/.claude/worktrees/x", "gitAnchorsFolderRealpath": "/code/app",
            "completedTurns": 3, "lastActivityAt": 1_700_000_000_000.0, "latestUserFrameAt": 1_699_999_000_000.0,
            "postTurnSummary": ["status_category": "blocked", "status_detail": " Which one? "],
            "postTurnSummaryFor": "u1", "lastAssistantUuid": "u1", "someNewField": ["x": 1],
        ]))
        #expect(s?.folder == "/code/app")
        #expect(s?.folderName == "app")
        #expect(s?.summary == .init(blocked: true, detail: "Which one?"))
        #expect(s?.running == false)
    }

    @Test func runningWhileTheSummaryLagsBehind() {
        let now = Date()
        let s = Claude.decodeSession(json([
            "sessionId": "local_2", "latestUserFrameAt": now.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
            "postTurnSummary": ["status_category": "review_ready"], "postTurnSummaryFor": "old", "lastAssistantUuid": "new",
            "cwd": "/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
        ]), now: now)
        #expect(s?.running == true)
        #expect(s?.summary == nil)
        #expect(s?.folder == nil)
        #expect(s?.title == "Untitled session")
        // A turn that started hours ago with no summary died with the app.
        let stale = Claude.decodeSession(json([
            "sessionId": "local_3", "latestUserFrameAt": now.addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000,
        ]), now: now)
        #expect(stale?.running == false)
    }

    @Test func activityIsTheLastStep() {
        func line(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! }
        let tool = line(["type": "assistant", "timestamp": "2026-10-05T08:33:04.292Z",
                         "message": ["content": [["type": "thinking"], ["type": "tool_use", "name": "Bash",
                                                                         "input": ["command": "swift test", "description": "Run the tests"]]]]])
        let result = line(["type": "user", "timestamp": "2026-10-05T08:33:09.000Z", "message": ["content": [["type": "tool_result"]]]])
        let other = line(["type": "attachment"])
        let running = Claude.activity(tail: Data(("partial line\n" + tool + "\n" + other + "\n").utf8))
        #expect(running?.text == "Run the tests")
        #expect(Claude.activity(tail: Data((tool + "\n" + result + "\n").utf8))?.text == "Thinking")
        let question = line(["type": "assistant", "timestamp": "2026-10-05T08:40:00.000Z",
                             "message": ["content": [["type": "tool_use", "name": "AskUserQuestion", "input": [:]]]]])
        #expect(Claude.activity(tail: Data((question + "\n").utf8))?.waitsForYou == true)
        #expect(running?.waitsForYou == false)
        // What it asks is what the row says; the generic phrase only when the input has nothing to say.
        #expect(Claude.activity(tail: Data((question + "\n").utf8))?.text == "Asking you a question")
        #expect(Claude.describe(tool: "AskUserQuestion", input: ["questions": [["question": "Which tone should the notes take?"], ["question": "Second"]]])
                == "Which tone should the notes take?")
        #expect(Claude.describe(tool: "ExitPlanMode", input: ["plan": "\n## Ship the redesign\n\n1. Build it"]) == "Approve the plan: Ship the redesign")
        #expect(Claude.describe(tool: "ExitPlanMode", input: [:]) == "Waiting for you to approve a plan")
        #expect(Claude.describe(tool: "Edit", input: ["file_path": "/a/b/PillView.swift"]) == "Editing PillView.swift")
        #expect(Claude.describe(tool: "mcp__lcu__js", input: [:]) == "Using lcu")
        #expect(Claude.describe(tool: "Bash", input: ["command": "git status --short"]) == "Running git status --short")
    }

    @Test func endNoticesCutAtAScanBoundaryAreStillFound() {
        let full = Data("xx<task-id>a2</task-id>yy".utf8)
        var ended = Set<String>()
        for cut in 1..<full.count {
            ended = []
            let first = full.prefix(cut)
            let next = Claude.scanEnds(Data(first), base: 0, into: &ended)
            Claude.scanEnds(Data(full[next...]), base: next, into: &ended)
            #expect(ended == ["a2"], "cut at \(cut)")
        }
    }

    @Test func backgroundTasks() throws {
        // Like Claude Code writes them: slashes as they are.
        func line(_ obj: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: obj, options: .withoutEscapingSlashes), encoding: .utf8)!
        }
        let fm = FileManager.default
        // Resolved, as the system reports open files (/var is a link to /private/var).
        let temp = URL(fileURLWithPath: realpath(fm.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory())
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let subagents = root.appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: tasks, withIntermediateDirectories: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)

        // Two subagents (one announced as finished) and two commands (one still has its output open).
        for id in ["a1", "a2"] {
            let transcript = subagents.appendingPathComponent("agent-\(id).jsonl")
            try Data((line(["type": "assistant", "timestamp": "2026-10-05T08:33:04.292Z", "message": ["content": [
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/x/Agents.swift"]]]]]) + "\n").utf8).write(to: transcript)
            try Data(#"{"description":"Review \#(id)","requestShape":"background"}"#.utf8)
                .write(to: subagents.appendingPathComponent("agent-\(id).meta.json"))
            try fm.createSymbolicLink(at: tasks.appendingPathComponent("\(id).output"), withDestinationURL: transcript)
        }
        for id in ["b1", "b2"] { try Data().write(to: tasks.appendingPathComponent("\(id).output")) }
        let parent = root.appendingPathComponent("session.jsonl")
        try Data([
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "toolu_1", "name": "Bash",
                                                                 "input": ["command": "swift build", "description": "Build the app"]]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                                            "content": "Command running in background with ID: b1. Output is being written to: …"]]]]),
            line(["type": "queue-operation", "content": "<task-notification>\n<task-id>a2</task-id>\n<status>completed</status>"]),
        ].joined(separator: "\n").utf8).write(to: parent)

        let reader = Claude.TaskReader()
        let open: Set<String> = [tasks.appendingPathComponent("b1.output").path]
        let later = Date().addingTimeInterval(60)
        let found = reader.tasks(in: tasks, transcript: parent, openOutputs: open, now: later)
        #expect(found.map(\.id).sorted() == ["a1", "b1"])
        #expect(found.first { $0.id == "a1" }?.kind == .agent)
        #expect(found.first { $0.id == "a1" }?.title == "Review a1")
        #expect(found.first { $0.id == "a1" }?.activity?.text == "Reading Agents.swift")
        #expect(found.first { $0.id == "b1" }?.kind == .command)
        #expect(found.first { $0.id == "b1" }?.title == "Build the app")
        // The command ends: its output is closed, and it stays finished.
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: [], now: later).map(\.id) == ["a1"])
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: open, now: later).map(\.id) == ["a1"])
        // A subagent whose transcript went quiet long ago died with its session.
        #expect(reader.tasks(in: tasks, transcript: parent, openOutputs: [], now: later.addingTimeInterval(Claude.agentTimeout)).isEmpty)
    }

    @Test func runningCommandsHoldTheirOutputOpen() throws {
        let fm = FileManager.default
        // A folder of its own, not Claude's.
        let made = fm.temporaryDirectory.appendingPathComponent("lookout-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: made.appendingPathComponent("p/s/tasks", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: made) }
        // The system names a file by its real path (/private/var, not /var).
        let root = URL(fileURLWithPath: made.path.withCString { realpath($0, nil).map { String(cString: $0) } } ?? made.path)
        let folder = root.appendingPathComponent("p/s/tasks", isDirectory: true)
        let output = folder.appendingPathComponent("b1.output")
        fm.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = try FileHandle(forWritingTo: output)
        try process.run()
        #expect(Claude.openTaskOutputs(under: root).contains(output.path))
        process.terminate()
        process.waitUntilExit()
        #expect(!Claude.openTaskOutputs(under: root).contains(output.path))
    }

    @Test func rejectsOtherFiles() {
        #expect(Claude.decodeSession(json(["scheduledTasks": []])) == nil)
        #expect(Claude.decodeSession(Data("not json".utf8)) == nil)
    }

    @Test func parsesTheSidebarDots() {
        let value = [UInt8(1)] + Array(#"{"state":{"unreadIds":["local_a","local_b"],"explicitUnreadIds":[]},"version":0}"#.utf8)
        #expect(Claude.parseUnread(value) == ["local_a", "local_b"])
        let utf16 = [UInt8(0)] + Array(#"{"state":{"unreadIds":["local_c"]}}"#.data(using: .utf16LittleEndian)!)
        #expect(Claude.parseUnread(utf16) == ["local_c"])
        #expect(Claude.parseUnread([1, 0x7b]) == nil)
    }
}

@MainActor
@Suite struct TypesafeKeySaving {
    @Test func aKeyTheKeychainRefusedIsNotSavedAndSaysSo() {
        let s = Store()
        s.persists = false
        var written: [String] = []
        s.keychainWrite = { key, _ in written.append(key); return false }
        #expect(!s.setTypesafeKey("  sk-test \n"))
        #expect(written == ["sk-test"])
        #expect(!s.hasTypesafeKey && s.typesafeKey == nil)
        #expect(s.iconError == "Couldn't save the key in the Keychain")
    }

    @Test func aKeyTheKeychainKeptIsSavedTrimmed() {
        let s = Store()
        s.persists = false
        s.keychainWrite = { _, _ in true }
        #expect(s.setTypesafeKey(" sk-test "))
        #expect(s.hasTypesafeKey && s.typesafeKey == "sk-test" && s.iconError == nil)
    }
}

@Suite struct FolderNaming {
    @Test func aNameIsItsOwnUntilAnotherProjectHasTheSame() {
        let all = ["/work/client/app", "/work/client/api", "/home/me/notes"]
        #expect(all.map { FolderNames.name($0, among: all) } == ["app", "api", "notes"])
        #expect(FolderNames.name("", among: all) == "Scratch")
    }

    @Test func identicalNamesTakeTheShortestPathThatTellsThemApart() {
        let all = ["/work/customer-a/app", "/work/customer-b/app", "/play/app", "/play/other/app", "/solo/tool"]
        #expect(all.map { FolderNames.name($0, among: all) } == ["customer-a/app", "customer-b/app", "play/app", "other/app", "tool"])
    }

    @Test func allTheNamesAtOnceAreWhatEachOneWouldBeAmongTheOthers() {
        // The same rule as one name at a time, which is the definition: the shortest suffix that no other folder shares.
        func reference(_ folder: String, _ all: [String]) -> String {
            func parts(_ f: String) -> [String] { f.split(separator: "/").map(String.init) }
            let own = parts(folder)
            let others = all.filter { $0 != folder }.map(parts)
            var depth = 1
            while depth < own.count, others.contains(where: { $0.suffix(depth) == own.suffix(depth) }) { depth += 1 }
            return own.suffix(depth).joined(separator: "/")
        }
        var all: [String] = []
        for a in 0..<6 { for b in 0..<4 { for c in ["app", "api", "lib"] where (a + b) % 3 != 0 { all.append("/work/g\(a)/p\(b % 2)/\(c)") } } }
        all += ["/play/app", "/app", "/solo/tool", "/x/y/z/app"]
        let names = FolderNames.names(for: Set(all))
        #expect(names.count == Set(all).count)
        for folder in Set(all) { #expect(names[folder] == reference(folder, all), "\(folder)") }
    }

    @MainActor @Test func theNamesAreOnlyWorkedOutAgainWhenTheFoldersChange() {
        let s = Store()
        s.persists = false
        func session(_ id: String, _ folder: String) -> ClaudeSession {
            ClaudeSession(id: id, title: id, folder: folder, lastActivity: Date())
        }
        var runs = 0
        s.nameFolders = { runs += 1; return FolderNames.names(for: $0) }
        s.claudeSessions = ["a": session("a", "/x/app"), "b": session("b", "/y/app")]
        #expect(s.folderNames == ["/x/app": "x/app", "/y/app": "y/app"] && runs == 1)
        // A session's own change (its activity moves its time) leaves the folders as they were: nothing is worked out again.
        s.claudeSessions["a"]?.lastActivity = Date().addingTimeInterval(60)
        s.agents.entries.append(AgentEntry(id: "a"))
        #expect(runs == 1 && s.folderNames["/x/app"] == "x/app")
        // A new folder, or a muted one, does: once each.
        s.claudeSessions["c"] = session("c", "/z/tool")
        #expect(s.folderNames["/z/tool"] == "tool" && runs == 2)
        s.agents.mutedFolders = ["/w/app"]
        #expect(s.folderNames["/w/app"] == "w/app" && s.folderNames["/x/app"] == "x/app" && runs == 3)
    }
}
