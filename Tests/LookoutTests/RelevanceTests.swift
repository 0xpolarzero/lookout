import Foundation
import Testing
@testable import Lookout

private let me = "0xpolarzero"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func comment(_ kind: EventKind, at offset: TimeInterval, root: Int? = nil) -> InboxItem {
    InboxItem(id: UUID().uuidString, repo: "o/r", kind: kind, number: 1, title: "t", snippet: "", author: "someone",
              avatar: nil, authorIsApp: false, url: URL(string: "https://github.com/o/r/issues/1")!,
              createdAt: t0.addingTimeInterval(offset), state: .unread, threadRoot: root)
}

@Suite struct Relevance {
    @Test func commentOnMyThreadCounts() {
        let thread = Store.ThreadInfo(title: "t", author: me)
        #expect(Store.isRelevant(comment(.issueComment, at: 0), thread: thread, mentioned: false, me: me))
        #expect(Store.isRelevant(comment(.reviewComment, at: 0, root: 9), thread: thread, mentioned: false, me: me))
    }

    @Test func strangersThreadIsDropped() {
        let thread = Store.ThreadInfo(title: "t", author: "other")
        #expect(!Store.isRelevant(comment(.issueComment, at: 0), thread: thread, mentioned: false, me: me))
        #expect(!Store.isRelevant(comment(.prComment, at: 0), thread: nil, mentioned: false, me: me))
    }

    @Test func replyAfterIJoinedCounts() {
        let thread = Store.ThreadInfo(title: "t", author: "other", activity: [t0])
        #expect(Store.isRelevant(comment(.issueComment, at: 60), thread: thread, mentioned: false, me: me))
        // Earlier comments in that thread weren't answers to me.
        #expect(!Store.isRelevant(comment(.issueComment, at: -60), thread: thread, mentioned: false, me: me))
    }

    @Test func reviewRepliesOnlyCountInMyReviewThread() {
        let thread = Store.ThreadInfo(title: "t", author: "other", activity: [t0], reviewActivity: [9: [t0], 10: []])
        #expect(Store.isRelevant(comment(.reviewComment, at: 60, root: 9), thread: thread, mentioned: false, me: me))
        #expect(!Store.isRelevant(comment(.reviewComment, at: 60, root: 10), thread: thread, mentioned: false, me: me))
        #expect(!Store.isRelevant(comment(.reviewComment, at: -60, root: 9), thread: thread, mentioned: false, me: me))
    }

    @Test func mentionAlwaysCounts() {
        let thread = Store.ThreadInfo(title: "t", author: "other")
        #expect(Store.isRelevant(comment(.prComment, at: 0), thread: thread, mentioned: true, me: me))
    }

    @Test func nonCommentEventsPassThrough() {
        #expect(Store.isRelevant(comment(.issueOpened, at: 0), thread: nil, mentioned: false, me: me))
    }

    @Test func mentionDetection() {
        #expect(Store.mentions("cc @0xPolarzero can you look?", me))
        #expect(Store.mentions("@0xpolarzero: done", me))
        #expect(!Store.mentions("cc @0xpolarzero-bot", me))
        #expect(!Store.mentions("mail me at x@0xpolarzero.dev", me))
        #expect(!Store.mentions("see github.com/@0xpolarzero2", me))
        #expect(!Store.mentions(nil, me))
    }
}
