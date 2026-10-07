import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite(.serialized) struct AddingARepository {
    @Test func theFieldIsEmptiedOnlyIfItStillReadsAsItDidWhenTheAddBegan() {
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/one") == "")
        // The next repository, typed while the add ran, is not erased with the first.
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/two") == "owner/two")
    }

    @Test func aFailedAddIsSaidAndASuccessfulOneIsNot() async {
        await Announced.exclusively {
            var said: [String] = []
            Announce.sink = { said.append($0) }
            #expect(ReposView.said(nil) == nil && said.isEmpty)
            #expect(ReposView.said("Not found (or no access)") == "Not found (or no access)")
            #expect(said == ["Not found (or no access)"])
        }
    }

    @Test func aRefusedLaunchAtLoginIsSaidWithTheReasonLeftOnScreen() async {
        struct Refused: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        await Announced.exclusively {
            var said: [String] = []
            Announce.sink = { said.append($0) }
            #expect(SettingsView.launchFailure(turningOn: true, using: { _ in }) == nil && said.isEmpty)
            #expect(SettingsView.launchFailure(turningOn: true, using: { _ in throw Refused() }) == "Operation not permitted")
            #expect(said == ["Couldn't turn on Launch at login"])
            // Turning it off is a different sentence: not the same words twice.
            #expect(SettingsView.launchFailure(turningOn: false, using: { _ in throw Refused() }) == "Operation not permitted")
            #expect(said.last == "Couldn't turn off Launch at login")
        }
    }
}

@MainActor
@Suite struct OpeningChecks {
    @Test func theChecksOfTheLatestCommitOpenNotTheCommit() {
        let s = Store()
        s.persists = false
        let repo = RepoConfig(fullName: "a/one")
        // No run known yet: the Actions page.
        #expect(s.checksURL(repo).absoluteString == "https://github.com/a/one/actions")
        s.ci["a/one"] = CIStatus(state: .success, branch: "main", sha: "abc", url: URL(string: "https://github.com/a/one/commit/abc"),
                                 failing: [], checkedAt: Date(), title: nil, updatedAt: nil)
        #expect(s.checksURL(repo).absoluteString == "https://github.com/a/one/commit/abc/checks")
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        s.openChecks(repo)
        #expect(opened == ["Open checks · a/one"])
    }
}
