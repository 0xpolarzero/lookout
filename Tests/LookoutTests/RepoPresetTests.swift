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

    /// A repository's flags as the presets define them: every kind but CI, and All comments.
    private func repo(_ kinds: Set<EventKind>, all: Bool = false) -> RepoConfig {
        RepoConfig(fullName: "a/one", events: kinds.union([.ciMain]), allComments: all)
    }

    @Test func onlyWhatsForMeIsRelevantCommentsAlone() {
        #expect(RepoPreset(repo(RepoPreset.comments)) == .forMe)
        #expect(RepoPreset.forMe.events == RepoPreset.comments)
        #expect(RepoPreset.forMe.allComments == false)
        #expect(RepoPreset.opened.isDisjoint(with: RepoPreset.forMe.events ?? []))
    }

    @Test func theLegacyDefaultIsCustomNotOnlyWhatsForMe() {
        // New issues and PRs on, All comments off: how every repository was started before presets.
        let legacy = RepoConfig(fullName: "a/one")
        #expect(legacy.events.isSuperset(of: RepoPreset.kinds) && !legacy.allComments)
        #expect(RepoPreset(legacy) == .custom)
        #expect(RepoPreset(repo(RepoPreset.kinds, all: true)) == .everything)
    }

    @Test func everyCombinationOfFlagsNamesOnePreset() {
        let kinds = Array(RepoPreset.kinds)
        for mask in 0..<(1 << kinds.count) {
            for all in [false, true] {
                var chosen: Set<EventKind> = []
                for (i, kind) in kinds.enumerated() where mask & (1 << i) != 0 { chosen.insert(kind) }
                let expected: RepoPreset = chosen == RepoPreset.kinds && all ? .everything
                    : chosen == RepoPreset.comments && !all ? .forMe : .custom
                #expect(RepoPreset(repo(chosen, all: all)) == expected)
            }
        }
    }

    @Test func ciDoesNotDecideThePreset() {
        for ci in [true, false] {
            var repo = repo(RepoPreset.kinds, all: true)
            if !ci { repo.events.remove(.ciMain) }
            #expect(RepoPreset(repo) == .everything)
        }
    }

    @Test func choosingAPresetNamesItAndLeavesCIAlone() {
        let s = store(RepoConfig(fullName: "a/one", events: [.prComment, .reviewComment]))
        s.setPreset(.everything, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .everything)
        #expect(!s.repos[0].events.contains(.ciMain))
        s.setPreset(.forMe, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .forMe)
        #expect(s.repos[0].events == RepoPreset.comments)
        s.setPreset(.everything, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .everything)
    }

    @Test func onlyWhatsForMeTurnsBothOpenedFlagsOff() {
        let s = store(RepoConfig(fullName: "a/one", allComments: true))
        s.setPreset(.forMe, on: s.repos[0])
        #expect(!s.repos[0].events.contains(.issueOpened))
        #expect(!s.repos[0].events.contains(.prOpened))
        #expect(RepoPreset.comments.isSubset(of: s.repos[0].events))
        #expect(!s.repos[0].allComments)
        // CI keeps whatever the row's own switch says.
        #expect(s.repos[0].events.contains(.ciMain))
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
        s.changePreset(.custom, on: s.repos[0])
        #expect(s.repos[0] == repo)
        #expect(RepoPreset(s.repos[0]) == .custom)
        #expect(s.undoStack.entries.isEmpty)
    }

    @Test func summariesSayWhatIsOnInPlainWords() {
        #expect(RepoPreset.summary(RepoConfig(fullName: "a/one")) == "New issues, new PRs and comments for you")
        #expect(RepoPreset.summary(repo([.prOpened, .reviewComment])) == "New PRs and review comments for you")
        #expect(RepoPreset.summary(repo([.prComment, .reviewComment], all: true)) == "All PR and review comments")
        #expect(RepoPreset.summary(repo([.issueComment, .prComment, .reviewComment], all: true)) == "All comments")
        #expect(RepoPreset.summary(repo([.issueOpened])) == "New issues")
        #expect(RepoPreset.summary(repo([])) == "Nothing")
    }

    @Test func onlyWhatsForMePrunesWhatWasNotAndOnlyUndoBringsItBack() {
        let s = store(RepoConfig(fullName: "a/one", allComments: true))
        s.undoStack.announce = { _ in }
        s.items = [comment("mine", forYou: true), comment("other", forYou: false), comment("unknown", forYou: nil)]
        s.setPreset(.forMe, on: s.repos[0])
        #expect(Set(s.items.map(\.id)) == ["mine", "unknown"])
        // Choosing the other preset turns the flags back on but cannot bring back what was removed.
        s.setPreset(.everything, on: s.repos[0])
        #expect(RepoPreset(s.repos[0]) == .everything)
        #expect(Set(s.items.map(\.id)) == ["mine", "unknown"])
    }

    @Test func aPresetChangeCanBeUndoneWithItsItems() {
        var repo = RepoConfig(fullName: "a/one", allComments: true)
        repo.events.insert(.ciMain)
        let s = store(repo)
        s.undoStack.announce = { _ in }
        s.items = [comment("mine", forYou: true), comment("other", forYou: false)]
        s.changePreset(.forMe, on: s.repos[0])
        #expect(s.undoStack.visible(in: .controls)?.message == "one: Only what's for me, 1 item removed")
        #expect(Set(s.items.map(\.id)) == ["mine"])
        #expect(s.undoLast())
        #expect(s.repos[0] == repo)
        #expect(RepoPreset(s.repos[0]) == .everything)
        #expect(Set(s.items.map(\.id)) == ["mine", "other"])
    }

    @Test func undoingAPresetLeavesLaterCIChangesAlone() {
        var repo = RepoConfig(fullName: "a/one", allComments: true)
        repo.events.insert(.ciMain)
        let s = store(repo)
        s.undoStack.announce = { _ in }
        s.changePreset(.forMe, on: s.repos[0])
        // CI has its own switch: turning it off afterwards is not part of what the undo takes back.
        s.toggle(.ciMain, on: s.repos[0])
        #expect(!s.repos[0].events.contains(.ciMain))
        #expect(s.undoLast())
        #expect(RepoPreset(s.repos[0]) == .everything)
        #expect(!s.repos[0].events.contains(.ciMain))
    }

    @Test func undoingAPresetLeavesALaterCustomChoiceAlone() {
        let s = store(RepoConfig(fullName: "a/one", allComments: true))
        s.undoStack.announce = { _ in }
        s.changePreset(.forMe, on: s.repos[0])
        // Issue comments were on under both presets; the preset did not touch them, so the undo must not either.
        s.toggle(.issueComment, on: s.repos[0])
        #expect(!s.repos[0].events.contains(.issueComment))
        #expect(s.undoLast())
        #expect(s.repos[0].events.isSuperset(of: [.issueOpened, .prOpened, .prComment, .reviewComment]))
        #expect(!s.repos[0].events.contains(.issueComment))
        #expect(s.repos[0].allComments)
    }

    @Test func undoingAPresetPutsBackTheFlagsItMovedEvenIfChosenAgainSince() {
        let s = store(RepoConfig(fullName: "a/one", allComments: true))
        s.undoStack.announce = { _ in }
        s.changePreset(.forMe, on: s.repos[0])
        s.toggle(.prOpened, on: s.repos[0])
        s.toggleAllComments(s.repos[0])
        #expect(s.repos[0].allComments)
        #expect(s.undoLast())
        #expect(RepoPreset(s.repos[0]) == .everything)
    }

    @Test func choosingThePresetAlreadyOnRegistersNoUndo() {
        let s = store(repo(RepoPreset.comments))
        s.undoStack.announce = { _ in }
        s.changePreset(.forMe, on: s.repos[0])
        #expect(s.undoStack.entries.isEmpty)
    }

    @Test func stoppingAndResumingBringsEverythingBackInPlace() {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two", events: [.prComment]), RepoConfig(fullName: "a/three")]
        s.items = [comment("c1", forYou: true)]
        let status = CIStatus(state: .failure, branch: "main", sha: "abc", failing: ["build"], checkedAt: Date())
        s.ci["a/one"] = status
        s.mutedCI["a/one"] = "abc"
        s.undoStack.announce = { _ in }
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
