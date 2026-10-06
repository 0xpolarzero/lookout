import Foundation
import os
import Testing
@testable import Lookout

/// What the client remembers of GitHub's answers: a 304 costs nothing to read, and what a poll visits stays remembered.
@Suite(.serialized) struct GitHubClientCache {
    /// Counts how many times a body was parsed.
    private struct Counted: Decodable {
        static let decoded = OSAllocatedUnfairLock(initialState: 0)
        let id: Int
        init(from decoder: Decoder) throws {
            Self.decoded.withLock { $0 += 1 }
            id = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .id)
        }
        private enum CodingKeys: String, CodingKey { case id }
    }

    /// A GitHub that gives every path an ETag and answers 304 to a request that has it; counts the full answers.
    private final class Server: @unchecked Sendable {
        let full = OSAllocatedUnfairLock(initialState: 0)

        var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                let url = request.url!
                let etag = "\"\(url.path)\""
                if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: ["ETag": etag])!)
                }
                full.withLock { $0 += 1 }
                return (Data(#"{"id": 7}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": etag])!)
            }
        }
    }

    @Test func aNotModifiedAnswerIsNotParsedAgain() async throws {
        let client = GitHubClient()
        let server = Server()
        client.transport = server.transport
        Counted.decoded.withLock { $0 = 0 }
        let first: Counted = try await client.get("/repos/a/b/issues")
        let second: Counted = try await client.get("/repos/a/b/issues")
        #expect(first.id == 7 && second.id == 7)
        #expect(server.full.withLock { $0 } == 1)
        #expect(Counted.decoded.withLock { $0 } == 1)
        // Asked for as another type, the same body is parsed as that one.
        let other: [String: Int] = try await client.get("/repos/a/b/issues")
        #expect(other == ["id": 7])
    }

    @Test func aPollThroughEveryRepositoryKeepsEveryAnswerItAsksForAgain() async throws {
        let client = GitHubClient()
        let server = Server()
        client.transport = server.transport
        let repositories = 40
        client.reserveETags(forRepositories: repositories)
        // Six answers a repository, visited in turn as a poll does, twice.
        for _ in 0..<2 {
            for r in 0..<repositories {
                for path in ["issues", "issues/comments", "pulls/comments", "actions/runs"] {
                    let _: Counted = try await client.get("/repos/o/r\(r)/\(path)")
                }
                let _: Counted = try await client.get("/repos/o/r\(r)/commits/\(String(repeating: "a", count: 40))/check-runs")
                let _: Counted = try await client.get("/repos/o/r\(r)/commits/\(String(repeating: "a", count: 40))/status")
            }
        }
        // Only the first visit was answered in full: the second was all 304s.
        #expect(server.full.withLock { $0 } == repositories * 6)
    }

    @Test func aNewCommitsAnswersTakeThePlaceOfTheOldOnes() async throws {
        let client = GitHubClient()
        client.transport = Server().transport
        for sha in ["a", "b", "c"] {
            let commit = String(repeating: sha, count: 40)
            let _: Counted = try await client.get("/repos/o/r/commits/\(commit)/check-runs")
            let _: Counted = try await client.get("/repos/o/r/commits/\(commit)/status")
        }
        #expect(client.remembered == 2)
        // Another repository's are its own.
        let _: Counted = try await client.get("/repos/o/other/commits/\(String(repeating: "a", count: 40))/status")
        #expect(client.remembered == 3)
    }

    @Test func nothingIsAskedOfTheCoreBudgetBetweenItsEndAndItsResetButSearchStillIs() async throws {
        let client = GitHubClient()
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let reset = Date().addingTimeInterval(600)
        client.transport = { request in
            let url = request.url!
            asked.withLock { $0.append(url.path) }
            let limits = ["x-ratelimit-resource": "core", "x-ratelimit-remaining": "0",
                          "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))]
            return (Data(#"{"id": 7}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: limits)!)
        }
        let _: Counted = try await client.get("/repos/o/r/issues")
        #expect(client.rateRemaining == 0)
        await #expect(throws: GitHubError.self) { let _: Counted = try await client.get("/repos/o/r/issues") }
        let _: Counted = try await client.get("/search/issues")
        #expect(asked.withLock { $0 } == ["/repos/o/r/issues", "/search/issues"])
    }

    /// Holds a request until the test lets it through.
    private actor AsyncGate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async { if !isOpen { await withCheckedContinuation { waiting.append($0) } } }
        func open() { isOpen = true; waiting.forEach { $0.resume() }; waiting = [] }
    }

    @Test func anotherTokenStartsWithItsOwnBudgetAndNothingTheOldOneAskedForReachesIt() async throws {
        let client = GitHubClient()
        let reset = Date().addingTimeInterval(600)
        let gate = AsyncGate()
        client.token = "a"
        client.transport = { request in
            let url = request.url!
            // The old account's last answer is still on its way when the token changes.
            if url.path == "/search/slow" { await gate.wait() }
            let limits = ["x-ratelimit-resource": "core", "x-ratelimit-remaining": "0", "ETag": "\"e\"",
                          "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))]
            return (Data(#"{"id": 7}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: limits)!)
        }
        let _: Counted = try await client.get("/repos/o/r/issues")
        #expect(client.rateRemaining == 0 && client.remembered == 1)
        let late = Task { let _: Counted = try await client.get("/search/slow") }
        await Task.yield()
        client.token = "b"
        #expect(client.rateRemaining == nil && client.rateResetsAt == nil && client.remembered == 0)
        let _: Counted = try await client.get("/user")
        #expect(client.rateRemaining == 0)
        client.token = "c"
        await gate.open()
        _ = try await late.value
        #expect(client.rateRemaining == nil && client.remembered == 0)
    }
}

/// The answers the idle gate's polling run serves (`--canned`): a poll through them gets every source of every repository, the
/// first time in full and the next time (the repository's branch and a commit's headline, asked once, apart) as 304s.
@MainActor
@Suite struct CannedPolling {
    @Test func aPollGetsEverySourceAndTheNextOneIsAll304s() async {
        let s = Store()
        Demo.populate(s, .agents)
        s.settings.reviewRequests = false
        s.lastSync = nil
        s.repoErrors = [:]
        let statuses = OSAllocatedUnfairLock(initialState: [Int]())
        s.gh.transport = { request in
            let answer = try await CannedGitHub.transport(request)
            // (The graph has no ETag: it is answered in full every time.)
            if request.url!.path != "/graphql" { statuses.withLock { $0.append((answer.1 as! HTTPURLResponse).statusCode) } }
            return answer
        }
        await s.pollAll()
        let first = statuses.withLock { $0 }
        #expect(s.repoErrors.isEmpty && !first.isEmpty && first.allSatisfy { $0 == 200 }, "\(s.repoErrors) \(first)")
        // What the CI answers say reached the store: the demo's failing repository passes in them.
        #expect(s.ci["apple/swift-format"]?.state == .success)
        statuses.withLock { $0 = [] }
        await s.pollAll()
        let second = statuses.withLock { $0 }
        #expect(s.repoErrors.isEmpty && !second.isEmpty && second.allSatisfy { $0 == 304 }, "\(second)")
    }
}
