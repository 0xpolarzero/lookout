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

    @Test func theAddFieldNamesWhatWasSubmitted() {
        #expect(RepoFailure.add("Not Found", input: "swift") == "Couldn't find swift on GitHub. Check the owner/repo.")
        #expect(RepoFailure.add("Not Found", input: " https://github.com/apple/swift-format/issues ") == "Couldn't find apple/swift-format on GitHub. Check the owner/repo.")
        #expect(RepoFailure.add("Forbidden", input: "e2b-dev/runtime") == "No access to e2b-dev/runtime")
        // Store's own sentences are left alone.
        #expect(RepoFailure.add("Already watching apple/swift", input: "apple/swift") == "Already watching apple/swift")
        #expect(RepoFailure.add("Use the owner/repo format", input: "swift") == "Use the owner/repo format")
    }

    @Test func aSuggestionIsNamedNotWhatWasTypedToFindIt() {
        // "swift" typed, apple/swift-nio picked: the sentence is about the one that was sent.
        #expect(RepoFailure.add("Not Found", input: "apple/swift-nio") == "Couldn't find apple/swift-nio on GitHub. Check the owner/repo.")
    }

    @Test func aReasonThatIsNotRecognisedIsNotShownAsItIs() {
        #expect(RepoFailure.add("GitHub error 500", input: "apple/swift") == "Couldn't add apple/swift.")
        #expect(RepoFailure.add("The data couldn't be read because it isn't in the correct format.", input: "https://github.com/apple/swift/pulls")
                == "Couldn't add apple/swift.")
    }
}

@Suite struct SignInSentences {
    @Test func theSignedOutRowSaysWhatToDoHere() {
        #expect(SignInFailure.sentence(SignInFailure.missingToken) == "Run gh auth login in Terminal, or use a token.")
    }

    @Test func otherReasonsAreOneSentenceWithoutTheSystemsWording() {
        #expect(SignInFailure.sentence("GitHub rejected the token") == "GitHub rejected your token.")
        #expect(SignInFailure.sentence("The Internet connection appears to be offline.") == "Couldn't reach GitHub.")
        #expect(SignInFailure.sentence("GitHub error 500") == "Couldn't sign in to GitHub.")
        #expect(SignInFailure.sentence("The operation couldn't be completed. (NSURLErrorDomain error -1005.)") == "Couldn't sign in to GitHub.")
    }
}
