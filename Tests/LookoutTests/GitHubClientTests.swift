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

        var session: URLSession {
            StubbedGitHub.session { [self] request in
                let etag = "\"\(request.url!.path)\""
                if request.value(forHTTPHeaderField: "If-None-Match") == etag { return .init(304, headers: ["ETag": etag]) }
                full.withLock { $0 += 1 }
                return .init(200, #"{"id": 7}"#, headers: ["ETag": etag])
            }
        }
    }

    @Test func aNotModifiedAnswerIsNotParsedAgain() async throws {
        let client = GitHubClient()
        let server = Server()
        client.session = server.session
        // Every other test parses `Counted` too: count by the path only this one asks for.
        let before = Counted.decoded.withLock { $0 }
        let first: Counted = try await client.get("/repos/a/b/issues")
        let second: Counted = try await client.get("/repos/a/b/issues")
        #expect(first.id == 7 && second.id == 7)
        #expect(server.full.withLock { $0 } == 1)
        #expect(Counted.decoded.withLock { $0 } - before == 1)
        // Asked for as another type, the same body is parsed as that one.
        let other: [String: Int] = try await client.get("/repos/a/b/issues")
        #expect(other == ["id": 7])
    }

    @Test func aPollThroughEveryRepositoryKeepsEveryAnswerItAsksForAgain() async throws {
        let client = GitHubClient()
        let server = Server()
        client.session = server.session
        let repositories = 40
        client.reserveETags(forRepositories: repositories)
        let sha = String(repeating: "a", count: 40)
        // Six answers a repository, visited in turn as a poll does, twice.
        for _ in 0..<2 {
            for r in 0..<repositories {
                for path in ["issues", "issues/comments", "pulls/comments", "actions/runs"] {
                    let _: Counted = try await client.get("/repos/o/r\(r)/\(path)")
                }
                let _: Counted = try await client.get("/repos/o/r\(r)/commits/\(sha)/check-runs")
                let _: Counted = try await client.get("/repos/o/r\(r)/commits/\(sha)/status")
            }
        }
        // Only the first visit was answered in full: the second was all 304s.
        #expect(server.full.withLock { $0 } == repositories * 6)
    }

    @Test func aNewCommitsAnswersTakeThePlaceOfTheOldOnes() async throws {
        let client = GitHubClient()
        client.session = Server().session
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
        client.session = StubbedGitHub.session { request in
            asked.withLock { $0.append(request.url!.path) }
            return .init(200, #"{"id": 7}"#, headers: [
                "x-ratelimit-resource": "core", "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ])
        }
        let _: Counted = try await client.get("/repos/o/r/issues")
        #expect(client.rateRemaining == 0)
        #expect(client.rateResetsAt.map { abs($0.timeIntervalSince(reset)) < 1 } == true)
        await #expect(throws: GitHubError.self) { let _: Counted = try await client.get("/repos/o/r/issues") }
        let _: Counted = try await client.get("/search/issues")
        #expect(asked.withLock { $0 } == ["/repos/o/r/issues", "/search/issues"])
    }

    @Test func requestsGoOutAgainOnceTheResetHasPassed() async throws {
        let client = GitHubClient()
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let reset = Date().addingTimeInterval(-5)
        client.session = StubbedGitHub.session { _ in
            asked.withLock { $0 += 1 }
            return .init(200, #"{"id": 7}"#, headers: [
                "x-ratelimit-resource": "core", "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ])
        }
        let _: Counted = try await client.get("/repos/o/r/issues")
        let _: Counted = try await client.get("/repos/o/r/issues")
        #expect(asked.withLock { $0 } == 2)
    }

    @Test func anotherTokenStartsWithItsOwnBudgetAndNothingTheOldOneAskedForReachesIt() async throws {
        let client = GitHubClient()
        let reset = Date().addingTimeInterval(600)
        let gate = StubbedGitHub.Gate()
        client.token = "a"
        client.session = StubbedGitHub.session { request in
            // The old account's last answer is still on its way when the token changes.
            .init(200, #"{"id": 7}"#, headers: [
                "x-ratelimit-resource": "core", "x-ratelimit-remaining": "0", "ETag": "\"e\"",
                "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            ], gate: request.url!.path == "/search/slow" ? gate : nil)
        }
        let _: Counted = try await client.get("/repos/o/r/issues")
        #expect(client.rateRemaining == 0 && client.remembered == 1)
        let late = Task { let _: Counted = try await client.get("/search/slow") }
        while gate.held == 0 { await Task.yield() }
        client.token = "b"
        #expect(client.rateRemaining == nil && client.rateResetsAt == nil && client.remembered == 0)
        let _: Counted = try await client.get("/user")
        #expect(client.rateRemaining == 0)
        client.token = "c"
        gate.open()
        _ = try await late.value
        #expect(client.rateRemaining == nil && client.remembered == 0)
    }
}
