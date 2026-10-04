import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct Prune {
    private func item(_ id: String, _ repo: String, _ kind: EventKind, forYou: Bool? = nil, state: ItemState = .unread) -> InboxItem {
        InboxItem(id: id, repo: repo, kind: kind, number: 1, title: "t", snippet: "", author: "x", avatar: nil,
                  authorIsApp: false, url: URL(string: "https://github.com/\(repo)")!, createdAt: Date(), state: state,
                  forYou: forYou)
    }

    private func store() -> Store {
        let s = Store()
        s.persists = false
        s.repos = [RepoConfig(fullName: "a/one", allComments: true), RepoConfig(fullName: "a/two")]
        s.items = [
            item("1", "a/one", .prComment, forYou: true),
            item("2", "a/one", .prComment, forYou: false, state: .discarded),
            item("3", "a/one", .issueOpened),
            item("4", "a/two", .prComment, forYou: true),
            item("5", "a/one", .issueComment, forYou: false),
            item("6", "x/y", .reviewRequested),
        ]
        return s
    }

    @Test func turningAnEventOffRemovesItsItemsInThatRepoOnly() {
        let s = store()
        s.toggle(.prComment, on: s.repos[0])
        #expect(s.items.map(\.id) == ["3", "4", "5", "6"])
        s.toggle(.prComment, on: s.repos[0])  // back on: nothing to restore, nothing removed
        #expect(s.items.count == 4)
    }

    @Test func allCommentsOffKeepsOnlyCommentsForYou() {
        let s = store()
        s.toggleAllComments(s.repos[0])
        #expect(s.items.map(\.id) == ["1", "3", "4", "6"])
    }

    @Test func reviewRequestsOffRemovesThem() {
        let s = store()
        s.settings.reviewRequests = false
        #expect(!s.items.contains { $0.kind == .reviewRequested })
    }
}
