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
        // Every failing repo muted: nothing needs a look, and the one repo that passes is what the bar shows.
        #expect(Store.ciWorst(repos: list, status: ci, muted: ["b/bad": "b1", "d/bad": "d1"]) == CIWorst(state: .success, failing: 0))
        // A muted running repo no longer makes the bar "running".
        let running = ["c/run": status(.pending, sha: "c1")]
        #expect(Store.ciWorst(repos: repos("c/run", "a/ok"), status: running.merging(["a/ok": status(.success)]) { a, _ in a },
                              muted: ["c/run": "c1"]).state == .success)
    }

    @Test func aMutedRepoIsNotPassingSoItNeverMakesTheBarPass() {
        // Only muted repos: nothing passes, and nothing is left to show.
        #expect(Store.ciWorst(repos: repos("b/bad"), status: ["b/bad": status(.failure, sha: "b1")], muted: ["b/bad": "b1"])
                == CIWorst(state: .none, failing: 0))
        // A muted failure beside a repo that has no runs: the bar says no runs, not passing.
        let ci = ["b/bad": status(.failure, sha: "b1")]
        #expect(Store.ciWorst(repos: repos("b/bad", "c/none"), status: ci, muted: ["b/bad": "b1"]) == CIWorst(state: .none, failing: 0))
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
        #expect(store.ciWorst == CIWorst(state: .none, failing: 0))
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

    @Test func theBarsCountNeverNeedsMoreThanTwoCharacters() {
        #expect([1, 9, 10, 15, 120].map(CICell.count) == ["1", "9", "9+", "9+", "9+"])
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

    @Test func theBarOpensARepoInTheStateItShowsNotAMutedFailure() {
        // An older passing repo and a newer failure that was muted: the bar says passing, so it opens the passing one.
        let store = store(["a/ok": status(.success, changed: 5000), "b/bad": status(.failure, sha: "b1", changed: 10)], ["a/ok", "b/bad"])
        store.muteCI(store.repos[1])
        #expect(store.ciWorst.state == .success)
        #expect(store.ciWorstRepo?.fullName == "a/ok")
        // Only muted repos left: the bar still opens something.
        store.ci["a/ok"] = nil
        store.repos.removeFirst()
        #expect(store.ciWorstRepo?.fullName == "b/bad")
    }

    @Test func theBarOpensTheRepoWithoutRunsNotTheMutedFailureBesideIt() {
        let store = store(["b/bad": status(.failure, sha: "b1", changed: 10)], ["b/bad", "c/none"])
        store.muteCI(store.repos[0])
        #expect(store.ciWorst.state == CIState.none)
        #expect(store.ciWorstRepo?.fullName == "c/none")
    }

    @Test func theBarOpensTheNewestOfItsStateAndRepoWithoutRunsWhenNothingElseExists() {
        let store = store(["a/old": status(.success, changed: 900), "b/new": status(.success, changed: 5)], ["a/old", "b/new", "c/none"])
        #expect(store.ciWorstRepo?.fullName == "b/new")
        let none = self.store([:], ["c/none"])
        #expect(none.ciWorst.state == CIState.none)
        #expect(none.ciWorstRepo?.fullName == "c/none")
    }

    // MARK: Undo

    @Test func muteOffersAnUndoThatTakesItBack() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        store.muteCI(store.repos[0])
        #expect(store.undoStack.visible(in: .ci)?.message == "Muted bad until it changes")
        #expect(store.undoLast())
        #expect(store.mutedCI.isEmpty)
        #expect(store.ciWorst == CIWorst(state: .failure, failing: 1))
        #expect(!store.undoLast())
    }

    @Test func anUndoLeavesAloneAMuteThatMovedOn() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        store.muteCI(store.repos[0])
        // A new commit un-muted it, and the new one was muted: undoing the first mute must not touch the second.
        store.unmuteCIIfChanged("b/bad", to: status(.failure, sha: "b2"))
        store.ci["b/bad"] = status(.failure, sha: "b2")
        store.mutedCI["b/bad"] = "b2"
        store.undoLast()
        #expect(store.mutedCI == ["b/bad": "b2"])
    }

    @Test func stoppingCIOffersAnUndoThatTurnsItBackOn() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad", "c/ok"])
        store.ciFetch = { _ in throw CancellationError() }
        store.stopShowingCI(store.repos[0])
        #expect(!store.repos[0].events.contains(.ciMain))
        #expect(store.ciList.entries.map(\.id) == ["c/ok"])
        #expect(store.undoStack.visible(in: .ci)?.message == "Stopped showing CI for bad")
        #expect(store.undoLast())
        #expect(store.repos[0].events.contains(.ciMain))
        #expect(store.ciList.entries.map(\.id) == ["b/bad", "c/ok"])
        #expect(!store.undoLast())
    }

    @Test func undoingStopShowingCILeavesARepoTurnedBackOnAlone() {
        let store = store(["b/bad": status(.failure, sha: "b1")], ["b/bad"])
        store.ciFetch = { _ in throw CancellationError() }
        store.stopShowingCI(store.repos[0])
        // Turned back on in Repositories before the undo: it stays on.
        store.toggle(.ciMain, on: store.repos[0])
        store.undoLast()
        #expect(store.repos[0].events.contains(.ciMain))
    }

    // MARK: The quiet group

    @Test func theQuietGroupCountsOnlyWhatReallyPasses() {
        let list = repos("a/ok", "b/bad", "c/none", "d/ok")
        let ci = ["a/ok": status(.success), "b/bad": status(.failure, sha: "b1"), "c/none": status(CIState.none), "d/ok": status(.success)]
        let rows = Store.ciList(repos: list, status: ci, muted: ["b/bad": "b1"])
        #expect(rows.quietTitle == "Passing · 2, 1 muted, 1 no runs")
        #expect(rows.quietSpeech == "2 passing, 1 muted, 1 no runs")
        #expect(rows.quietName == "Passing")
        let mutedOnly = Store.ciList(repos: repos("b/bad"), status: ["b/bad": status(.failure, sha: "b1")], muted: ["b/bad": "b1"])
        #expect(mutedOnly.quietTitle == "Muted · 1")
        let noRuns = Store.ciList(repos: repos("c/none"), status: [:], muted: [:])
        #expect(noRuns.quietTitle == "No runs · 1")
        let all = Store.ciList(repos: repos("a/x", "b/y"), status: ["a/x": status(.success), "b/y": status(.success)], muted: [:])
        #expect(all.quietTitle == "All passing · 2 repositories")
        #expect(all.quietSpeech == "2 repositories")
    }

    // MARK: Checking

    /// A GitHub the test answers by hand, in the order it likes.
    @MainActor private final class Answers {
        var waiting: [CheckedContinuation<CIStatus, Error>] = []
        var asked = 0

        func fetch(_ repo: RepoConfig) async throws -> CIStatus {
            asked += 1
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        func settle(_ index: Int, with status: CIStatus) { waiting[index].resume(returning: status) }
    }

    private func quiet(_ store: Store) -> (Store, Answers) {
        let answers = Answers()
        store.settings.notifications = false
        store.ciFetch = { try await answers.fetch($0) }
        return (store, answers)
    }

    /// Lets the tasks the test started run until `condition` holds (or two seconds have passed).
    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func checksForOneRepoWhileOneIsUnderWayShareItsAnswer() async {
        let (store, answers) = quiet(store([:], ["a/x"]))
        async let first: () = { try? await store.syncCI("a/x") }()
        async let second: () = { try? await store.syncCI("a/x") }()
        await settle { answers.waiting.count == 1 }
        async let third: () = { try? await store.syncCI("a/x") }()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answers.asked == 1)
        answers.settle(0, with: status(.failure, sha: "s1"))
        _ = await (first, second, third)
        #expect(store.ci["a/x"]?.sha == "s1")
        // Once it has answered, the next check asks again.
        async let next: () = { try? await store.syncCI("a/x") }()
        await settle { answers.waiting.count == 2 }
        answers.settle(1, with: status(.success, sha: "s2"))
        await next
        #expect(store.ci["a/x"]?.sha == "s2")
    }

    @Test func anOlderAnswerThatArrivesLastDoesNotReplaceANewerOneOrItsMute() async {
        let (store, answers) = quiet(store(["a/x": status(.failure, sha: "s0")], ["a/x"]))
        let repo = store.repos[0]
        async let older: () = { try? await store.syncCI("a/x") }()
        await settle { answers.waiting.count == 1 }
        // CI turned off and on again while that check was out: the check it starts is the newer one.
        store.toggle(.ciMain, on: repo)
        store.toggle(.ciMain, on: repo)
        await settle { answers.waiting.count == 2 }
        answers.settle(1, with: status(.failure, sha: "s2"))
        await settle { store.ci["a/x"]?.sha == "s2" }
        store.muteCI(store.repos[0])
        answers.settle(0, with: status(.failure, sha: "s1"))
        await older
        #expect(store.ci["a/x"]?.sha == "s2")
        #expect(store.mutedCI == ["a/x": "s2"])
    }

    @Test func aFailureIsNotifiedOnceWhenTwoChecksBothSeeIt() async {
        let (store, answers) = quiet(store(["a/x": status(.success, sha: "s0")], ["a/x"]))
        let repo = store.repos[0]
        async let older: () = { try? await store.syncCI("a/x") }()
        await settle { answers.waiting.count == 1 }
        store.toggle(.ciMain, on: repo)
        store.toggle(.ciMain, on: repo)
        await settle { answers.waiting.count == 2 }
        answers.settle(1, with: status(.failure, sha: "s1"))
        answers.settle(0, with: status(.failure, sha: "s1"))
        await older
        await settle { store.ci["a/x"]?.state == .failure }
        #expect(store.pulse == 1)
    }

    @Test func aCheckThatReturnsAfterTheRepoWasRemovedLeavesNothingBehind() async {
        let (store, answers) = quiet(store([:], ["a/x"]))
        async let check: () = { try? await store.syncCI("a/x") }()
        await settle { answers.waiting.count == 1 }
        store.removeRepo(store.repos[0])
        answers.settle(0, with: status(.success))
        await check
        #expect(store.ci.isEmpty)
    }

    // MARK: Freshness

    private func checked(_ ago: TimeInterval) -> CIStatus {
        var s = status(.success)
        s.checkedAt = now.addingTimeInterval(-ago)
        return s
    }

    @Test func freshnessIsTheOldestCheckOfARepoWithCIOn() {
        let store = store(["a/new": checked(60), "b/old": checked(7200), "c/off": checked(99999)], ["a/new", "b/old", "c/off"])
        store.repos[2].events.remove(.ciMain)
        #expect(store.ciFreshness == now.addingTimeInterval(-7200))
        // Nothing checked yet: no date, so no "Last checked" line.
        #expect(self.store([:], ["a/x"]).ciFreshness == nil)
    }

    // MARK: Reading GitHub's answer

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func check(_ name: String, _ status: String = "completed", _ conclusion: String? = "success", started: TimeInterval = 0,
                       completed: TimeInterval? = nil, app: String? = "circleci") -> GHCheckRuns.Run {
        GHCheckRuns.Run(app: GHCheckRuns.App(slug: app), name: name, status: status, conclusion: conclusion, headSha: "s",
                        startedAt: t0.addingTimeInterval(started), completedAt: completed.map { t0.addingTimeInterval($0) })
    }

    private func combined(_ statuses: [GHCombinedStatus.Status] = []) -> GHCombinedStatus {
        GHCombinedStatus(state: "success", totalCount: statuses.count, sha: "s", statuses: statuses)
    }

    @Test func aRepoWithOnlyExternalChecksHasAStateNamesAndAChangeTime() {
        let failed = Store.readCI(runs: [], sha: nil, checks: [check("build", "completed", "failure", started: 10, completed: 90),
                                                                check("lint", started: 5, completed: 40)], combined: combined())
        #expect(failed.state == .failure)
        #expect(failed.failing == ["build"])
        #expect(failed.changedAt == t0.addingTimeInterval(90))
        let running = Store.readCI(runs: [], sha: nil, checks: [check("build", "in_progress", nil, started: 30)], combined: combined())
        #expect(running.state == .pending)
        // Still running: it last changed when it started.
        #expect(running.changedAt == t0.addingTimeInterval(30))
    }

    @Test func aRepoWithOnlyLegacyStatusesHasAChangeTime() {
        let status = GHCombinedStatus.Status(context: "ci/jenkins", state: "failure", createdAt: t0, updatedAt: t0.addingTimeInterval(20))
        let reading = Store.readCI(runs: [], sha: nil, checks: [], combined: combined([status]))
        #expect(reading == Store.CIReading(state: .failure, failing: ["ci/jenkins"], changedAt: t0.addingTimeInterval(20)))
        let neverUpdated = GHCombinedStatus.Status(context: "ci/x", state: "success", createdAt: t0, updatedAt: nil)
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: combined([neverUpdated])).changedAt == t0)
    }

    @Test func theLatestChangeAmongActionsAndExternalSourcesWins() {
        let run = GHWorkflowRuns.Run(name: "build", workflowId: 1, headSha: "s", displayTitle: "Fix", updatedAt: t0.addingTimeInterval(50),
                                     status: "completed", conclusion: "success")
        let other = GHWorkflowRuns.Run(name: "old", workflowId: 2, headSha: "older", displayTitle: nil, updatedAt: t0.addingTimeInterval(500),
                                       status: "completed", conclusion: "failure")
        // A github-actions check run is the Actions run again, not an external source.
        let mirror = check("build", started: 0, completed: 900, app: "github-actions")
        let external = check("deploy", started: 10, completed: 70)
        let reading = Store.readCI(runs: [run, other], sha: "s", checks: [mirror, external], combined: combined())
        #expect(reading.state == .success)
        #expect(reading.changedAt == t0.addingTimeInterval(70))
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: combined()) == Store.CIReading(state: .none, failing: [], changedAt: nil))
    }

    @Test func aCommitsHeadlineIsItsFirstLine() throws {
        let decoder = JSONDecoder()
        let commit = try decoder.decode(GHCommit.self, from: Data(#"{"commit":{"message":"Respect trailing commas (#1042)\n\nLong body"}}"#.utf8))
        #expect(commit.headline == "Respect trailing commas (#1042)")
    }

    @Test func aHeadlineIsOnlyAskedForWhenTheRunHasNone() async {
        let store = store(["a/x": status(.failure, sha: "c1")], ["a/x"])
        #expect(await store.ciHeadline("a/x", commit: "c1", runTitle: "From the run") == "From the run")
        store.ci["a/x"]?.title = "Known"
        // Same commit as last time: what was fetched then stands (no request).
        #expect(await store.ciHeadline("a/x", commit: "c1", runTitle: nil) == "Known")
    }
}
