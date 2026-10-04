import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class Store {
    var repos: [RepoConfig] = []
    var items: [InboxItem] = []
    var ci: [String: CIStatus] = [:]
    var settings = AppSettings() { didSet { save() } }

    var me: GHUser?
    var tokenSource: TokenSource?
    var authError: String?
    var repoErrors: [String: String] = [:]
    var isSyncing = false
    var lastSync: Date?
    var rateRemaining: Int?
    var suggestions: [String] = []
    /// Bumped whenever an important item arrives, so the pill can flash.
    var pulse = 0

    @ObservationIgnored let gh = GitHubClient()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored var persists = true

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lookout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    // MARK: Lifecycle

    func start() {
        load()
        notifier.onOpen = { [weak self] id in
            guard let self else { return }
            if let item = self.items.first(where: { $0.id == id }) {
                self.open(item)
            } else if let url = URL(string: id), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
        notifier.setup()
        restartPolling()
    }

    func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                let interval = self?.settings.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshNow() {
        Task { await pollAll() }
    }

    // MARK: Persistence

    private func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let state = try? dec.decode(PersistedState.self, from: data) else { return }
        repos = state.repos
        items = state.items
        ci = state.ci
        settings = state.settings
    }

    func save() {
        guard persists, !loading else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let state = PersistedState(repos: repos, items: items, ci: ci, settings: settings)
        if let data = try? enc.encode(state) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Derived

    var isSnoozed: Bool { (settings.snoozeUntil ?? .distantPast) > Date() }
    var ciRepos: [RepoConfig] { repos.filter { $0.events.contains(.ciMain) } }

    func ciRepos(in state: CIState) -> [RepoConfig] {
        ciRepos.filter { ci[$0.fullName]?.state == state }
    }

    func isLowPriority(_ item: InboxItem) -> Bool {
        let author = item.author.lowercased()
        if settings.treatAppsAsBots && item.authorIsApp { return true }
        let handles = Set(settings.botHandles.map { $0.lowercased() })
        return handles.contains(author) || handles.contains(author.replacingOccurrences(of: "[bot]", with: ""))
    }

    func list(_ filter: InboxFilter) -> [InboxItem] {
        items.filter { item in
            switch filter {
            case .needsYou: item.state.isOpen && !isLowPriority(item)
            case .bots: item.state.isOpen && isLowPriority(item)
            case .done: !item.state.isOpen
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func unreadCount(_ filter: InboxFilter) -> Int {
        list(filter).filter { $0.state == .unread }.count
    }

    func openCount(_ filter: InboxFilter) -> Int {
        list(filter).count
    }

    var worstCI: CIState {
        let states = ciRepos.compactMap { ci[$0.fullName]?.state }
        if states.contains(.failure) { return .failure }
        if states.contains(.pending) { return .pending }
        if states.contains(.success) { return .success }
        return .none
    }

    // MARK: Item actions

    private func mutate(_ id: String, _ f: (inout InboxItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
        save()
    }

    func open(_ item: InboxItem) {
        NSWorkspace.shared.open(item.url)
        if item.state == .unread { markRead(item) }
    }

    func markRead(_ item: InboxItem) { mutate(item.id) { $0.state = .read } }
    func markUnread(_ item: InboxItem) { mutate(item.id) { $0.state = .unread } }
    func discard(_ item: InboxItem) { mutate(item.id) { $0.state = .discarded } }
    func restore(_ item: InboxItem) { mutate(item.id) { $0.state = .read } }

    func markAllRead(_ filter: InboxFilter) {
        let ids = Set(list(filter).filter { $0.state == .unread }.map(\.id))
        for i in items.indices where ids.contains(items[i].id) { items[i].state = .read }
        save()
    }

    func addBot(_ handle: String) {
        let h = handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !h.isEmpty, !settings.botHandles.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) else { return }
        settings.botHandles.append(h)
    }

    func removeBot(_ handle: String) {
        settings.botHandles.removeAll { $0 == handle }
    }

    func snooze(for seconds: TimeInterval?) {
        settings.snoozeUntil = seconds.map { Date().addingTimeInterval($0) }
    }

    func snoozeUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        settings.snoozeUntil = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    // MARK: Auth

    func authenticate() async {
        let resolved = await Task.detached { TokenProvider.resolve() }.value
        guard let (token, source) = resolved else {
            me = nil
            tokenSource = nil
            authError = "No GitHub token found. Run `gh auth login`, or paste a token in Settings."
            return
        }
        gh.token = token
        tokenSource = source
        do {
            me = try await gh.get("/user", as: GHUser.self)
            authError = nil
        } catch {
            me = nil
            authError = error.localizedDescription
        }
    }

    func setToken(_ token: String?) {
        if let token, !token.isEmpty { Keychain.write(token) } else { Keychain.delete() }
        me = nil
        refreshNow()
    }

    // MARK: Repos

    func addRepo(_ input: String) async -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "github.com/") { name = String(name[range.upperBound...]) }
        name = name.split(separator: "/").prefix(2).joined(separator: "/")
        guard name.split(separator: "/").count == 2 else { return "Use the owner/repo format" }
        guard !repos.contains(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) else { return "Already watching \(name)" }
        if me == nil { await authenticate() }
        do {
            let info: GHRepo = try await gh.get("/repos/\(name)")
            var config = RepoConfig(fullName: info.fullName)
            config.defaultBranch = info.defaultBranch
            repos.append(config)
            save()
            suggestions.removeAll { $0 == info.fullName }
            await sync(info.fullName)
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeRepo(_ repo: RepoConfig) {
        repos.removeAll { $0.id == repo.id }
        items.removeAll { $0.repo == repo.fullName && $0.kind != .reviewRequested }
        ci[repo.fullName] = nil
        save()
    }

    func toggle(_ kind: EventKind, on repo: RepoConfig) {
        guard let i = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        if repos[i].events.contains(kind) { repos[i].events.remove(kind) } else { repos[i].events.insert(kind) }
        save()
        if kind == .ciMain && repos[i].events.contains(kind) {
            let name = repo.fullName
            Task { try? await syncCI(name) }
        }
    }

    func moveRepo(_ name: String, onto target: String) {
        guard name != target, let from = repos.firstIndex(where: { $0.fullName == name }),
              let to = repos.firstIndex(where: { $0.fullName == target }) else { return }
        repos.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    func toggleAllComments(_ repo: RepoConfig) {
        guard let i = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[i].allComments.toggle()
        save()
    }

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        if me == nil { await authenticate() }
        var names: [String] = []
        if let involved: GHSearch<GHIssue> = try? await gh.get("/search/issues", ["q": "involves:@me", "sort": "updated", "per_page": "100"]) {
            names += involved.items.compactMap { $0.repositoryUrl.map { repoName(from: $0) } }
        }
        if let mine: [GHRepo] = try? await gh.get("/user/repos", ["sort": "pushed", "per_page": "100", "affiliation": "owner,collaborator,organization_member"]) {
            names += mine.map(\.fullName)
        }
        var seen = Set(repos.map { $0.fullName.lowercased() })
        suggestions = names.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Polling

    func pollAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            lastSync = Date()
            rateRemaining = gh.rateRemaining
            prune()
            save()
        }
        if me == nil { await authenticate() }
        guard me != nil else { return }
        for repo in repos {
            await sync(repo.fullName)
        }
        if settings.reviewRequests {
            await syncReviewRequests()
        }
    }

    private func sync(_ name: String) async {
        do {
            try await syncConversations(name)
            try await syncThreads(name)
            try await syncCI(name)
            repoErrors[name] = nil
        } catch {
            repoErrors[name] = error.localizedDescription
        }
    }

    private func updateRepo(_ name: String, _ f: (inout RepoConfig) -> Void) {
        guard let i = repos.firstIndex(where: { $0.fullName == name }) else { return }
        f(&repos[i])
    }

    private func syncConversations(_ name: String) async throws {
        guard let repo = repos.first(where: { $0.fullName == name }), let me = me?.login.lowercased() else { return }
        let ev = repo.events
        let baseline = repo.addedAt.addingTimeInterval(-24 * 3600)
        func cursor(_ key: String) -> Date { repo.cursors[key] ?? baseline }
        func query(_ key: String) -> [String: String] {
            ["sort": "updated", "direction": "asc", "per_page": "100", "since": ISO8601DateFormatter().string(from: cursor(key))]
        }

        var fresh: [InboxItem] = []
        var mentioned = Set<String>()
        var titles: [Int: String] = [:]
        // (number, my comment date, thread root) — applied after new items merge.
        var myReplies: [(number: Int, at: Date, root: Int?)] = []

        if !ev.isDisjoint(with: [.issueOpened, .prOpened, .issueComment, .prComment, .reviewComment]) {
            let issues: [GHIssue] = try await gh.get("/repos/\(name)/issues", query("issues").merging(["state": "all"]) { a, _ in a })
            for issue in issues {
                titles[issue.number] = issue.title
                let kind: EventKind = issue.pullRequest != nil ? .prOpened : .issueOpened
                guard ev.contains(kind), issue.createdAt >= cursor("issues").addingTimeInterval(-1),
                      let user = issue.user, user.login.lowercased() != me else { continue }
                fresh.append(InboxItem(
                    id: "\(name)#\(kind.rawValue)#\(issue.id)", repo: name, kind: kind, number: issue.number,
                    title: issue.title, snippet: snippet(issue.body), author: user.login, avatar: user.avatarUrl,
                    authorIsApp: user.isApp, url: issue.htmlUrl, createdAt: issue.createdAt, state: .unread))
            }
            if let last = issues.map(\.updatedAt).max() { updateRepo(name) { $0.cursors["issues"] = last } }
        }

        if !ev.isDisjoint(with: [.issueOpened, .prOpened, .issueComment, .prComment]) {
            let comments: [GHComment] = try await gh.get("/repos/\(name)/issues/comments", query("comments"))
            for c in comments {
                guard let user = c.user, let number = c.issueUrl.flatMap({ Int($0.lastPathComponent) }) else { continue }
                if user.login.lowercased() == me {
                    myReplies.append((number, c.createdAt, nil))
                    continue
                }
                let kind: EventKind = c.htmlUrl.path.contains("/pull/") ? .prComment : .issueComment
                guard ev.contains(kind), c.createdAt >= cursor("comments").addingTimeInterval(-1) else { continue }
                if mentionsMe(c.body, me) { mentioned.insert("\(name)#c#\(c.id)") }
                fresh.append(InboxItem(
                    id: "\(name)#c#\(c.id)", repo: name, kind: kind, number: number,
                    title: title(for: number, in: name, titles), snippet: snippet(c.body), author: user.login,
                    avatar: user.avatarUrl, authorIsApp: user.isApp, url: c.htmlUrl, createdAt: c.createdAt, state: .unread))
            }
            if let last = comments.map(\.updatedAt).max() { updateRepo(name) { $0.cursors["comments"] = last } }
        }

        if ev.contains(.reviewComment) {
            let comments: [GHComment] = try await gh.get("/repos/\(name)/pulls/comments", query("review"))
            for c in comments {
                guard let user = c.user, let number = c.pullRequestUrl.flatMap({ Int($0.lastPathComponent) }) else { continue }
                let root = c.inReplyToId ?? c.id
                if user.login.lowercased() == me {
                    myReplies.append((number, c.createdAt, root))
                    continue
                }
                guard c.createdAt >= cursor("review").addingTimeInterval(-1) else { continue }
                if mentionsMe(c.body, me) { mentioned.insert("\(name)#r#\(c.id)") }
                fresh.append(InboxItem(
                    id: "\(name)#r#\(c.id)", repo: name, kind: .reviewComment, number: number,
                    title: title(for: number, in: name, titles), snippet: snippet(c.body), author: user.login,
                    avatar: user.avatarUrl, authorIsApp: user.isApp, url: c.htmlUrl, createdAt: c.createdAt,
                    state: .unread, threadRoot: root, path: c.path))
            }
            if let last = comments.map(\.updatedAt).max() { updateRepo(name) { $0.cursors["review"] = last } }
        }

        let known = Set(items.map(\.id))
        var added = fresh.filter { !known.contains($0.id) }
        let commentKinds: Set<EventKind> = [.issueComment, .prComment, .reviewComment]
        let filtering = !repo.allComments
        let needInfo = Set(added.filter { $0.title == "#\($0.number)" || (filtering && commentKinds.contains($0.kind)) }.map(\.number))
        let reviewNumbers = Set(added.filter { filtering && $0.kind == .reviewComment }.map(\.number))
        let info: [Int: ThreadInfo]? = needInfo.isEmpty ? [:]
            : try? await fetchThreads(name, Array(needInfo), participation: filtering, reviewThreads: reviewNumbers, me: me)
        for i in added.indices {
            if let title = info?[added[i].number]?.title { added[i].title = title }
        }
        // Comments only count when they're on my thread, mention me, or come after I joined the conversation.
        // If the lookup failed, keep everything rather than silently dropping something addressed to me.
        if filtering, let info {
            added = added.filter { Self.isRelevant($0, thread: info[$0.number], mentioned: mentioned.contains($0.id), me: me) }
        }
        items.append(contentsOf: added)

        // Anything I replied to after it was posted is addressed.
        for reply in myReplies {
            for i in items.indices where items[i].repo == name && items[i].number == reply.number
                && items[i].state.isOpen && items[i].createdAt < reply.at {
                if let root = reply.root {
                    if items[i].threadRoot == root { items[i].state = .addressed }
                } else if EventKind.conversationKinds.contains(items[i].kind) {
                    items[i].state = .addressed
                }
            }
        }

        announce(added.filter { $0.state == .unread && $0.createdAt > repo.addedAt })
    }

    struct ThreadInfo {
        var title: String?
        var author: String?
        /// When I commented on (or reviewed) the issue/PR.
        var activity: [Date] = []
        /// Review thread root comment id → when I posted in that thread.
        var reviewActivity: [Int: [Date]] = [:]
    }

    /// One GraphQL call for the threads new comments landed on: titles, authors and my participation.
    func fetchThreads(_ name: String, _ numbers: [Int], participation: Bool, reviewThreads: Set<Int>,
                              me: String) async throws -> [Int: ThreadInfo] {
        let parts = name.split(separator: "/")
        let common = participation ? "title author { login } comments(last: 100) { nodes { author { login } createdAt } }" : "title"
        var q = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") {"
        for n in numbers.sorted().suffix(40) {
            var pr = common
            if participation { pr += " reviews(last: 50) { nodes { author { login } submittedAt } }" }
            if reviewThreads.contains(n) {
                pr += " reviewThreads(last: 60) { nodes { comments(first: 50) { nodes { databaseId author { login } createdAt } } } }"
            }
            q += " n\(n): issueOrPullRequest(number: \(n)) { ... on Issue { \(common) } ... on PullRequest { \(pr) } }"
        }
        q += " } }"
        let json = try await gh.graphql(q)
        guard let repoObj = (json["data"] as? [String: Any])?["repository"] as? [String: Any] else {
            throw GitHubError(message: "Couldn't load threads for \(name)")
        }

        func nodes(_ obj: Any?, _ key: String) -> [[String: Any]] {
            ((obj as? [String: Any])?[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        }
        func login(_ node: [String: Any]) -> String? { ((node["author"] as? [String: Any])?["login"] as? String)?.lowercased() }
        func date(_ node: [String: Any], _ key: String) -> Date? { (node[key] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }

        var result: [Int: ThreadInfo] = [:]
        for (key, value) in repoObj {
            guard let n = Int(key.dropFirst()), let obj = value as? [String: Any] else { continue }
            var info = ThreadInfo(title: obj["title"] as? String, author: login(obj))
            info.activity = nodes(obj, "comments").filter { login($0) == me }.compactMap { date($0, "createdAt") }
                + nodes(obj, "reviews").filter { login($0) == me }.compactMap { date($0, "submittedAt") }
            for thread in nodes(obj, "reviewThreads") {
                let comments = nodes(thread, "comments")
                guard let root = comments.first?["databaseId"] as? Int else { continue }
                info.reviewActivity[root] = comments.filter { login($0) == me }.compactMap { date($0, "createdAt") }
            }
            result[n] = info
        }
        return result
    }

    /// The "comments that are for me" rule (used when a repo's All comments switch is off).
    nonisolated static func isRelevant(_ item: InboxItem, thread: ThreadInfo?, mentioned: Bool, me: String) -> Bool {
        guard [.issueComment, .prComment, .reviewComment].contains(item.kind), !mentioned else { return true }
        guard let thread else { return false }
        if thread.author == me { return true }
        if item.kind == .reviewComment {
            return thread.reviewActivity[item.threadRoot ?? -1]?.contains { $0 < item.createdAt } ?? false
        }
        return thread.activity.contains { $0 < item.createdAt }
    }

    nonisolated static func mentions(_ body: String?, _ me: String) -> Bool {
        guard let body else { return false }
        let pattern = "(?<![\\w/@-])@" + NSRegularExpression.escapedPattern(for: me) + "(?![\\w-])"
        return body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func mentionsMe(_ body: String?, _ me: String) -> Bool {
        Self.mentions(body, me)
    }


    /// Review threads: resolution state lives only in GraphQL.
    private func syncThreads(_ name: String) async throws {
        let recent = Date().addingTimeInterval(-21 * 86400)
        let tracked = items.filter { $0.repo == name && $0.kind == .reviewComment && $0.state != .discarded && $0.createdAt > recent }
        let numbers = Array(Set(tracked.map(\.number))).sorted().suffix(20)
        guard !numbers.isEmpty else { return }
        let parts = name.split(separator: "/")
        var q = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") {"
        for n in numbers {
            q += " pr\(n): pullRequest(number: \(n)) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { databaseId } } } } }"
        }
        q += " } }"
        let json = try await gh.graphql(q)
        guard let repoObj = (json["data"] as? [String: Any])?["repository"] as? [String: Any] else { return }

        var resolved: [Int: Bool] = [:]
        for case let pr as [String: Any] in repoObj.values {
            let nodes = (pr["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            for node in nodes {
                let first = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
                if let id = first?["databaseId"] as? Int, let isResolved = node["isResolved"] as? Bool {
                    resolved[id] = isResolved
                }
            }
        }
        for i in items.indices where items[i].repo == name && items[i].kind == .reviewComment {
            guard let root = items[i].threadRoot, let r = resolved[root] else { continue }
            if r, items[i].state != .discarded { items[i].state = .resolved }
            if !r, items[i].state == .resolved { items[i].state = .read }
        }
    }

    private func syncCI(_ name: String) async throws {
        guard var repo = repos.first(where: { $0.fullName == name }), repo.events.contains(.ciMain) else { return }
        if repo.defaultBranch == nil {
            let info: GHRepo = try await gh.get("/repos/\(name)")
            updateRepo(name) { $0.defaultBranch = info.defaultBranch }
            repo.defaultBranch = info.defaultBranch
        }
        let branch = repo.defaultBranch!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let ref = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        // Only push-triggered Actions runs count: issue/comment-triggered workflows also run against the
        // default branch HEAD and would otherwise make CI look red.
        let actions: GHWorkflowRuns = try await gh.get("/repos/\(name)/actions/runs",
                                                       ["branch": branch, "event": "push", "per_page": "30"])
        let sha = actions.workflowRuns.first?.headSha
        var latest: [Int: GHWorkflowRuns.Run] = [:]
        for run in actions.workflowRuns where run.headSha == sha && latest[run.workflowId] == nil {
            latest[run.workflowId] = run
        }
        let target = sha ?? ref
        let checks: GHCheckRuns = try await gh.get("/repos/\(name)/commits/\(target)/check-runs", ["per_page": "100"])
        let external = checks.checkRuns.filter { $0.app?.slug != "github-actions" }
        let status: GHCombinedStatus = try await gh.get("/repos/\(name)/commits/\(target)/status")

        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        var failing = latest.values.filter { bad.contains($0.conclusion ?? "") }.map(\.name).sorted()
        failing += external.filter { bad.contains($0.conclusion ?? "") }.map(\.name)
        failing += status.statuses.filter { $0.state == "failure" || $0.state == "error" }.map(\.context)
        let pending = latest.values.contains { $0.status != "completed" }
            || external.contains { $0.status != "completed" }
            || status.statuses.contains { $0.state == "pending" }
        let any = !latest.isEmpty || !external.isEmpty || status.totalCount > 0
        let state: CIState = !failing.isEmpty ? .failure : pending ? .pending : any ? .success : .none
        let commit = sha ?? status.sha

        let previous = ci[name]?.state
        ci[name] = CIStatus(state: state, branch: branch, sha: commit,
                            url: URL(string: "https://github.com/\(name)/commit/\(commit)"),
                            failing: failing, checkedAt: Date(),
                            title: actions.workflowRuns.first?.displayTitle,
                            updatedAt: latest.values.compactMap(\.updatedAt).max())

        if previous == .success || previous == .pending, state == .failure {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI failing on \(branch)",
                   subtitle: failing.prefix(3).joined(separator: ", "), body: "", quiet: false)
            pulse += 1
        } else if previous == .failure, state == .success {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI back to green",
                   subtitle: branch, body: "", quiet: true)
        }
    }

    private func syncReviewRequests() async {
        guard let result: GHSearch<GHIssue> = try? await gh.get(
            "/search/issues", ["q": "is:open is:pr user-review-requested:@me archived:false", "per_page": "50"]) else { return }
        let first = !settings.didInitialReviewSync
        var current = Set<String>()
        var added: [InboxItem] = []
        for pr in result.items {
            let id = "rr#\(pr.id)"
            current.insert(id)
            guard !items.contains(where: { $0.id == id }), let user = pr.user, let repoURL = pr.repositoryUrl else { continue }
            let item = InboxItem(
                id: id, repo: repoName(from: repoURL), kind: .reviewRequested, number: pr.number, title: pr.title,
                snippet: snippet(pr.body), author: user.login, avatar: user.avatarUrl, authorIsApp: user.isApp,
                url: pr.htmlUrl, createdAt: first ? pr.updatedAt : Date(), state: .unread)
            items.append(item)
            added.append(item)
        }
        // Request disappeared: I reviewed it (or it was withdrawn/closed).
        for i in items.indices where items[i].kind == .reviewRequested && items[i].state.isOpen && !current.contains(items[i].id) {
            items[i].state = .addressed
        }
        if first {
            settings.didInitialReviewSync = true
        } else {
            announce(added)
        }
    }

    private func prune() {
        let now = Date()
        items.removeAll { item in
            let age = now.timeIntervalSince(item.createdAt)
            return (!item.state.isOpen && age > 14 * 86400) || age > 60 * 86400
        }
        if items.count > 1500 {
            items = Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(1500))
        }
    }

    // MARK: Notifications

    private func announce(_ new: [InboxItem]) {
        guard !new.isEmpty else { return }
        let important = new.filter { !isLowPriority($0) }
        if !important.isEmpty { pulse += 1 }
        if new.count > 4 {
            let repos = Set(new.map(\.repo)).sorted().joined(separator: ", ")
            notify(id: "", title: "\(new.count) new items", subtitle: repos, body: "", quiet: important.isEmpty)
            return
        }
        for item in new {
            let path = item.path.map { " · \($0)" } ?? ""
            notify(id: item.id, title: "\(item.kind.label) · \(item.repo)#\(item.number)", subtitle: item.title,
                   body: "@\(item.author)\(path): \(item.snippet)", quiet: isLowPriority(item))
        }
    }

    private func notify(id: String, title: String, subtitle: String, body: String, quiet: Bool) {
        guard settings.notifications, !isSnoozed else { return }
        notifier.post(id: id, title: title, subtitle: subtitle, body: body, quiet: quiet)
    }

    // MARK: Helpers

    private func title(for number: Int, in repo: String, _ titles: [Int: String]) -> String {
        titles[number] ?? items.first(where: { $0.repo == repo && $0.number == number })?.title ?? "#\(number)"
    }

    private func repoName(from url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }

    private func snippet(_ body: String?) -> String {
        guard let body else { return "" }
        var text = body
        // Drop HTML comments (PR templates, bot metadata) and fenced code.
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " [code] ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[#*_>`]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespaces).prefix(280))
    }
}
