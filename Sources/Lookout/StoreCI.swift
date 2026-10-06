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

    /// Quiets a repo until its commit or state changes: out of the worst state and the bar's glyph.
    func muteCI(_ repo: RepoConfig) {
        guard let status = ci[repo.fullName] else { return }
        mutedCI[repo.fullName] = status.sha ?? ""
        save()
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

    /// What the bar shows of CI: the worst state among the repos that aren't muted, and how many fail. A muted repo
    /// counts as quiet, not as missing: with only muted repos left the bar reads passing, not "no runs".
    var ciWorst: CIWorst { Self.ciWorst(repos: ciRepos, status: ci, muted: mutedCI) }

    nonisolated static func ciWorst(repos: [RepoConfig], status: [String: CIStatus], muted: [String: String]) -> CIWorst {
        var failing = 0
        var running = false
        var passing = false
        for repo in repos {
            let state = status[repo.fullName]?.state ?? CIState.none
            if isMuted(repo.fullName, status: status, muted: muted) { passing = true; continue }
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

    // MARK: Opening

    /// The repo the bar's CI cell opens: the worst one, the latest change first.
    var ciWorstRepo: RepoConfig? {
        let list = ciList
        return (list.attention.first ?? list.entries.max { ($0.changedAt ?? .distantPast) < ($1.changedAt ?? .distantPast) })?.repo
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

    /// Stops showing CI for a repo, like turning its CI toggle off in Repositories.
    func stopShowingCI(_ repo: RepoConfig) {
        if repo.events.contains(.ciMain) { toggle(.ciMain, on: repo) }
    }
}
