import Testing
@testable import Lookout

@MainActor
@Suite struct Reorder {
    private func store(_ names: [String]) -> Store {
        let s = Store()
        s.persists = false
        s.repos = names.map { RepoConfig(fullName: $0) }
        return s
    }

    @Test func dragDownLandsAfterTarget() {
        let s = store(["a/1", "a/2", "a/3", "a/4"])
        s.moveRepo("a/1", onto: "a/3")
        #expect(s.repos.map(\.fullName) == ["a/2", "a/3", "a/1", "a/4"])
    }

    @Test func dragUpLandsBeforeTarget() {
        let s = store(["a/1", "a/2", "a/3", "a/4"])
        s.moveRepo("a/4", onto: "a/2")
        #expect(s.repos.map(\.fullName) == ["a/1", "a/4", "a/2", "a/3"])
    }

    @Test func unknownOrSelfIsNoop() {
        let s = store(["a/1", "a/2"])
        s.moveRepo("a/1", onto: "a/1")
        s.moveRepo("x/y", onto: "a/2")
        #expect(s.repos.map(\.fullName) == ["a/1", "a/2"])
    }
}
