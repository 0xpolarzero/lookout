import Testing
@testable import Lookout

@MainActor
@Suite struct Updates {
    @Test func versionsCompareNumerically() throws {
        #expect(try #require(Version("0.10.0")) > #require(Version("0.9.3")))
        #expect(try #require(Version("v1.2")) == #require(Version("1.2.0")))
        #expect(try #require(Version("1.2.1")) > #require(Version("1.2")))
        #expect(try #require(Version("0.2.0")) < #require(Version("0.2.1")))
        #expect(Version("0.0.0-dev") != nil)
        #expect(Version("latest") == nil)
        #expect(Version("") == nil)
    }

    @Test func devBuildsNeverUpdate() {
        // Tests don't run from a release bundle.
        #expect(!Updater().isRelease)
    }

    @Test func aFailedDownloadIsTheErrorTheHubSaysAndAnIdleOneHasNone() {
        let updater = Updater()
        updater.preview(.idle)
        #expect(updater.shownError == nil)
        updater.preview(.failed("The download didn't finish"))
        #expect(updater.shownError == "The download didn't finish")
    }

    @Test func aFailureThatRepeatsIsCountedAgainSoItIsSaidAgain() {
        let updater = Updater()
        updater.preview(.failed("The download didn't finish"))
        let first = updater.failures
        updater.preview(.downloading)
        updater.preview(.failed("The download didn't finish"))
        #expect(updater.failures == first + 1)
    }
}
