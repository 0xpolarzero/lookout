import AppKit
import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Agents {
    private let now = sessionsNow

    /// A store that has already seen `sessions` once (seeded), so later reads are "new activity".
    private func store(_ sessions: [ClaudeSession], dots: Set<String> = []) -> Store {
        let s = Store.unsaved()
        s.agents.enabled = true
        s.agents.enabledAt = now.addingTimeInterval(-3600)
        s.ingest(sessions, appUnread: dots, claudeFrontmost: false, now: now)
        return s
    }

    private func entry(_ s: Store, _ id: String) -> AgentEntry? { s.agents.entries.first { $0.id == id } }

    @Test func statusAgesFollowTheClockTheyAreGiven() {
        let s = store([session("a", minutesAgo: 5)])
        let idle = (s.agentRows.pending + s.agentRows.kept).first { $0.id == "a" }!
        #expect(idle.statusLabel(now: now) == "Finished 5m")
        #expect(idle.statusLabel(now: now.addingTimeInterval(3600)) == "Finished 1h")
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

    @Test func aSessionSearchFoundButNeverOfferedTakesWhatIsDoneToIt() {
        // Older than the first read offers: only search lists it.
        let s = store([session("old", minutesAgo: 3 * 24 * 60)])
        #expect(s.agents.entries.isEmpty)
        s.toggleAgentRead("old")
        s.setAgentLabel("old", "OL")
        #expect(entry(s, "old")?.unread == true && entry(s, "old")?.label == "OL")
        s.dismissAgent("old")
        #expect(entry(s, "old")?.hiddenAt != nil)
        // Kept in its entry, and not offered as new activity.
        #expect(s.agentRows.pending.isEmpty && s.agentRows.kept.isEmpty)
        #expect(s.row(s.claudeSessions["old"]!).unread)
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

    @Test func undoingAHideDoesNotReverseAKeepMadeSince() {
        let s = store([session("a")])
        s.dismissAgent("a")
        s.keepAgent("a")
        #expect(s.undoStack.undo())
        #expect(s.agentRows.kept.map(\.id) == ["a"])
        // Left as Hide made it, undo brings back what it hid.
        let t = store([session("a")])
        t.dismissAgent("a")
        #expect(t.undoStack.undo())
        #expect(t.agentRows.pending.map(\.id) == ["a"])
    }

    @Test func hidingASessionAlreadyHiddenOffersNothingToTakeBack() {
        let s = store([session("a")])
        s.keepAgent("a")
        s.dismissAgent("a")
        let row = s.row(s.claudeSessions["a"]!)
        #expect(row.hidden && row.spokenValue().hasSuffix(", hidden"))
        let line = s.undoStack.entries.count
        s.dismissAgent("a")
        #expect(s.undoStack.entries.count == line)
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
        s.ingest([session("a"), session("new", minutesAgo: 0), session("chat", folder: nil, minutesAgo: 0)],
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
        var old = session("old", folder: "/code/lookout", minutesAgo: 3 * 24 * 60)
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
        #expect(s.sessionGroups.map { $0.rows.map(\.id) } == [["a", "c"], ["b"]])
        // Each project got its own colour.
        #expect(s.agents.folderColors["/code/x"] != s.agents.folderColors["/code/y"])
        #expect(s.agentRows.kept.first?.color != nil)
    }

    @Test func searchFindsAnySessionKeptFirst() {
        var other = session("other", folder: "/code/sandbox", minutesAgo: 1)
        other.title = "Storage directory"
        var mine = session("mine", minutesAgo: 50)
        mine.title = "Sandbox on Linux"
        let s = store([other, mine])
        s.keepAgent("mine")
        #expect(s.searchSessions("sand").map(\.id) == ["mine", "other"])  // title prefix and kept first
        #expect(s.searchSessions("sto dir").map(\.id) == ["other"])
        #expect(s.searchSessions("").isEmpty)
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
        // Upper-cased before it is cut: ß is SS, so two of them are still two characters.
        #expect(AgentLabel.sanitize("ßß") == "SS")
    }

    @Test func everyLabelIsTwoCharactersWideEnoughForTheTileAtItsTypeSize() {
        // Past the nine digits a project's tiles take another letter, never a third character.
        let items = (0..<60).map { (id: "s\($0)", title: "Same title", custom: String?.none) }
        let labels = AgentLabel.assign(items).values
        #expect(Set(labels).count == 60 && labels.allSatisfy { $0.count == 2 })
        // The widest two the tile can be given fit it without scaling the type down.
        let base = NSFont.systemFont(ofSize: 11, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        for pair in ["WW", "MM", "W9", "SS"] {
            #expect(ceil((pair as NSString).size(withAttributes: [.font: font]).width) <= Theme.Metrics.tile - 2, "\(pair)")
        }
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
        let folder = Claude.tasksRoot.appendingPathComponent("lookout-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let output = folder.appendingPathComponent("b1.output")
        fm.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = try FileHandle(forWritingTo: output)
        try process.run()
        #expect(Claude.openTaskOutputs().contains(output.path))
        process.terminate()
        process.waitUntilExit()
        #expect(!Claude.openTaskOutputs().contains(output.path))
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
@Suite struct LabelReset {
    @Test func anEmptiedFieldResetsWhatItsModeHolds() {
        // Letters over an icon the title's own letters; otherwise nothing, so the default shows again.
        #expect(LabelEditor.reset(.letters, title: "CI failure diagnosis", folder: "microsandbox", hasIcon: true) == "CF")
        #expect(LabelEditor.reset(.letters, title: "CI failure diagnosis", folder: "microsandbox", hasIcon: false) == nil)
        // An emoji is removed, never written back as the label it was.
        #expect(LabelEditor.reset(.emoji, title: "CI failure diagnosis", folder: "microsandbox", hasIcon: true) == nil)
    }
}

@MainActor
@Suite struct LabelValidation {
    @Test func theWrongKindOfTextInAStyleIsSaidNotSwallowed() {
        #expect(LabelEditor.problem("AB", mode: .emoji) == "That isn't an emoji. Switch to Letters for letters")
        #expect(LabelEditor.problem("🐧", mode: .letters) == "That's an emoji. Switch to Emoji to use it")
        // What fits the style, and an empty field (which resets it), have nothing to say.
        #expect(LabelEditor.problem("AB", mode: .letters) == nil && LabelEditor.problem("🐧", mode: .emoji) == nil)
        #expect(LabelEditor.problem("  ", mode: .emoji) == nil && LabelEditor.problem("", mode: .letters) == nil)
    }
}

/// The idle gate runs the real lifecycle on the demo's data (`--demo agents --lifecycle`): what the watchers read from the
/// empty folder must not take the working sessions, and so the ring, away from what it measures.
@MainActor
@Suite struct DemoLifecycle {
    @Test func aReadOfAnEmptyFolderLeavesTheDemosSessionsAndTheirRing() {
        let store = Store()
        Demo.populate(store, .agents)
        let before = store.allAgentRows
        #expect(before.contains { $0.tileMarks.working })
        store.demoLifecycle = true
        store.applyClaude(ClaudeSnapshot(link: .ok, sessions: [], appUnread: [], activity: [:], tasks: [:], stamp: store.claudeStamp))
        #expect(store.allAgentRows.map(\.id) == before.map(\.id))
        #expect(store.allAgentRows.contains { $0.tileMarks.working })
        // Without the lifecycle, the same read is what removes them (a real, empty Claude folder).
        let real = Store()
        Demo.populate(real, .agents)
        real.applyClaude(ClaudeSnapshot(link: .ok, sessions: [], appUnread: [], activity: [:], tasks: [:], stamp: real.claudeStamp))
        #expect(real.allAgentRows.isEmpty)
    }
}

@MainActor
@Suite struct TokenSaving {
    @Test func aGitHubTokenTheKeychainRefusedIsNotSavedAndIsNotSignedInWith() {
        let s = Store.unsaved()
        var written: [(String, String)] = []
        s.keychainWrite = { key, account in written.append((key, account)); return false }
        s.lastSync = nil
        #expect(!s.setToken("ghp_test"))
        #expect(written.count == 1 && written[0].0 == "ghp_test" && written[0].1 == Keychain.github)
        // Nothing was refreshed with the token that was not kept.
        #expect(s.lastSync == nil && !s.isSyncing)
    }

    @Test func aTokenGitHubRejectsIsAnnouncedOnceForTheAttemptThatSavedIt() {
        let s = Store.unsaved()
        s.keychainWrite = { _, _ in true }
        s.interceptRefresh = {}
        var said: [String] = []
        s.announceSignIn = { said.append($0) }
        // A poll that fails to sign in with nobody having tried anything says nothing.
        s.signInFailed("Bad credentials")
        #expect(said.isEmpty)
        #expect(s.setToken("ghp_revoked"))
        s.signInFailed("The token was rejected: Bad credentials")
        #expect(said == ["GitHub rejected your token."] && s.authError != nil)
        // The next poll's failure is not the attempt's.
        s.signInFailed("The token was rejected: Bad credentials")
        #expect(said.count == 1)
    }
}

@MainActor
@Suite struct TypesafeKeySaving {
    @Test func aKeyTheKeychainRefusedIsNotSavedAndSaysSo() {
        let s = Store.unsaved()
        var written: [String] = []
        s.keychainWrite = { key, _ in written.append(key); return false }
        #expect(!s.setTypesafeKey("  sk-test \n"))
        #expect(written == ["sk-test"])
        #expect(!s.hasTypesafeKey && s.typesafeKey == nil)
        #expect(s.iconError == "Couldn't save the key in the Keychain")
    }

    @Test func aKeyTheKeychainKeptIsSavedTrimmed() {
        let s = Store.unsaved()
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
        let s = Store.unsaved()
        func session(_ id: String, _ folder: String) -> ClaudeSession {
            ClaudeSession(id: id, title: id, folder: folder, lastActivity: Date())
        }
        s.claudeSessions = ["a": session("a", "/x/app"), "b": session("b", "/y/app")]
        #expect(s.folderNames == ["/x/app": "x/app", "/y/app": "y/app"])
        let seen = s.namedFoldersSeen
        // A session's own change (its activity moves its time) leaves the folders as they were.
        s.claudeSessions["a"]?.lastActivity = Date().addingTimeInterval(60)
        #expect(s.namedFoldersSeen == seen && s.folderNames["/x/app"] == "x/app")
        // A new folder, or a muted one, does not.
        s.claudeSessions["c"] = session("c", "/z/tool")
        #expect(s.folderNames["/z/tool"] == "tool")
        s.agents.mutedFolders = ["/w/app"]
        #expect(s.folderNames["/w/app"] == "w/app" && s.folderNames["/x/app"] == "x/app")
    }
}
