import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct CI {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ state: CIState, sha: String? = "aaa", failing: [String] = [], changed: TimeInterval = 0) -> CIStatus {
        CIStatus(state: state, branch: "main", sha: sha, url: nil, failing: failing, checkedAt: now, title: nil,
                 updatedAt: now.addingTimeInterval(-changed))
    }

    private func repos(_ names: String...) -> [RepoConfig] { names.map { RepoConfig(fullName: $0) } }

    private func store(_ ci: [String: CIStatus], _ names: [String]) -> Store {
        let store = Store()
        store.persists = false
        store.repos = names.map { RepoConfig(fullName: $0) }
        store.ci = ci
        return store
    }

    // MARK: Worst state

    @Test func theWorstStateWinsAndFailingReposAreCounted() {
        let list = repos("a/ok", "b/bad", "c/run", "d/bad")
        let ci = ["a/ok": status(.success), "b/bad": status(.failure), "c/run": status(.pending), "d/bad": status(.failure)]
        #expect(Store.ciWorst(repos: list, status: ci, muted: [:]) == CIWorst(state: .failure, failing: 2))
        #expect(Store.ciWorst(repos: list, status: ci.filter { $0.value.state != .failure }, muted: [:])
                == CIWorst(state: .pending, failing: 0))
        #expect(Store.ciWorst(repos: [], status: [:], muted: [:]) == CIWorst(state: .none, failing: 0))
        // No status yet: no runs.
        #expect(Store.ciWorst(repos: list, status: [:], muted: [:]) == CIWorst(state: .none, failing: 0))
    }

    @Test func aMutedRepoIsLeftOutOfTheWorstStateAndTheCount() {
        let list = repos("a/ok", "b/bad", "d/bad")
        let ci = ["a/ok": status(.success), "b/bad": status(.failure, sha: "b1"), "d/bad": status(.failure, sha: "d1")]
        #expect(Store.ciWorst(repos: list, status: ci, muted: ["b/bad": "b1"]) == CIWorst(state: .failure, failing: 1))
        // Every failing repo muted: nothing needs a look, and the bar reads passing, not "no runs".
        #expect(Store.ciWorst(repos: list, status: ci, muted: ["b/bad": "b1", "d/bad": "d1"]) == CIWorst(state: .success, failing: 0))
        // A muted running repo no longer makes the bar "running".
        let running = ["c/run": status(.pending, sha: "c1")]
        #expect(Store.ciWorst(repos: repos("c/run"), status: running, muted: ["c/run": "c1"]).state == .success)
    }

    @Test func aMuteEndsWhenTheShaMoves() {
        let list = repos("b/bad")
        let muted = ["b/bad": "b1"]
        #expect(Store.ciWorst(repos: list, status: ["b/bad": status(.failure, sha: "b1")], muted: muted).failing == 0)
        #expect(Store.ciWorst(repos: list, status: ["b/bad": status(.failure, sha: "b2")], muted: muted).failing == 1)
        // Muted with no sha known: it holds until one shows up.
        #expect(Store.isMuted("x/y", status: ["x/y": status(.failure, sha: nil)], muted: ["x/y": ""]))
        #expect(!Store.isMuted("x/y", status: ["x/y": status(.failure, sha: "z")], muted: ["x/y": ""]))
    }

    @Test func aMuteEndsWhenTheStateChangesEvenOnTheSameSha() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        let repo = store.repos[0]
        store.muteCI(repo)
        #expect(store.mutedCI == ["b/bad": "b1"])
        #expect(store.ciWorst == CIWorst(state: .success, failing: 0))
        // Polled again, nothing changed: still muted.
        store.unmuteCIIfChanged("b/bad", to: status(.failure, sha: "b1"))
        #expect(store.isCIMuted(repo))
        // The failed jobs re-run on the same commit: heard again.
        store.unmuteCIIfChanged("b/bad", to: status(.pending, sha: "b1"))
        #expect(store.mutedCI.isEmpty)
        #expect(store.ciWorst == CIWorst(state: .failure, failing: 1))
    }

    @Test func aMuteEndsWhenANewCommitIsSynced() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        store.muteCI(store.repos[0])
        store.unmuteCIIfChanged("b/bad", to: status(.failure, sha: "b2"))
        #expect(store.mutedCI.isEmpty)
    }

    @Test func unmutingAndRemovingARepoForgetTheMute() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        let repo = store.repos[0]
        store.muteCI(repo)
        store.unmuteCI(repo)
        #expect(store.mutedCI.isEmpty)
        store.muteCI(repo)
        store.removeRepo(repo)
        #expect(store.mutedCI.isEmpty)
    }

    @Test func aMuteSurvivesASaveAndALoad() throws {
        var state = PersistedState(repos: [], items: [], ci: [:], settings: AppSettings(), agents: nil, mutedCI: ["a/b": "abc"])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        state = try dec.decode(PersistedState.self, from: enc.encode(state))
        #expect(state.mutedCI == ["a/b": "abc"])
    }

    // MARK: The list

    @Test func failingRowsComeFirstThenTheLatestChange() {
        let list = repos("a/old-run", "b/new-run", "c/old-bad", "d/new-bad", "e/ok")
        let ci = [
            "a/old-run": status(.pending, changed: 900), "b/new-run": status(.pending, changed: 10),
            "c/old-bad": status(.failure, changed: 5000), "d/new-bad": status(.failure, changed: 60), "e/ok": status(.success),
        ]
        let rows = Store.ciList(repos: list, status: ci, muted: [:])
        #expect(rows.attention.map(\.id) == ["d/new-bad", "c/old-bad", "b/new-run", "a/old-run"])
        #expect(rows.quiet.map(\.id) == ["e/ok"])
    }

    @Test func theQuietGroupHoldsMutedFirstThenPassingThenNoRuns() {
        let list = repos("a/ok", "b/bad", "c/none", "d/ok")
        let ci = ["a/ok": status(.success), "b/bad": status(.failure, sha: "b1"), "c/none": status(CIState.none), "d/ok": status(.success)]
        let rows = Store.ciList(repos: list, status: ci, muted: ["b/bad": "b1"])
        #expect(rows.attention.isEmpty)
        #expect(rows.quiet.map(\.id) == ["b/bad", "a/ok", "d/ok", "c/none"])
        #expect(rows.quiet.first?.muted == true)
        #expect(!rows.allPassing)
    }

    @Test func allGreenIsOneQuietGroup() {
        let rows = Store.ciList(repos: repos("a/x", "b/y"), status: ["a/x": status(.success), "b/y": status(.success)], muted: [:])
        #expect(rows.attention.isEmpty)
        #expect(rows.allPassing)
        #expect(Store.ciList(repos: [], status: [:], muted: [:]).isEmpty)
    }

    @Test func theOwnerShowsOnlyOnANameCollision() {
        let rows = Store.ciList(repos: repos("apple/swift-nio", "other/Swift-NIO", "a/lcu"), status: [:], muted: [:])
        #expect(rows.title(RepoConfig(fullName: "apple/swift-nio")) == "apple/swift-nio")
        #expect(rows.title(RepoConfig(fullName: "a/lcu")) == "lcu")
    }

    // MARK: Opening and speaking

    @Test func theBarOpensTheWorstReposChecks() {
        let store = store(["a/ok": status(.success), "b/run": status(.pending), "c/bad": status(.failure, sha: "c1")], ["a/ok", "b/run", "c/bad"])
        #expect(store.ciWorstRepo?.fullName == "c/bad")
        store.muteCI(store.repos[2])
        #expect(store.ciWorstRepo?.fullName == "b/run")
    }

    @Test func rowsAreSpokenWithTheirNamesAndAges() {
        var entry = CIEntry(repo: RepoConfig(fullName: "apple/swift-format"),
                            status: status(.failure, failing: ["Linux / build", "Windows / test"], changed: 45 * 60), state: .failure, muted: false)
        #expect(CISpeech.value(entry, now: now) == "failing, Linux build and Windows test, 45 minutes ago")
        entry = CIEntry(repo: entry.repo, status: status(.pending, changed: 30), state: .pending, muted: false)
        #expect(CISpeech.value(entry, now: now) == "running, just now")
        #expect(CISpeech.age(now.addingTimeInterval(-3600), now: now) == "1 hour ago")
        #expect(CISpeech.list(["a", "b", "c"]) == "a, b and c")
    }
}
