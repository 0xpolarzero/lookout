import AppKit
import Foundation

// CI as the hub reads it: which repos need a look, which are muted, and the worst state the bar shows.

/// The worst state among the repos that aren't muted, and how many of them fail: all the bar's CI cell shows.
struct CIWorst: Equatable {
    var state: CIState
    var failing: Int
}

/// A repo in CI's list with what the rows need of it.
struct CIEntry: Identifiable {
    let repo: RepoConfig
    let status: CIStatus?
    let state: CIState
    let muted: Bool

    var id: String { repo.fullName }
    /// When its runs last changed.
    var changedAt: Date? { status?.updatedAt }
}

/// CI's list: failing then running repos get their own rows; everything else (passing, muted, no runs yet) is the
/// one quiet group.
struct CIList {
    var attention: [CIEntry] = []
    var quiet: [CIEntry] = []
    /// Repo names two watched repos share: those show their owner too.
    var shared: Set<String> = []

    var isEmpty: Bool { attention.isEmpty && quiet.isEmpty }
    var entries: [CIEntry] { attention + quiet }
    /// Every repo has passed: the quiet group is the whole list.
    var allPassing: Bool { attention.isEmpty && !quiet.isEmpty && quiet.allSatisfy { $0.state == .success && !$0.muted } }

    /// What a row calls a repo: its name, with `owner/` only where the name alone is ambiguous.
    func title(_ repo: RepoConfig) -> String { shared.contains(repo.name.lowercased()) ? repo.fullName : repo.name }

    /// What the quiet group holds, by what each repo really is: a muted repo is not passing, whatever it shows.
    var quietCounts: (passing: Int, muted: Int, noRuns: Int) {
        (quiet.filter { $0.state == .success && !$0.muted }.count, quiet.filter(\.muted).count,
         quiet.filter { $0.state == .none && !$0.muted }.count)
    }

    /// The group's name, for the row and for VoiceOver's label: the biggest part of it.
    var quietName: String {
        let (passing, muted, _) = quietCounts
        if allPassing { return "All passing" }
        return passing > 0 ? CIState.success.title : muted > 0 ? "Muted" : CIState.none.title
    }

    /// "Passing · 11, 1 muted"; "All passing · 3 repositories" once nothing else is there.
    var quietTitle: String {
        let (passing, muted, noRuns) = quietCounts
        if allPassing { return "All passing · \(plural(quiet.count, "repository", "repositories"))" }
        var parts = ["\(quietName) · \(passing > 0 ? passing : muted > 0 ? muted : noRuns)"]
        if passing > 0, muted > 0 { parts.append("\(muted) muted") }
        if (passing > 0 || muted > 0), noRuns > 0 { parts.append("\(noRuns) \(CIState.none.label)") }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver adds to the group's name: its counts, in words.
    var quietSpeech: String {
        let (passing, muted, noRuns) = quietCounts
        if allPassing { return plural(quiet.count, "repository", "repositories") }
        let parts = [(passing, CIState.success.label), (muted, "muted"), (noRuns, CIState.none.label)]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
}

extension Store {
    // MARK: Muting

    /// Whether a repo's CI is muted: it was muted at the sha it is still on. A new commit un-mutes it (a changed state
    /// does too, see `unmuteCIIfChanged`), without anything having to remember to.
    nonisolated static func isMuted(_ name: String, status: [String: CIStatus], muted: [String: String]) -> Bool {
        guard let sha = muted[name], let current = status[name] else { return false }
        return (current.sha ?? "") == sha
    }

    func isCIMuted(_ repo: RepoConfig) -> Bool { Self.isMuted(repo.fullName, status: ci, muted: mutedCI) }

    /// Quiets a repo until its commit or state changes: out of the worst state and the bar's glyph. The undo line says so.
    func muteCI(_ repo: RepoConfig) {
        let name = repo.fullName
        guard let status = ci[name] else { return }
        let sha = status.sha ?? ""
        let before = mutedCI[name]
        mutedCI[name] = sha
        save()
        registerUndo("Muted \(ciList.title(repo)) until it changes", in: .ci,
                     announcement: "Muted \(repo.name) until it changes. Undo available") { [self] in
            // Only if nothing has moved it since: a new commit already un-muted it.
            guard mutedCI[name] == sha else { return }
            mutedCI[name] = before
            save()
        }
    }

    func unmuteCI(_ repo: RepoConfig) {
        guard mutedCI[repo.fullName] != nil else { return }
        mutedCI[repo.fullName] = nil
        save()
    }

    /// Called by the CI sync with a repo's new status, before it replaces the old one: a muted repo whose commit or
    /// state moved is heard again.
    func unmuteCIIfChanged(_ name: String, to new: CIStatus) {
        guard let sha = mutedCI[name] else { return }
        if new.state != ci[name]?.state || (new.sha ?? "") != sha { mutedCI[name] = nil }
    }

    // MARK: Worst state

    /// What the bar shows of CI: the worst state among the repos that aren't muted, and how many fail. A muted repo is
    /// left out altogether: it isn't passing, so it never turns the bar into a check.
    var ciWorst: CIWorst { Self.ciWorst(repos: ciRepos, status: ci, muted: mutedCI) }

    nonisolated static func ciWorst(repos: [RepoConfig], status: [String: CIStatus], muted: [String: String]) -> CIWorst {
        var failing = 0
        var running = false
        var passing = false
        for repo in repos {
            let state = status[repo.fullName]?.state ?? CIState.none
            if isMuted(repo.fullName, status: status, muted: muted) { continue }
            switch state {
            case .failure: failing += 1
            case .pending: running = true
            case .success: passing = true
            case .none: break
            }
        }
        return CIWorst(state: failing > 0 ? .failure : running ? .pending : passing ? .success : .none, failing: failing)
    }

    // MARK: The list

    var ciList: CIList { Self.ciList(repos: ciRepos, status: ci, muted: mutedCI) }

    /// Failing repos first, then running; within each the latest change first. The rest keep the user's order,
    /// muted first (so a repo you quieted is easy to find again), then passing, then no runs.
    nonisolated static func ciList(repos: [RepoConfig], status: [String: CIStatus], muted: [String: String]) -> CIList {
        var list = CIList()
        var attention: [CIEntry] = []
        var quiet: [[CIEntry]] = [[], [], []]
        for repo in repos {
            let state = status[repo.fullName]?.state ?? CIState.none
            let isMuted = isMuted(repo.fullName, status: status, muted: muted)
            let entry = CIEntry(repo: repo, status: status[repo.fullName], state: state, muted: isMuted)
            if !isMuted, state == .failure || state == .pending {
                attention.append(entry)
            } else {
                quiet[isMuted ? 0 : state == .none ? 2 : 1].append(entry)
            }
        }
        list.attention = attention.sorted {
            let (a, b) = ($0.state == .failure ? 0 : 1, $1.state == .failure ? 0 : 1)
            if a != b { return a < b }
            return ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast)
        }
        list.quiet = quiet.flatMap { $0 }
        var seen: Set<String> = []
        for repo in repos where !seen.insert(repo.name.lowercased()).inserted { list.shared.insert(repo.name.lowercased()) }
        return list
    }

    // MARK: Freshness

    func lastCICheck(_ name: String) -> Date? { ciCheckedAt[name] ?? ci[name]?.checkedAt }

    /// How old what the CI rows show is: the oldest answer GitHub gave for a repo whose CI is on. Failed polls don't
    /// move it, so rows can't look fresh while nothing is being checked. Nil until something has been checked.
    var ciFreshness: Date? { ciRepos.compactMap { lastCICheck($0.fullName) }.min() }

    // MARK: Checking

    /// Checks one repo's CI. A request while one is under way for the same repo waits for that one's answer instead
    /// of asking again, so "Check now" pressed twice, or during a poll, is one round trip.
    func syncCI(_ name: String) async throws {
        if let running = ciChecks[name] { return try await running.value }
        guard let repo = repos.first(where: { $0.fullName == name }), repo.events.contains(.ciMain) else { return }
        let ticket = (ciTickets[name] ?? 0) + 1
        ciTickets[name] = ticket
        let check = Task { @MainActor [self] in
            // A check `endCIChecks` already gave up on leaves what a newer one registered.
            defer { if ciTickets[name] == ticket { ciChecks[name] = nil } }
            let status = try await (ciFetch ?? fetchCI)(repo)
            publishCI(name, status, ticket: ticket)
        }
        ciChecks[name] = check
        try await check.value
    }

    /// Whatever is under way for a repo no longer counts: it was removed or its CI turned off, and what comes back
    /// must not bring it back.
    func endCIChecks(_ name: String) {
        ciTickets[name, default: 0] += 1
        ciChecks[name] = nil
    }

    /// Asks GitHub for a repo's CI, and the commit's headline.
    private func fetchCI(_ repo: RepoConfig) async throws -> CIStatus {
        let name = repo.fullName
        var repo = repo
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
        let target = sha ?? ref
        async let checksReq: GHCheckRuns = gh.get("/repos/\(name)/commits/\(target)/check-runs", ["per_page": "100"])
        async let statusReq: GHCombinedStatus = gh.get("/repos/\(name)/commits/\(target)/status")
        let (checks, combined) = try await (checksReq, statusReq)
        let reading = Self.readCI(runs: actions.workflowRuns, sha: sha, checks: checks.checkRuns, combined: combined)
        let commit = sha ?? combined.sha
        // The headline comes from the Actions run; a repo with only external CI asks the commit for it (once per commit).
        let title = await ciHeadline(name, commit: commit, runTitle: actions.workflowRuns.first?.displayTitle)
        return CIStatus(state: reading.state, branch: branch, sha: commit,
                        url: URL(string: "https://github.com/\(name)/commit/\(commit)"),
                        failing: reading.failing, checkedAt: Date(), title: title, updatedAt: reading.changedAt)
    }

    /// Takes an answer in, unless a newer check or the repo's removal has overtaken it. Nothing here waits: what the
    /// repo was before (for the mute and the notifications) is read in the same step that replaces it.
    func publishCI(_ name: String, _ status: CIStatus, ticket: Int) {
        guard ciTickets[name] == ticket else { return }
        let previous = ci[name]?.state
        unmuteCIIfChanged(name, to: status)
        // `checkedAt` always differs: only a real change is worth an assignment (and a re-render, and a save).
        ciCheckedAt[name] = status.checkedAt
        if var old = ci[name] {
            old.checkedAt = status.checkedAt
            if old != status { ci[name] = status; save() }
        } else {
            ci[name] = status
            save()
        }

        let (state, commit, branch) = (status.state, status.sha ?? "", status.branch)
        if previous == .success || previous == .pending, state == .failure {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI failing on \(branch)",
                   subtitle: status.failing.prefix(3).joined(separator: ", "), body: "", quiet: false)
            pulse += 1
        } else if previous == .failure, state == .success {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI back to green",
                   subtitle: branch, body: "", quiet: true)
        }
    }

    // MARK: Reading GitHub

    /// What CI's three sources say about one commit.
    struct CIReading: Equatable {
        var state: CIState
        var failing: [String]
        /// The latest change among them: an Actions run, an external check run or a legacy status.
        var changedAt: Date?
    }

    /// Folds Actions runs (the latest of each workflow, on `sha`) and their jobs, external check runs and legacy
    /// statuses into one state, the names that failed and when it last changed. Any of the three can be all a repo has.
    nonisolated static func readCI(runs: [GHWorkflowRuns.Run], sha: String?, checks: [GHCheckRuns.Run],
                                   combined: GHCombinedStatus) -> CIReading {
        var latest: [Int: GHWorkflowRuns.Run] = [:]
        for run in runs where run.headSha == sha && latest[run.workflowId] == nil { latest[run.workflowId] = run }
        let external = checks.filter { $0.app?.slug != "github-actions" }

        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        // A failed workflow is named by the jobs that failed in it (each is a check run in the run's own suite); its own
        // name stands in only when none is found. Jobs of runs not chosen above (another trigger) never count.
        let jobs = checks.filter { $0.app?.slug == "github-actions" && bad.contains($0.conclusion ?? "") }
        var failing: [String] = []
        for run in latest.values.filter({ bad.contains($0.conclusion ?? "") }).sorted(by: { $0.name < $1.name }) {
            let failed = jobs.filter { run.checkSuiteId != nil && $0.checkSuite?.id == run.checkSuiteId }.map(\.name)
            failing += failed.isEmpty ? [run.name] : failed
        }
        failing += external.filter { bad.contains($0.conclusion ?? "") }.map(\.name)
        failing += combined.statuses.filter { $0.state == "failure" || $0.state == "error" }.map(\.context)
        let pending = latest.values.contains { $0.status != "completed" }
            || external.contains { $0.status != "completed" }
            // design-lint: ignore (GitHub's own status name, not ours)
            || combined.statuses.contains { $0.state == "pending" }
        let any = !latest.isEmpty || !external.isEmpty || combined.totalCount > 0
        let state: CIState = !failing.isEmpty ? .failure : pending ? .pending : any ? .success : .none
        let changed = latest.values.compactMap(\.updatedAt)
            + external.compactMap { $0.completedAt ?? $0.startedAt }
            + combined.statuses.compactMap { $0.updatedAt ?? $0.createdAt }
        return CIReading(state: state, failing: failing, changedAt: changed.max())
    }

    /// The commit's headline: the Actions run's title when there is one; else what the commit says, asked once per
    /// commit (a repo with only external CI has no run to read it from).
    func ciHeadline(_ name: String, commit: String, runTitle: String?) async -> String? {
        if let runTitle { return runTitle }
        if let known = ci[name], known.sha == commit, let title = known.title { return title }
        let found: GHCommit? = try? await gh.get("/repos/\(name)/commits/\(commit)")
        return found?.headline
    }

    // MARK: Opening

    /// The repo the bar's CI cell opens: the latest change among the repos in the state the bar shows. A muted repo
    /// isn't one of them (the bar doesn't count it), unless nothing else is left.
    var ciWorstRepo: RepoConfig? {
        let entries = ciList.entries
        let worst = ciWorst.state
        let shown = entries.filter { !$0.muted && $0.state == worst }
        return (shown.isEmpty ? entries : shown).max { ($0.changedAt ?? .distantPast) < ($1.changedAt ?? .distantPast) }?.repo
    }

    func openWorstChecks() {
        if let repo = ciWorstRepo { openChecks(repo) }
    }

    /// A repo's checks for its latest commit (its Actions page until a run is known).
    func checksURL(_ repo: RepoConfig) -> URL {
        ci[repo.fullName]?.url?.appendingPathComponent("checks") ?? repo.url.appendingPathComponent("actions")
    }

    /// The commit CI last ran on (the repo's page until a run is known).
    func commitURL(_ repo: RepoConfig) -> URL { ci[repo.fullName]?.url ?? repo.url }

    func openChecks(_ repo: RepoConfig) { open(checksURL(repo), as: "Open checks · \(repo.fullName)") }
    func openCommit(_ repo: RepoConfig) { open(commitURL(repo), as: "Open commit · \(repo.fullName)") }
    func openRepository(_ repo: RepoConfig) { open(repo.url, as: "Open repository · \(repo.fullName)") }

    /// Through the playground's interception, like every other open.
    private func open(_ url: URL, as description: String) {
        if let interceptOpen { interceptOpen(description) } else { NSWorkspace.shared.open(url) }
    }

    func copyChecksURL(_ repo: RepoConfig) { copy(checksURL(repo).absoluteString, as: "Copy link · \(repo.fullName)") }

    func copyCommitSHA(_ repo: RepoConfig) {
        guard let sha = ci[repo.fullName]?.sha else { return }
        copy(sha, as: "Copy commit SHA · \(String(sha.prefix(7)))")
    }

    private func copy(_ text: String, as description: String) {
        if let interceptOpen { interceptOpen(description); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Stops showing CI for a repo, like turning its CI toggle off in Repositories, and offers to take it back: the
    /// repo leaves CI's list at once, and its toggle is somewhere else.
    func stopShowingCI(_ repo: RepoConfig) {
        guard repo.events.contains(.ciMain) else { return }
        let title = ciList.title(repo)
        toggle(.ciMain, on: repo)
        registerUndo("Stopped showing CI for \(title)", in: .ci,
                     announcement: "Stopped showing CI for \(repo.name). Undo available") { [self] in
            // Only if it is still off: it may have been turned back on in Repositories since.
            if let now = repos.first(where: { $0.id == repo.id }), !now.events.contains(.ciMain) { toggle(.ciMain, on: now) }
        }
    }
}
