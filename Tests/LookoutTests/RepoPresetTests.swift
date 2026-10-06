import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct RepoPresets {
    private func store(_ repo: RepoConfig) -> Store {
        let s = Store()
        s.persists = false
        s.repos = [repo]
        return s
    }

    private func comment(_ id: String, forYou: Bool?) -> InboxItem {
        var item = InboxItem(id: id, repo: "a/one", kind: .issueComment, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                             authorIsApp: false, url: URL(string: "https://github.com/a/one")!, createdAt: Date(), state: .unread)
        item.forYou = forYou
        return item
    }

    @Test func aFreshRepositoryIsOnlyWhatsForMe() {
        #expect(RepoPreset(RepoConfig(fullName: "a/one")) == .forMe)
    }

    @Test func everyCombinationOfFlagsNamesOnePreset() {
        let kinds = Array(RepoPreset.kinds)
        for mask in 0..<(1 << kinds.count) {
            for all in [false, true] {
                var repo = RepoConfig(fullName: "a/one", events: [.ciMain], allComments: all)
                for (i, kind) in kinds.enumerated() where mask & (1 << i) != 0 { repo.events.insert(kind) }
                let full = repo.events.isSuperset(of: RepoPreset.kinds)
                #expect(RepoPreset(repo) == (full ? (all ? .everything : .forMe) : .custom))
            }
        }
    }

    @Test func ciDoesNotDecideThePreset() {
        for ci in [true, false] {
            var repo = RepoConfig(fullName: "a/one", allComments: true)
            if !ci { repo.events.remove(.ciMain) }
            #expect(RepoPreset(repo) == .everything)
        }
    }

    @Test func choosingAPresetNamesItAndLeavesCIAlone() {
        var repo = RepoConfig(fullName: "a/one", events: [.prComment, .reviewComment])
        repo.allComments = false
        let s = store(repo)
        s.setPreset(.everything, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .everything)
        #expect(!s.repos[0].events.contains(.ciMain))
        s.setPreset(.forMe, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .forMe)
        #expect(s.repos[0].events == RepoPreset.kinds)
        s.setPreset(.everything, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .everything)
    }

    @Test func roundTripFromEveryPresetAndBack() {
        for start in [RepoPreset.everything, .forMe] {
            let s = store(RepoConfig(fullName: "a/one", allComments: start == .everything))
            for next in [RepoPreset.forMe, .everything, .forMe] {
                s.setPreset(next, on: s.repos[0])
                #expect(RepoPreset(s.repos[0]) == next)
            }
        }
    }

    @Test func customChangesNothing() {
        let repo = RepoConfig(fullName: "a/one", events: [.issueComment, .ciMain])
        let s = store(repo)
        s.setPreset(.custom, on: s.repos[0])
        #expect(s.repos[0] == repo)
        #expect(RepoPreset(s.repos[0]) == .custom)
    }

    @Test func onlyWhatsForMePrunesWhatWasNot() {
        let s = store(RepoConfig(fullName: "a/one", allComments: true))
        s.items = [comment("mine", forYou: true), comment("other", forYou: false), comment("unknown", forYou: nil)]
        s.setPreset(.forMe, on: s.repos[0])
        #expect(Set(s.items.map(\.id)) == ["mine", "unknown"])
    }

    @Test func stoppingAndResumingBringsEverythingBackInPlace() {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two", events: [.prComment]), RepoConfig(fullName: "a/three")]
        s.items = [comment("c1", forYou: true)]
        let status = CIStatus(state: .failure, branch: "main", sha: "abc", failing: ["build"], checkedAt: Date())
        s.ci["a/one"] = status
        s.mutedCI["a/one"] = "abc"
        let stopped = s.stopWatching(s.repos[0])!
        #expect(s.repos.map(\.fullName) == ["a/two", "a/three"])
        #expect(s.items.isEmpty && s.ci["a/one"] == nil && s.mutedCI["a/one"] == nil)
        s.resumeWatching(stopped)
        #expect(s.repos.map(\.fullName) == ["a/one", "a/two", "a/three"])
        #expect(s.items.map(\.id) == ["c1"])
        #expect(s.ci["a/one"] == status && s.mutedCI["a/one"] == "abc")
    }

    @Test func movingByOneStopsAtTheEnds() {
        let s = Store()
        s.persists = false
        s.repos = ["a", "b", "c"].map { RepoConfig(fullName: "x/\($0)") }
        s.moveRepo("x/a", by: -1)
        #expect(s.repos.map(\.name) == ["a", "b", "c"])
        s.moveRepo("x/a", by: 1)
        #expect(s.repos.map(\.name) == ["b", "a", "c"])
        s.moveRepo("x/c", by: -1)
        #expect(s.repos.map(\.name) == ["b", "c", "a"])
        s.moveRepo("x/a", by: 1)
        #expect(s.repos.map(\.name) == ["b", "c", "a"])
    }
}
