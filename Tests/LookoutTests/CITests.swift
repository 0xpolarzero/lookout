import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lookout

@MainActor
@Suite struct CI {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func check(_ name: String, _ status: String = "completed", _ conclusion: String? = "success", started: TimeInterval = 0,
                       completed: TimeInterval? = nil, app: String? = "circleci", suite: Int? = nil) -> GHCheckRuns.Run {
        GHCheckRuns.Run(app: GHCheckRuns.App(slug: app), checkSuite: suite.map(GHCheckRuns.Suite.init), name: name, status: status, conclusion: conclusion, headSha: "s",
                        startedAt: t0.addingTimeInterval(started), completedAt: completed.map { t0.addingTimeInterval($0) })
    }

    private func combined(_ statuses: [GHCombinedStatus.Status] = []) -> GHCombinedStatus {
        GHCombinedStatus(state: "success", totalCount: statuses.count, sha: "s", statuses: statuses)
    }

    // MARK: Reading GitHub's answer

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
                                     status: "completed", conclusion: "success", checkSuiteId: 10)
        let other = GHWorkflowRuns.Run(name: "old", workflowId: 2, headSha: "older", displayTitle: nil, updatedAt: t0.addingTimeInterval(500),
                                       status: "completed", conclusion: "failure", checkSuiteId: 20)
        // A github-actions check run is the Actions run again, not an external source.
        let mirror = check("build", started: 0, completed: 900, app: "github-actions")
        let external = check("deploy", started: 10, completed: 70)
        let reading = Store.readCI(runs: [run, other], sha: "s", checks: [mirror, external], combined: combined())
        #expect(reading.state == .success)
        #expect(reading.changedAt == t0.addingTimeInterval(70))
        #expect(Store.readCI(runs: [], sha: nil, checks: [], combined: combined()) == Store.CIReading(state: .none, failing: [], changedAt: nil))
    }

    private func workflow(_ name: String, id: Int, suite: Int?, _ conclusion: String?, sha: String = "s",
                          status: String = "completed") -> GHWorkflowRuns.Run {
        GHWorkflowRuns.Run(name: name, workflowId: id, headSha: sha, displayTitle: "Fix", updatedAt: t0, status: status,
                           conclusion: conclusion, checkSuiteId: suite)
    }

    @Test func aFailedWorkflowIsNamedByItsFailedJobs() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        let jobs = [check("Linux build", "completed", "failure", app: "github-actions", suite: 10),
                    check("macOS test", "completed", "success", app: "github-actions", suite: 10),
                    check("Windows test", "completed", "timed_out", app: "github-actions", suite: 10)]
        let reading = Store.readCI(runs: [ci], sha: "s", checks: jobs, combined: combined())
        #expect(reading.state == .failure)
        #expect(reading.failing == ["Linux build", "Windows test"])
    }

    @Test func aFailedWorkflowWithNoJobsKeepsItsOwnName() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        // No job at all, a job of another suite, and a job with no suite known.
        #expect(Store.readCI(runs: [ci], sha: "s", checks: [], combined: combined()).failing == ["CI"])
        let elsewhere = [check("Other", "completed", "failure", app: "github-actions", suite: 99)]
        #expect(Store.readCI(runs: [ci], sha: "s", checks: elsewhere, combined: combined()).failing == ["CI"])
        let unknown = workflow("CI", id: 1, suite: nil, "failure")
        let job = [check("Linux build", "completed", "failure", app: "github-actions")]
        #expect(Store.readCI(runs: [unknown], sha: "s", checks: job, combined: combined()).failing == ["CI"])
    }

    @Test func jobsOfRunsThatDoNotCountAreLeftOut() {
        // A failed job of a workflow run the push's selection didn't take (another trigger, an older run) says nothing.
        let ci = workflow("CI", id: 1, suite: 10, "success")
        let stray = [check("Triage", "completed", "failure", app: "github-actions", suite: 30)]
        #expect(Store.readCI(runs: [ci], sha: "s", checks: stray, combined: combined()).state == .success)
    }

    @Test func actionsJobsAndExternalChecksFailTogether() {
        let ci = workflow("CI", id: 1, suite: 10, "failure")
        let checks = [check("Linux build", "completed", "failure", app: "github-actions", suite: 10),
                      check("deploy", "completed", "failure")]
        let reading = Store.readCI(runs: [ci], sha: "s", checks: checks, combined: combined())
        #expect(reading.failing == ["Linux build", "deploy"])
    }

    @Test func theSuiteLinksAJobToItsWorkflowRunInGitHubsJSON() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(GHCheckRuns.Run.self, from: Data(
            #"{"name":"Linux build","status":"completed","conclusion":"failure","head_sha":"s","app":{"slug":"github-actions"},"check_suite":{"id":10}}"#.utf8))
        let run = try decoder.decode(GHWorkflowRuns.Run.self, from: Data(
            #"{"name":"CI","workflow_id":1,"head_sha":"s","status":"completed","conclusion":"failure","check_suite_id":10}"#.utf8))
        #expect(job.checkSuite?.id == 10 && run.checkSuiteId == 10)
    }

    @Test func aCommitsHeadlineIsItsFirstLine() throws {
        let decoder = JSONDecoder()
        let commit = try decoder.decode(GHCommit.self, from: Data(#"{"commit":{"message":"Respect trailing commas (#1042)\n\nLong body"}}"#.utf8))
        #expect(commit.headline == "Respect trailing commas (#1042)")
    }

    @Test func aHeadlineIsOnlyAskedForWhenTheRunHasNone() async {
        let store = Store()
        store.persists = false
        store.ci["a/x"] = CIStatus(state: .failure, branch: "main", sha: "c1", failing: ["build"], checkedAt: t0, title: nil, updatedAt: nil)
        #expect(await store.ciHeadline("a/x", commit: "c1", runTitle: "From the run") == "From the run")
        store.ci["a/x"]?.title = "Known"
        // Same commit as last time: what was fetched then stands (no request).
        #expect(await store.ciHeadline("a/x", commit: "c1", runTitle: nil) == "Known")
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

        func settle(_ index: Int, with status: CIStatus) {
            guard waiting.indices.contains(index) else { Issue.record("No check \(index) is waiting"); return }
            waiting[index].resume(returning: status)
        }

        func fail(_ index: Int, _ message: String) {
            guard waiting.indices.contains(index) else { Issue.record("No check \(index) is waiting"); return }
            waiting[index].resume(throwing: NSError(domain: "CI", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private func status(_ state: CIState, sha: String) -> CIStatus {
        CIStatus(state: state, branch: "main", sha: sha, failing: state == .failure ? ["build"] : [], checkedAt: Date(), title: nil,
                 updatedAt: t0)
    }

    /// A store watching `names` with CI on, whose checks wait for the test to answer them.
    private func store(_ names: [String] = ["a/x"]) -> (Store, Answers) {
        let store = Store()
        store.persists = false
        store.settings.notifications = false
        store.repos = names.map { RepoConfig(fullName: $0, events: [.ciMain]) }
        let answers = Answers()
        store.ciFetch = { try await answers.fetch($0) }
        return (store, answers)
    }

    /// Lets the main actor turn until `condition` holds (counted in turns, not timed).
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func checksForOneRepoWhileOneIsUnderWayShareItsAnswer() async throws {
        let (store, answers) = store()
        async let first: () = { try? await store.syncCI("a/x") }()
        async let second: () = { try? await store.syncCI("a/x") }()
        try await eventually { answers.waiting.count == 1 }
        async let third: () = { try? await store.syncCI("a/x") }()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(answers.asked == 1)
        answers.settle(0, with: status(.failure, sha: "s1"))
        _ = await (first, second, third)
        #expect(store.ci["a/x"]?.sha == "s1")
        // Once it has answered, the next check asks again.
        async let next: () = { try? await store.syncCI("a/x") }()
        try await eventually { answers.waiting.count == 2 }
        answers.settle(1, with: status(.success, sha: "s2"))
        await next
        #expect(store.ci["a/x"]?.sha == "s2")
    }

    @Test func anOlderAnswerThatArrivesLastDoesNotReplaceANewerOne() async throws {
        let (store, answers) = store()
        let repo = store.repos[0]
        async let older: () = { try? await store.syncCI("a/x") }()
        try await eventually { answers.waiting.count == 1 }
        // CI turned off and on again while that check was out: the check it starts is the newer one.
        store.toggle(.ciMain, on: repo)
        store.toggle(.ciMain, on: store.repos[0])
        try await eventually { answers.waiting.count == 2 }
        answers.settle(1, with: status(.failure, sha: "s2"))
        try await eventually { store.ci["a/x"]?.sha == "s2" }
        answers.settle(0, with: status(.failure, sha: "s1"))
        await older
        #expect(store.ci["a/x"]?.sha == "s2")
    }

    @Test func anAnswerThatArrivesAfterTheRepoWasStoppedBringsNothingBack() async throws {
        let (store, answers) = store()
        async let check: () = { try? await store.syncCI("a/x") }()
        try await eventually { answers.waiting.count == 1 }
        store.removeRepo(store.repos[0])
        answers.settle(0, with: status(.failure, sha: "s1"))
        await check
        #expect(store.ci.isEmpty)
    }

    @Test func anAnswerThatArrivesAfterCIWasSwitchedOffBringsNothingBack() async throws {
        let (store, answers) = store()
        async let check: () = { try? await store.syncCI("a/x") }()
        try await eventually { answers.waiting.count == 1 }
        store.toggle(.ciMain, on: store.repos[0])
        answers.settle(0, with: status(.failure, sha: "s1"))
        await check
        #expect(store.ci.isEmpty)
    }

    @Test func aLateFailureDoesNotBringBackAFaultCIWasClearedOf() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        async let poll: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        // CI is switched off while the check is out, and the check then fails.
        store.toggle(.ciMain, on: store.repos[0])
        answers.fail(0, "Server error")
        await poll
        #expect(store.repoErrors.isEmpty)
    }

    @Test func aFailureOfTheCurrentCheckIsAFault() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        async let poll: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        answers.fail(0, "Server error")
        await poll
        #expect(store.repoErrors["a/x"] == "Server error")
    }

    @Test func aLateFailureOfAStoppedAndWatchedAgainRepoIsNotItsFault() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        async let poll: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        // The repo is stopped and watched anew while its check is out, and the check then fails.
        let repo = store.repos[0]
        store.removeRepo(repo)
        var again = repo
        again.addedAt = repo.addedAt.addingTimeInterval(1)
        store.repos = [again]
        answers.fail(0, "Server error")
        await poll
        #expect(store.repoErrors.isEmpty)
    }

    @Test func aLateAnswerOfAStoppedAndWatchedAgainRepoDoesNotClearItsFault() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        async let poll: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        let repo = store.repos[0]
        store.removeRepo(repo)
        var again = repo
        again.addedAt = repo.addedAt.addingTimeInterval(1)
        store.repos = [again]
        store.repoErrors["a/x"] = "Forbidden"
        answers.settle(0, with: status(.success, sha: "s1"))
        await poll
        #expect(store.repoErrors["a/x"] == "Forbidden")
    }

    @Test func conversationsFailingDoNotKeepCIFromBeingChecked() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        store.repos[0].events = [.issueOpened, .ciMain]
        store.gh.session = StubbedGitHub.session { _ in .init(500, #"{"message": "Not here"}"#) }
        async let poll: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        answers.settle(0, with: status(.success, sha: "s1"))
        await poll
        #expect(store.ci["a/x"]?.sha == "s1")
        // The conversations' fault stays, though CI answered.
        #expect(store.repoErrors["a/x"] == "Not here")
    }

    @Test func eachSourceKeepsItsFaultWhenTheOtherAnswers() async throws {
        let (store, answers) = store()
        store.me = GHUser(login: "me", avatarUrl: nil, type: "User")
        store.settings.reviewRequests = false
        // CI fails; the conversations (none asked for) are fine.
        async let first: () = store.pollAll()
        try await eventually { answers.waiting.count == 1 }
        answers.fail(0, "CI down")
        await first
        #expect(store.repoErrors["a/x"] == "CI down")
        // CI answers: its fault goes.
        async let second: () = store.pollAll()
        try await eventually { answers.waiting.count == 2 }
        answers.settle(1, with: status(.success, sha: "s1"))
        await second
        #expect(store.repoErrors.isEmpty)
    }
}

@Suite(.hostsWindows) struct FailingChecks {
    @Test func theChipNamesTheFailingChecksAndCountsTheRest() {
        #expect(RepoChip.failingSummary(["build"]) == "build")
        #expect(RepoChip.failingSummary(["build", "lint"]) == "build, lint")
        #expect(RepoChip.failingSummary(["build", "lint", "test", "deploy"]) == "build, lint +2")
    }

    @Test func aLongNameIsCutShort() {
        #expect(RepoChip.failingSummary(["Linux build (release, arm64)"]) == "Linux build (re…")
        #expect(RepoChip.failingSummary(["exactly sixteen!"]) == "exactly sixteen!")
    }

    /// What the chip's width is in a flow of `width`, as each chip reports it.
    private struct Widths: PreferenceKey {
        static let defaultValue: [CGFloat] = []
        static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
    }

    @MainActor private func chipWidths(_ chips: [(String, [String])], flow width: CGFloat) -> [CGFloat] {
        var seen: [CGFloat] = []
        let flow = FlowLayout(spacing: 5) {
            ForEach(chips.indices, id: \.self) { i in
                RepoChip(repo: RepoConfig(fullName: chips[i].0), status: CIStatus(state: .failure, branch: "main", failing: chips[i].1,
                                                                                   checkedAt: Date(), title: nil, updatedAt: nil),
                         state: .failure) {}
                    .background(GeometryReader { Color.clear.preference(key: Widths.self, value: [$0.size.width]) })
            }
        }
        .frame(width: width)
        .onPreferenceChange(Widths.self) { seen = $0 }
        let host = NSHostingView(rootView: flow)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: true)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return seen
    }

    @MainActor @Test func wideFailingNamesStayInsideTheFlowTheCIPanelGivesThem() {
        // The horizontal panel gives its chips about 208 pt; a long repo name and wide failing names are more than that.
        let wide = ["WWWWWWWWWWWWWWW", "MMMMMMMMMMMMMMM", "OOOOOOOOOOOOOOO"]
        let widths = chipWidths([("a/swift-format", wide), ("a/another-long-repository-name", wide), ("a/x", ["build"])], flow: 208)
        #expect(widths.count == 3)
        #expect(widths.allSatisfy { $0 <= 208 })
    }
}
