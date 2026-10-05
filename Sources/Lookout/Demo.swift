import AppKit
import Foundation
import SwiftUI

/// `--demo [scenario]`: fake data for trying the UI without touching GitHub or the saved state.
@MainActor
enum Demo {
    enum Scenario: String, CaseIterable {
        case busy, botsOnly, allClear, snoozed, error, empty, agents
    }

    static func populate(_ store: Store, _ scenario: Scenario = .busy) {
        store.persists = false
        let now = Date()
        store.me = GHUser(login: "0xpolarzero", avatarUrl: URL(string: "https://avatars.githubusercontent.com/u/0?v=4"), type: "User")
        store.tokenSource = .ghCLI
        store.lastSync = now.addingTimeInterval(-20)
        store.rateRemaining = 4812
        store.settings.botHandles = ["vercel", "netlify"]
        store.repos = [
            RepoConfig(fullName: "0xpolarzero/lookout", allComments: true),
            RepoConfig(fullName: "apple/swift-format"),
            RepoConfig(fullName: "ziglang/zig", events: [.prComment, .reviewComment, .ciMain]),
            RepoConfig(fullName: "superradcompany/microsandbox", events: [.issueComment, .prComment, .reviewComment]),
            RepoConfig(fullName: "amontlabs/lcu", allComments: true),
            RepoConfig(fullName: "e2b-dev/runtime", events: [.issueComment, .prComment]),
        ]
        store.ci = [
            "0xpolarzero/lookout": CIStatus(state: .success, branch: "main", sha: "6f9e3014c2", failing: [], checkedAt: now,
                                            title: "Compact, draggable repo cards", updatedAt: now.addingTimeInterval(-1500)),
            "apple/swift-format": CIStatus(state: .failure, branch: "main", sha: "b41c09e7aa", failing: ["Linux / build", "Windows / test"],
                                           checkedAt: now, title: "Respect trailing comma config (#1042)", updatedAt: now.addingTimeInterval(-2700)),
            "ziglang/zig": CIStatus(state: .pending, branch: "master", sha: "0d2e9f1b33", failing: [], checkedAt: now,
                                    title: "std.Io: add vectored reads to File", updatedAt: now.addingTimeInterval(-240)),
            "amontlabs/lcu": CIStatus(state: .success, branch: "main", sha: "a93b0c2d11", failing: [], checkedAt: now,
                                      title: "Release 0.4.2", updatedAt: now.addingTimeInterval(-86400)),
        ]
        store.items = items(now)

        switch scenario {
        case .busy:
            break
        case .botsOnly:
            store.items = store.items.filter { store.isLowPriority($0) || !$0.state.isOpen }
            for key in store.ci.keys { store.ci[key]?.state = .success; store.ci[key]?.failing = [] }
        case .allClear:
            store.items = store.items.filter { !$0.state.isOpen }
            for key in store.ci.keys { store.ci[key]?.state = .success; store.ci[key]?.failing = [] }
        case .snoozed:
            store.settings.snoozeUntil = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: now)
                .map { $0 > now ? $0 : now.addingTimeInterval(3600) }
        case .error:
            store.rateRemaining = 312
            store.repoErrors["ziglang/zig"] = "Not found (or no access)"
            store.ci["0xpolarzero/lookout"]?.state = .failure
            store.ci["0xpolarzero/lookout"]?.failing = ["test (macos-15)"]
            store.ci["0xpolarzero/lookout"]?.title = "Drag the pill from anywhere"
        case .agents:
            agents(store, now)
        case .empty:
            store.repos = []
            store.ci = [:]
            store.items = []
            store.settings.reviewRequests = false
        }
    }

    static let hoverID = "demo-hover"
    static let selectedID = "demo-selected"
    static let blockedAgentID = "local_demo-lcu"

    /// The Claude sessions extension, on, with kept and pending sessions in every state.
    static func agents(_ store: Store, _ now: Date) {
        func session(_ id: String, _ title: String, _ folder: String?, minutes: Double, turns: Int = 4,
                     blocked: Bool = false, detail: String = "", running: Bool = false) -> ClaudeSession {
            let at = now.addingTimeInterval(-minutes * 60)
            return ClaudeSession(id: id, title: title, folder: folder.map { "/Users/me/code/\($0)" }, completedTurns: turns,
                                 lastActivity: at, lastFocused: at.addingTimeInterval(-600), lastUserMessage: at.addingTimeInterval(-90),
                                 summary: running ? nil : ClaudeSession.Summary(blocked: blocked, detail: detail), running: running)
        }
        let sessions = [
            session(blockedAgentID, "LCU update notifications", "lcu", minutes: 2, blocked: true,
                    detail: "Should updates install silently, or ask first each time?"),
            session("local_demo-ci", "CI failure diagnosis", "microsandbox", minutes: 4,
                    detail: "Fixed the flaky sandbox test; CI is green on the branch."),
            session("local_demo-lookout", "Agent completion notifications", "lookout", minutes: 1, running: true),
            session("local_demo-transfer", "Repository ownership transfer setup", "microsandbox", minutes: 180,
                    detail: "Transfer is done; both remotes point at the new org."),
            session("local_demo-linux", "LCU JavaScript sandbox on Linux", "microsandbox", minutes: 1500,
                    detail: "Sandbox runs on Linux; two follow-ups listed."),
            session("local_demo-calc", "Calculator display reading", "lcu-research", minutes: 1,
                    detail: "The display reads 1,234.5; the screenshot is attached."),
            session("local_demo-games", "Game recommendations", nil, minutes: 25,
                    detail: "Single-player immersion or online squads?"),
            session("local_demo-storage", "Sandbox storage directory customization", "microsandbox", minutes: 2900,
                    detail: "Storage path is configurable through the CLI and the env."),
        ]
        store.claudeSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        store.claudeLink = .ok
        store.claudeActivity = ["local_demo-lookout": ClaudeActivity(text: "Running swift test", since: now.addingTimeInterval(-20))]
        store.claudeTasks = ["local_demo-ci": [
            ClaudeTask(id: "a1", kind: .agent, title: "Review the sandbox changes", since: now.addingTimeInterval(-190),
                       activity: ClaudeActivity(text: "Reading sandbox.rs", since: now.addingTimeInterval(-5))),
            ClaudeTask(id: "a2", kind: .agent, title: "Check the other CI jobs", since: now.addingTimeInterval(-70),
                       activity: ClaudeActivity(text: "Thinking", since: now.addingTimeInterval(-2))),
            ClaudeTask(id: "b1", kind: .command, title: "Run the full test suite", since: now.addingTimeInterval(-370)),
        ]]
        var state = AgentsState()
        state.folderColors = ["/Users/me/code/lcu": 0, "/Users/me/code/microsandbox": 1, "/Users/me/code/lookout": 2,
                              "/Users/me/code/lcu-research": 3]
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.seeded = true
        func entry(_ id: String, kept: Bool, unread: Bool, label: String? = nil, icon: String? = nil) -> AgentEntry {
            let s = store.claudeSessions[id]!
            return AgentEntry(id: id, kept: kept, label: label, unread: unread, seen: s.activity, focusedAt: s.lastFocused, icon: icon)
        }
        state.iconsEnabled = true
        state.entries = [
            entry(blockedAgentID, kept: true, unread: true, icon: "bell.badge"),
            entry("local_demo-ci", kept: true, unread: true, icon: "ladybug"),
            entry("local_demo-lookout", kept: true, unread: false),
            entry("local_demo-transfer", kept: true, unread: false, icon: "key"),
            entry("local_demo-linux", kept: true, unread: false, label: "🐧"),
            entry("local_demo-calc", kept: false, unread: true),
            entry("local_demo-games", kept: false, unread: false),
        ]
        store.agents = state
    }

    private static func items(_ now: Date) -> [InboxItem] {
        var counter = 0
        func item(_ kind: EventKind, _ repo: String, _ n: Int, _ title: String, _ author: String, _ snippet: String,
                  _ minutesAgo: Double, _ state: ItemState = .unread, app: Bool = false, path: String? = nil,
                  id: String? = nil) -> InboxItem {
            counter += 1
            let login = author.replacingOccurrences(of: "[bot]", with: "")
            return InboxItem(id: id ?? "demo-\(counter)", repo: repo, kind: kind, number: n, title: title, snippet: snippet,
                             author: author, avatar: URL(string: "https://github.com/\(login).png"), authorIsApp: app,
                             url: URL(string: "https://github.com/\(repo)/issues/\(n)")!,
                             createdAt: now.addingTimeInterval(-minutesAgo * 60), state: state, path: path)
        }
        return [
            // Needs you
            item(.reviewComment, "ziglang/zig", 21877, "std.Io: add vectored reads to File", "andrewrk",
                 "This should take the buffer by slice instead, otherwise we copy twice on the hot path.", 3,
                 path: "lib/std/Io/File.zig", id: hoverID),
            item(.prComment, "apple/swift-format", 1042, "Respect trailing comma config in collection literals", "allevato",
                 "Thanks! Could you add a test for the nested array case?", 18),
            item(.issueOpened, "0xpolarzero/lookout", 12, "Pill overlaps the Dock when it's on the right", "mattt",
                 "With the Dock pinned right, the pill sits under it. Maybe snap to the visible frame?", 42, id: selectedID),
            item(.reviewRequested, "apple/swift-format", 1051, "Add --lines option to format a range", "ahoppen", "", 65),
            item(.prOpened, "0xpolarzero/lookout", 15, "Add GitHub Enterprise host setting", "kylef",
                 "Adds an API base URL field in Settings and threads it through the client.", 95),
            item(.issueComment, "0xpolarzero/lookout", 9, "Support GitHub Enterprise", "kyle", "+1, we'd use this at work.", 120, .read),
            // Bots
            item(.prComment, "0xpolarzero/lookout", 14, "Group notifications by repo", "vercel[bot]",
                 "Deployment ready. Preview: lookout-git-group.vercel.app", 6, app: true),
            item(.reviewComment, "apple/swift-format", 1042, "Respect trailing comma config in collection literals",
                 "coderabbitai[bot]", "Consider extracting this into a helper; the same check appears in three places.", 22,
                 app: true, path: "Sources/SwiftFormat/Rules/TrailingComma.swift"),
            item(.prComment, "apple/swift-format", 1042, "Respect trailing comma config in collection literals", "codecov[bot]",
                 "Coverage 87.2% (+0.4%) compared to base.", 25, .read, app: true),
            // Done
            item(.reviewComment, "ziglang/zig", 21877, "std.Io: add vectored reads to File", "squeek502",
                 "Nit: this is the same as readv on posix.", 300, .resolved, path: "lib/std/Io/File.zig"),
            item(.issueComment, "0xpolarzero/lookout", 7, "Crash on wake from sleep", "jessesquires",
                 "Repro'd on 26.1 as well.", 900, .addressed),
            item(.reviewRequested, "ziglang/zig", 21840, "Sema: fix comptime int overflow in @shlExact", "mlugg", "", 1500, .addressed),
            item(.issueOpened, "apple/swift-format", 1038, "Question: config file lookup order?", "someone", "How does it pick between…", 2000, .discarded),
        ]
    }
}

/// `--check owner/repo`: headless sync against live GitHub, prints what the inbox would contain.
@MainActor
enum Check {
    static func run(store: Store, repo: String) {
        store.persists = false
        Task {
            await store.authenticate()
            if let i = CommandLine.arguments.firstIndex(of: "--thread"), let n = Int(CommandLine.arguments[i + 1]) {
                let me = store.me?.login.lowercased() ?? ""
                let info = try? await store.fetchThreads(repo, [n], participation: true, reviewThreads: [n], me: me)
                let t = info?[n]
                print("#\(n) title=\(t?.title ?? "nil") author=\(t?.author ?? "nil") myActivity=\(t?.activity ?? []) reviewThreadsWithMe=\(t?.reviewActivity.filter { !$0.value.isEmpty }.count ?? 0)")
                exit(0)
            }
            print("auth:", store.me?.login ?? "nil", store.tokenSource?.rawValue ?? "", store.authError ?? "")
            if let err = await store.addRepo(repo) { print("add error:", err) }
            if CommandLine.arguments.contains("--all"), let r = store.repos.first {
                store.toggleAllComments(r)
                store.repos[0].cursors = [:]
                store.items = []
            }
            if let i = CommandLine.arguments.firstIndex(of: "--days"), let days = Double(CommandLine.arguments[i + 1]) {
                store.repos[0].addedAt = Date().addingTimeInterval(-(days - 1) * 86400)
                store.repos[0].cursors = [:]
                store.items = []
            }
            print("allComments:", store.repos.first?.allComments ?? false)
            await store.pollAll()
            for item in store.items.sorted(by: { $0.createdAt > $1.createdAt }).filter({ $0.kind != .issueOpened && $0.kind != .prOpened }).prefix(25) {
                print(String(format: "%-15@ %-10@ #%-6d %@ @%@ low=%d  %@", item.kind.rawValue, item.state.rawValue, item.number,
                             shortAgo(item.createdAt), item.author, store.isLowPriority(item) ? 1 : 0, String(item.title.prefix(50))))
            }
            let comments = store.items.filter { [.issueComment, .prComment, .reviewComment].contains($0.kind) }
            print("comments forYou:", comments.filter { $0.forYou == true }.count, "notForYou:", comments.filter { $0.forYou == false }.count,
                  "unknown:", comments.filter { $0.forYou == nil }.count)
            print("items:", store.items.count, "by kind:", Dictionary(grouping: store.items, by: \.kind.rawValue).mapValues(\.count))
            print("ci:", store.ci.mapValues { "\($0.branch) \($0.state.rawValue) failing=\($0.failing)" })
            print("errors:", store.repoErrors, "cursors:", store.repos.first?.cursors ?? [:])
            print("rate:", store.gh.rateRemaining ?? -1)
            await store.pollAll()
            print("second poll rate:", store.gh.rateRemaining ?? -1, "items:", store.items.count)
            exit(0)
        }
    }
}

/// `--claude`: what the Claude sessions extension reads from the desktop app right now.
@MainActor
enum ClaudeCheck {
    static func run() {
        var start = Date()
        let result = Claude.SessionReader().read()
        let sessionsMS = Int(Date().timeIntervalSince(start) * 1000)
        start = Date()
        let unread = Claude.unreadIDs()
        print("installed:", Claude.isInstalled, "running:", Claude.isRunning, "sessions read in", sessionsMS, "ms, dots in",
              Int(Date().timeIntervalSince(start) * 1000), "ms")
        switch result {
        case .failure(let error): print("sessions:", error)
        case .success(let sessions):
            print("sessions:", sessions.count, "archived:", sessions.filter(\.isArchived).count)
            for s in sessions.filter({ !$0.isArchived }).sorted(by: { $0.lastActivity > $1.lastActivity }).prefix(12) {
                let state = s.running ? "running" : s.summary?.blocked == true ? "blocked" : s.summary == nil ? "-" : "done"
                print(String(format: "%-8@ %-7@ %-5@ turns=%-4d %@ · %@", state, shortAgo(s.lastActivity),
                             unread?.contains(s.id) == true ? "dot" : "", s.completedTurns, s.title, s.folderName))
            }
        }
        print("unread dots:", unread.map { "\($0.count)" } ?? "unreadable")
        if case .success(let sessions) = result {
            let reader = Claude.ActivityReader()
            for s in sessions where s.running {
                print("  working:", s.title, "→", s.cliID.flatMap { reader.activity(for: $0) }.map { "\($0.text) (since \(shortAgo($0.since)))" } ?? "no transcript")
            }
            let folders = Claude.taskFolders()
            let open = Claude.openTaskOutputs()
            let tasks = Claude.TaskReader()
            for s in sessions where !s.running && !s.isArchived {
                guard let cli = s.cliID, let folder = folders[cli] else { continue }
                for t in tasks.tasks(in: folder, transcript: reader.transcript(cli), openOutputs: open) {
                    print("  background:", s.title, "→", t.kind == .agent ? "agent" : "command", t.title,
                          t.activity.map { "(\($0.text))" } ?? "", "since \(shortAgo(t.since))")
                }
            }
        }
        if CommandLine.arguments.contains("--watch") { watch(); return }
        if case .success(let sessions) = result, let unread {
            for s in sessions where unread.contains(s.id) { print("  dot:", s.title, s.isArchived ? "(archived)" : "", shortAgo(s.lastActivity)) }
        }
        exit(0)
    }

    /// `--claude --watch`: the extension live against the real app, nothing saved; prints every change.
    private static var watchers: [FolderWatcher] = []

    private static func watch() {
        let store = Store()
        store.persists = false
        store.agents.enabled = true
        store.agents.enabledAt = Date()
        var last = ""
        func dump(_ reason: String) {
            store.refreshClaude()
            let rows = store.agentRows
            let lines = (rows.kept + rows.pending).map { r in
                "\(r.label) \(r.pending ? "pending" : "kept   ") \(r.unread ? "UNREAD" : "read  ") \(r.statusText.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.session.title)"
            }
            let text = lines.joined(separator: "\n")
            guard text != last else { return }
            last = text
            print("--- \(Date().formatted(date: .omitted, time: .standard)) (\(reason)) counts=\(store.agentCounts)\n" + text)
            fflush(stdout)
        }
        dump("start")
        // Held for the life of the process (the run loop never returns), so the stream keeps delivering.
        watchers.append(FolderWatcher([Claude.sessionsDir, Claude.localStorageDir]) { MainActor.assumeIsolated { dump("files") } })
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in MainActor.assumeIsolated { dump("timer") } }
    }
}
