import AppKit
import Foundation
import SwiftUI

/// `--demo [scenario]`: fake data for trying the UI without touching GitHub or the saved state.
@MainActor
enum Demo {
    /// `busy` to `agents` are the plain `--demo` sets. The rest are the states that empty a list or break the sync, each on
    /// top of the `agents` data (the bar with everything on it) unless noted, so a shot shows the state in a realistic bar.
    enum Scenario: String, CaseIterable {
        case busy, botsOnly, allClear, snoozed, error, empty, agents
        // Inbox and sync causes.
        case signedOut, reposFailed, rateLimited, needsYouEmpty, botsEmpty, doneEmpty, firstSync, syncFault
        // An inbox longer than any list shows.
        case inboxMany
        // CI.
        case noCI, allPassing, manyCI, ciRunning
        // Sessions, replacing the `agents` ones: a handful of each state, and long lists.
        case sessionsWaiting, sessionsWorking, sessionsUnread, sessionsNewActivity, sessionsScratch, sessionsNone, sessions12
        case sessionsManyNew, sessionsWaiting10
        // The update tile.
        case updateAvailable, updateDownloading, updateReady
        // The Router: cards of each kind (a question with its form) and a chat with receipts; and the Router switched off.
        case router, routerOff
        // Router only: the session tiles gone, the Router standing in for them.
        case routerOnly
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
            nothingForYou(store)
            passing(store)
        case .allClear:
            store.items = store.items.filter { !$0.state.isOpen }
            passing(store)
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
        case .signedOut:
            agents(store, now)
            store.me = nil
            store.tokenSource = nil
            store.lastSync = nil
            store.rateRemaining = nil
            store.authError = "No GitHub token found"
        case .reposFailed:
            agents(store, now)
            store.repoErrors = ["ziglang/zig": "Not found (or no access)", "e2b-dev/runtime": "Forbidden"]
        case .rateLimited:
            agents(store, now)
            store.rateRemaining = 0
        case .needsYouEmpty:
            // Nothing for you, CI healthy, bot items still unread: all caught up.
            agents(store, now)
            nothingForYou(store)
            passing(store)
        case .botsEmpty:
            agents(store, now)
            store.items = store.items.filter { !($0.state.isOpen && store.isLowPriority($0)) }
        case .doneEmpty:
            agents(store, now)
            store.items = store.items.filter { $0.state.isOpen }
        case .firstSync:
            agents(store, now)
            store.lastSync = nil
            store.isSyncing = true
            store.items = []
            store.ci = [:]
            store.rateRemaining = nil
        case .syncFault:
            // Several poll intervals old: the sync status reads "Not syncing".
            agents(store, now)
            store.lastSync = now.addingTimeInterval(-3600)
        case .inboxMany:
            agents(store, now)
            let titles = ["Cache the avatar lookups", "Dark mode for the Settings window", "Snooze until Monday", "Open the right repo on click",
                          "Hide read items after a day", "Keyboard shortcut for Mark all read", "Tab order in the footer", "Menu bar icon option",
                          "Group by repository", "Notifications repeat after wake", "Sort Done by repository", "Search inside snippets"]
            store.items += titles.enumerated().map { index, title in
                InboxItem(id: "many-\(index)", repo: "0xpolarzero/lookout", kind: .issueOpened, number: 30 + index, title: title,
                          snippet: "", author: ["kylef", "mattt", "allevato"][index % 3], avatar: nil, authorIsApp: false,
                          url: URL(string: "https://github.com/0xpolarzero/lookout/issues/\(30 + index)")!,
                          createdAt: now.addingTimeInterval(-Double(130 + index * 40) * 60), state: .unread)
            }
        case .noCI:
            agents(store, now)
            for i in store.repos.indices { store.repos[i].events.remove(.ciMain) }
            store.ci = [:]
        case .allPassing:
            agents(store, now)
            passing(store)
        case .manyCI:
            agents(store, now)
            manyCI(store, now)
        case .ciRunning:
            // Nothing failing: what was running stays running.
            agents(store, now)
            for key in store.ci.keys where store.ci[key]?.state == .failure { store.ci[key]?.state = .success; store.ci[key]?.failing = [] }
        case .sessionsWaiting:
            // w2's activity is what an AskUserQuestion call yields: its first question, as the transcript reader reports it.
            sessions(store, now, [
                .init(session("w1", "LCU update notifications", "lcu", minutes: 2, blocked: true,
                              detail: "Should updates install silently, or ask first each time?"), unread: true),
                .init(session("w2", "Release notes wording", "lookout", minutes: 5, running: true), unread: true),
                .init(session("w3", "CI failure diagnosis", "microsandbox", minutes: 40, detail: "Fixed the flaky sandbox test.")),
            ], activity: ["w2": ClaudeActivity(text: "Which tone should the release notes take?", since: now.addingTimeInterval(-300),
                                               waitsForYou: true)])
        case .sessionsWorking:
            sessions(store, now, [
                .init(session("k1", "Agent completion notifications", "lookout", minutes: 1, running: true)),
                .init(session("k2", "CI failure diagnosis", "microsandbox", minutes: 4, detail: "Reviewing the sandbox changes."), unread: true),
                .init(session("k3", "Transfer setup", "lcu", minutes: 120, detail: "Both remotes point at the new org.")),
            ], activity: ["k1": ClaudeActivity(text: "Running swift test", since: now.addingTimeInterval(-90))],
                     tasks: ["k2": [
                        ClaudeTask(id: "a1", kind: .agent, title: "Review the sandbox changes", since: now.addingTimeInterval(-190),
                                   activity: ClaudeActivity(text: "Reading sandbox.rs", since: now.addingTimeInterval(-5))),
                        ClaudeTask(id: "a2", kind: .agent, title: "Check the other CI jobs", since: now.addingTimeInterval(-70)),
                        ClaudeTask(id: "b1", kind: .command, title: "Run the full test suite", since: now.addingTimeInterval(-370)),
                     ]])
        case .sessionsUnread:
            sessions(store, now, [
                .init(session("u1", "CI failure diagnosis", "microsandbox", minutes: 4, detail: "Fixed the flaky sandbox test."), unread: true),
                .init(session("u2", "Calculator display reading", "lcu", minutes: 15, detail: "The display reads 1,234.5."), unread: true),
                .init(session("u3", "Game recommendations", nil, minutes: 60, detail: "Single-player or online squads?"), unread: true),
                .init(session("u4", "Transfer setup", "lookout", minutes: 300, detail: "Transfer is done.")),
            ])
        case .sessionsNewActivity:
            // Nothing kept: every session is new activity, offered to keep or hide.
            sessions(store, now, [
                .init(session("n1", "CI failure diagnosis", "microsandbox", minutes: 4, detail: "Fixed the flaky sandbox test."),
                      kept: false, unread: true),
                .init(session("n2", "Calculator display reading", "lcu", minutes: 15, detail: "The display reads 1,234.5."),
                      kept: false, unread: true),
                .init(session("n3", "Game recommendations", nil, minutes: 60, detail: "Single-player or online squads?"), kept: false),
                .init(session("n4", "Transfer setup", "lookout", minutes: 300, detail: "Transfer is done."), kept: true),
            ])
        case .sessionsScratch:
            sessions(store, now, [
                .init(session("s1", "Game recommendations", nil, minutes: 25, detail: "Single-player immersion or online squads?"),
                      unread: true),
                .init(session("s2", "Regex for semver tags", nil, minutes: 90, detail: "Use `^v\\d+\\.\\d+\\.\\d+$`.")),
                .init(session("s3", "Agent completion notifications", "lookout", minutes: 3, detail: "Done; tests pass."), unread: true),
            ])
        case .sessionsNone:
            sessions(store, now, [])
        case .sessions12:
            sessions12(store, now)
        case .sessionsManyNew:
            sessionsManyNew(store, now)
        case .sessionsWaiting10:
            // Twelve sessions, ten of them waiting: none of them may be hidden.
            questions(store, now, total: 12, waiting: 10)
        case .updateAvailable:
            agents(store, now)
            store.updater.preview(.available, version: "0.5.0")
        case .updateDownloading:
            agents(store, now)
            store.updater.preview(.downloading, version: "0.5.0", fraction: 0.42)
        case .updateReady:
            agents(store, now)
            store.updater.preview(.ready, version: "0.5.0")
        case .router:
            agents(store, now)
            router(store, now)
        case .routerOff:
            agents(store, now)
        case .routerOnly:
            agents(store, now)
            router(store, now)
            store.router.routerOnly = true
        }
    }

    /// The Router on, over the `agents` sessions: the one that asks is stopped on its question (whose form Lookout holds),
    /// a plan and a stuck turn wait, a turn is done, older cards are addressed; a short chat with what the Router did.
    private static func router(_ store: Store, _ now: Date) {
        let lcu = blockedAgentID
        store.claudeSessions[lcu]?.running = true
        store.claudeSessions[lcu]?.cliID = "cli-demo-lcu"
        store.claudeActivity[lcu] = ClaudeActivity(text: "Should updates install silently, or ask first each time?",
                                                   since: now.addingTimeInterval(-120), waitsForYou: true, tool: "AskUserQuestion",
                                                   toolUseID: "toolu_demo_lcu")
        let question = "Should updates install silently, or ask first each time?"
        store.pendingForms["cli-demo-lcu"] = PendingForm(
            id: "cli-demo-lcu-1-1", cliSessionID: "cli-demo-lcu", transcriptPath: "",
            questions: [PendingForm.Question(question: question, header: "Updates", multiSelect: false, options: [
                PendingForm.Option(label: "Install silently", description: "Download and install in the background"),
                PendingForm.Option(label: "Ask first", description: "Show a prompt before each update"),
            ])],
            createdAt: now.addingTimeInterval(-60), pid: 0, toolUseID: "toolu_demo_lcu")
        func card(_ session: String, _ kind: RouterCard.Kind, _ text: String, minutes: Double, addressed: RouterCard.Addressed? = nil)
            -> RouterCard {
            let s = store.claudeSessions[session]
            let at = now.addingTimeInterval(-minutes * 60)
            // Ids as the feed makes them: a wait by when it began, a turn by its number.
            let id = kind.isTurn ? "\(session)#t\(s?.completedTurns ?? 0)" : "\(session)#w\(RouterFeed.Stamp.ms(at))"
            return RouterCard(id: id, sessionID: session, kind: kind,
                              title: s?.title ?? session, folder: s?.folder, text: text, createdAt: at,
                              addressedAt: addressed == nil ? nil : at.addingTimeInterval(120), addressedBy: addressed)
        }
        var state = RouterState()
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.cards = [
            card("local_demo-transfer", .done, "Transfer is done; both remotes point at the new org.", minutes: 12, addressed: .router),
            card("local_demo-games", .question, "Single-player immersion or online squads?", minutes: 30, addressed: .answered),
            card("local_demo-ci", .done, "Fixed the flaky sandbox test; **CI is green** on the branch.", minutes: 4),
            card("local_demo-linux", .plan, "Run the JavaScript sandbox in a Firecracker microVM on Linux", minutes: 9),
            card("local_demo-calc", .stuck, "Can't reach the staging database: the VPN is down.", minutes: 6),
            card(lcu, .question, question, minutes: 2),
        ]
        state.cards[state.cards.count - 1].toolUseID = "toolu_demo_lcu"
        // The question is the wait the session is on now, so its form shows on its card.
        state.waits[lcu] = state.cards.last?.waitMs
        state.chat = [
            RouterMessage(role: .you, text: "what needs me?", date: now.addingTimeInterval(-300)),
            RouterMessage(role: .router, text: "**3 need you**: *LCU update notifications* asks how updates install; the Linux "
                          + "sandbox has a plan to approve; *Calculator display reading* is stuck on the VPN.\nDone: CI failure diagnosis.",
                          date: now.addingTimeInterval(-290)),
            RouterMessage(role: .you, text: "transfer: remove the old remote", date: now.addingTimeInterval(-200)),
            RouterMessage(role: .receipt, text: "→ Repository ownership transfer setup: Remove the old remote.",
                          date: now.addingTimeInterval(-195), sessionID: "local_demo-transfer",
                          original: "transfer: remove the old remote"),
            RouterMessage(role: .peer, text: "Removed `old-origin`; only the new org's remote is left. I also checked the branch "
                          + "protection rules on the new org: `main` requires one review and passing checks, as before. The deploy key "
                          + "was carried over, and the webhook for CI now points at the new repository. Two open PRs still target the "
                          + "old fork; I left them alone.", date: now.addingTimeInterval(-60), sessionID: "local_demo-transfer"),
            RouterMessage(role: .you, text: "start a session to bump the version", date: now.addingTimeInterval(-30),
                          projects: ["/Users/me/code/lookout"]),
            RouterMessage(role: .receipt, text: "Cancelled before sending", date: now.addingTimeInterval(-28)),
            RouterMessage(role: .error, text: "SendMessage to Game recommendations: not delivered (the session isn't open in Claude)",
                          date: now.addingTimeInterval(-10), sessionID: "local_demo-games"),
        ]
        // The scenario shows the tiles too; `routerOnly` hides them.
        state.routerOnly = false
        store.router = state
    }

    /// Only the bot items and the finished ones left: nothing is for you.
    private static func nothingForYou(_ store: Store) {
        store.items = store.items.filter { store.isLowPriority($0) || !$0.state.isOpen }
    }

    /// Every CI repo green.
    private static func passing(_ store: Store) {
        for key in store.ci.keys { store.ci[key]?.state = .success; store.ci[key]?.failing = [] }
    }

    /// 15 repositories with CI: two failing, two running, eleven passing.
    private static func manyCI(_ store: Store, _ now: Date) {
        let names = ["0xpolarzero/lookout", "apple/swift-format", "ziglang/zig", "amontlabs/lcu", "e2b-dev/runtime",
                     "superradcompany/microsandbox", "apple/swift-argument-parser", "pointfreeco/swift-composable-architecture",
                     "vapor/vapor", "swiftlang/swift-package-manager", "tuist/tuist", "realm/SwiftLint", "Alamofire/Alamofire",
                     "hummingbird-project/hummingbird", "apple/swift-nio"]
        store.repos = names.map { RepoConfig(fullName: $0) }
        let failing: [String: [String]] = ["apple/swift-format": ["Linux / build", "Windows / test"], "vapor/vapor": ["Unit tests (5.10)"]]
        let running: Set<String> = ["ziglang/zig", "apple/swift-nio"]
        store.ci = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            let state: CIState = failing[name] != nil ? .failure : running.contains(name) ? .pending : .success
            return (name, CIStatus(state: state, branch: "main", sha: String(format: "%010x", 0x9a133ca0 + index * 977),
                                   failing: failing[name] ?? [], checkedAt: now, title: "Commit headline \(index + 1)",
                                   updatedAt: now.addingTimeInterval(-Double(index + 1) * 2300)))
        })
    }

    static let hoverID = "demo-hover"
    static let selectedID = "demo-selected"
    static let blockedAgentID = "local_demo-lcu"

    /// A session as the Claude app reports it: a finished turn with a summary, or (`running`) mid-turn.
    private static func session(_ id: String, _ title: String, _ folder: String?, minutes: Double, turns: Int = 4,
                                blocked: Bool = false, detail: String = "", running: Bool = false) -> ClaudeSession {
        let at = Date().addingTimeInterval(-minutes * 60)
        return ClaudeSession(id: id, title: title, folder: folder.map { "/Users/me/code/\($0)" }, completedTurns: turns,
                             lastActivity: at, lastFocused: at.addingTimeInterval(-600), lastUserMessage: at.addingTimeInterval(-90),
                             summary: running ? nil : ClaudeSession.Summary(blocked: blocked, detail: detail), running: running)
    }

    /// A session and how Lookout lists it: kept or new activity, read or not.
    private struct Listed {
        var session: ClaudeSession
        var kept = true
        var unread = false
        var label: String?
        var icon: String?

        init(_ session: ClaudeSession, kept: Bool = true, unread: Bool = false, label: String? = nil, icon: String? = nil) {
            self.session = session
            self.kept = kept
            self.unread = unread
            self.label = label
            self.icon = icon
        }
    }

    /// The Claude sessions extension, on, with these sessions. `colors` pins each project's colour; the others get the
    /// least used one, in listing order. `unlisted` are known to the app but without an entry: only found by search.
    private static func sessions(_ store: Store, _ now: Date, _ listed: [Listed], activity: [String: ClaudeActivity] = [:],
                                 tasks: [String: [ClaudeTask]] = [:], colors: [String: Int] = [:],
                                 unlisted: [ClaudeSession] = []) {
        store.claudeSessions = Dictionary(uniqueKeysWithValues: (listed.map(\.session) + unlisted).map { ($0.id, $0) })
        store.claudeLink = .ok
        store.claudeActivity = activity
        store.claudeTasks = tasks
        var state = AgentsState()
        state.folderColors = colors
        for folder in listed.compactMap(\.session.folder) { state.assignColor(folder) }
        state.enabled = true
        state.enabledAt = now.addingTimeInterval(-86400)
        state.seeded = true
        state.iconsEnabled = true
        state.entries = listed.map { l in
            AgentEntry(id: l.session.id, kept: l.kept, label: l.label, unread: l.unread, seen: l.session.activity,
                       focusedAt: l.session.lastFocused, icon: l.icon)
        }
        store.agents = state
    }

    /// The sessions in every state: a waiting one, a working one, finished ones (unread and read), new activity.
    static func agents(_ store: Store, _ now: Date) {
        let listed = [
            Listed(session(blockedAgentID, "LCU update notifications", "lcu", minutes: 2, blocked: true,
                           detail: "Should updates install silently, or ask first each time?"), unread: true, icon: "bell.badge"),
            Listed(session("local_demo-ci", "CI failure diagnosis", "microsandbox", minutes: 4,
                           detail: "Fixed the flaky sandbox test; CI is green on the branch."), unread: true, icon: "ladybug"),
            Listed(session("local_demo-lookout", "Agent completion notifications", "lookout", minutes: 1, running: true)),
            Listed(session("local_demo-transfer", "Repository ownership transfer setup", "microsandbox", minutes: 180,
                           detail: "Transfer is done; both remotes point at the new org."), icon: "key"),
            Listed(session("local_demo-linux", "LCU JavaScript sandbox on Linux", "microsandbox", minutes: 1500,
                           detail: "Sandbox runs on Linux; two follow-ups listed."), label: "\u{1F427}"),
            Listed(session("local_demo-calc", "Calculator display reading", "lcu-research", minutes: 1,
                           detail: "The display reads 1,234.5; the screenshot is attached."), kept: false, unread: true),
            Listed(session("local_demo-games", "Game recommendations", nil, minutes: 25,
                           detail: "Single-player immersion or online squads?"), kept: false),
        ]
        let hidden = session("local_demo-storage", "Sandbox storage directory customization", "microsandbox", minutes: 2900,
                             detail: "Storage path is configurable through the CLI and the env.")
        sessions(store, now, listed, activity: ["local_demo-lookout": ClaudeActivity(text: "Running swift test", since: now.addingTimeInterval(-20))],
                 tasks: ["local_demo-ci": [
                    ClaudeTask(id: "a1", kind: .agent, title: "Review the sandbox changes", since: now.addingTimeInterval(-190),
                               activity: ClaudeActivity(text: "Reading sandbox.rs", since: now.addingTimeInterval(-5))),
                    ClaudeTask(id: "a2", kind: .agent, title: "Check the other CI jobs", since: now.addingTimeInterval(-70),
                               activity: ClaudeActivity(text: "Thinking", since: now.addingTimeInterval(-2))),
                    ClaudeTask(id: "b1", kind: .command, title: "Run the full test suite", since: now.addingTimeInterval(-370)),
                 ]],
                 colors: ["/Users/me/code/lcu": 0, "/Users/me/code/microsandbox": 1, "/Users/me/code/lookout": 2,
                          "/Users/me/code/lcu-research": 3],
                 unlisted: [hidden])
    }

    /// Twelve sessions: one waiting, one working, the rest finished, two of them new activity. More than the bar shows.
    private static func sessions12(_ store: Store, _ now: Date) {
        let projects = ["lcu", "microsandbox", "lookout", "lcu-research", "zig-docs"]
        var listed = [
            Listed(session("t0", "LCU update notifications", "lcu", minutes: 2, blocked: true,
                           detail: "Should updates install silently, or ask first each time?"), unread: true),
            Listed(session("t1", "Agent completion notifications", "lookout", minutes: 1, running: true)),
        ]
        for i in 2..<12 {
            listed.append(Listed(session("t\(i)", "Session number \(i)", projects[i % projects.count], minutes: Double(i * 17),
                                         detail: "Finished turn \(i)."), kept: i < 10, unread: i % 3 == 0))
        }
        sessions(store, now, listed, activity: ["t1": ClaudeActivity(text: "Running swift test", since: now.addingTimeInterval(-90))])
    }

    /// One waiting, two kept, and eleven with new activity: more than that group lists.
    private static func sessionsManyNew(_ store: Store, _ now: Date) {
        let projects = ["lcu", "microsandbox", "lookout", "lcu-research"]
        var listed = [
            Listed(session("m0", "LCU update notifications", "lcu", minutes: 2, blocked: true,
                           detail: "Should updates install silently, or ask first each time?"), unread: true),
            Listed(session("m1", "Transfer setup", "lookout", minutes: 200, detail: "Both remotes point at the new org.")),
            Listed(session("m2", "Calculator display reading", "lcu", minutes: 90, detail: "The display reads 1,234.5.")),
        ]
        for i in 0..<11 {
            let made = session("m\(i + 3)", "New activity \(i + 1)", projects[i % projects.count], minutes: Double(3 + i * 11),
                               detail: "Finished turn \(i + 1).")
            listed.append(Listed(made, kept: false, unread: i % 2 == 0))
        }
        sessions(store, now, listed)
    }

    /// `total` sessions, the first `waiting` of them waiting for you: more than the bar has room for.
    private static func questions(_ store: Store, _ now: Date, total: Int, waiting: Int) {
        let projects = ["lcu", "microsandbox", "lookout", "lcu-research", "zig-docs"]
        // Built a step at a time: as one expression, older compilers give up type-checking it.
        var listed: [Listed] = []
        for i in 0..<total {
            let isWaiting = i < waiting
            let detail = isWaiting ? "Which one should it be?" : "Finished turn \(i)."
            let made = session("q\(i)", "Question number \(i)", projects[i % projects.count], minutes: Double(i * 7 + 1),
                               blocked: isWaiting, detail: detail)
            listed.append(Listed(made, unread: isWaiting))
        }
        sessions(store, now, listed)
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
                "\(r.label) \(r.pending ? "pending" : "kept   ") \(r.unread ? "UNREAD" : "read  ") \(r.statusText().padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.session.title)"
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
