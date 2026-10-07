import Foundation
import Testing
@testable import Lookout

@Suite struct AddingARepository {
    @Test func theFieldIsEmptiedOnlyIfItStillReadsAsItDidWhenTheAddBegan() {
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/one") == "")
        // The next repository, typed while the add ran, is not erased with the first.
        #expect(ReposView.field(afterAdding: "owner/one", typed: "owner/two") == "owner/two")
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
