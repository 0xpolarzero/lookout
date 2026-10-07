import Foundation
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
}
