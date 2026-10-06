import Testing
@testable import Lookout

@Suite struct RepoFailureSentences {
    @Test func theSameCauseReadsTheSameWhateverGitHubCalledIt() {
        #expect(RepoFailure(reason: "Not Found") == .notFound)
        #expect(RepoFailure(reason: "Not found (or no access)") == .notFound)
        #expect(RepoFailure(reason: "Forbidden") == .forbidden)
        #expect(RepoFailure(reason: "API rate limit exceeded for user ID 1.") == .rateLimited)
        #expect(RepoFailure(reason: "GitHub rejected the token") == .badToken)
        #expect(RepoFailure(reason: "The Internet connection appears to be offline.") == .unreachable)
        #expect(RepoFailure(reason: "GitHub error 502") == nil)
    }

    @Test func aRowNamesTheRepository() {
        #expect(RepoFailure.sync("Forbidden", of: "e2b-dev/runtime") == "No access to e2b-dev/runtime")
        #expect(RepoFailure.sync("Not found (or no access)", of: "ziglang/zig") == "Couldn't find ziglang/zig, or no access to it")
        #expect(RepoFailure.sync("GitHub error 502", of: "ziglang/zig") == "Couldn't sync ziglang/zig")
    }

    @Test func theAddFieldNamesWhatWasTyped() {
        #expect(RepoFailure.add("Not Found", input: "swift") == "Couldn't find swift on GitHub. Check the owner/repo.")
        #expect(RepoFailure.add("Not Found", input: " https://github.com/apple/swift-format/issues ") == "Couldn't find apple/swift-format on GitHub. Check the owner/repo.")
        #expect(RepoFailure.add("Forbidden", input: "e2b-dev/runtime") == "No access to e2b-dev/runtime")
        // Store's own sentences are left alone.
        #expect(RepoFailure.add("Already watching apple/swift", input: "apple/swift") == "Already watching apple/swift")
        #expect(RepoFailure.add("Use the owner/repo format", input: "swift") == "Use the owner/repo format")
    }
}
