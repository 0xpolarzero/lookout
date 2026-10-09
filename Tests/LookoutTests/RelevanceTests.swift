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

    @Test func aCutOffThreadCantRuleACommentOut() {
        var thread = Store.ThreadInfo(title: "t", author: "other", activity: [t0])
        thread.activityTruncated = true
        // Seeing my earlier comment is proof; not seeing one proves nothing when the history was cut.
        #expect(Store.relevance(comment(.issueComment, at: 60), thread: thread, mentioned: false, me: me) == true)
        #expect(Store.relevance(comment(.issueComment, at: -60), thread: thread, mentioned: false, me: me) == nil)
        #expect(Store.relevance(comment(.reviewComment, at: 60, root: 9), thread: thread, mentioned: false, me: me) == false)
        thread.reviewThreadsTruncated = true
        #expect(Store.relevance(comment(.reviewComment, at: 60, root: 9), thread: thread, mentioned: false, me: me) == nil)
        #expect(Store.relevance(comment(.issueComment, at: 0), thread: nil, mentioned: false, me: me) == nil)
        #expect(Store.relevance(comment(.issueComment, at: 0), thread: nil, mentioned: true, me: me) == true)
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

    @Test func aCutOffThreadIsSettledByTheThreadsIWasIn() {
        var thread = Store.ThreadInfo(title: "t", author: "other")
        thread.activityTruncated = true
        thread.reviewThreadsTruncated = true
        let issue = comment(.issueComment, at: 0), review = comment(.reviewComment, at: 0, root: 9)
        let never = Store.Joined(numbers: [2], complete: true)
        #expect(Store.relevance(issue, thread: thread, mentioned: false, me: me, joined: never) == false)
        #expect(Store.relevance(review, thread: thread, mentioned: false, me: me, joined: never) == false)
        // Past what the search could answer, a missing thread proves nothing.
        let partial = Store.Joined(numbers: [2], complete: false)
        #expect(Store.relevance(issue, thread: thread, mentioned: false, me: me, joined: partial) == nil)
        let was = Store.Joined(numbers: [1], complete: true)
        #expect(Store.relevance(issue, thread: thread, mentioned: false, me: me, joined: was) == true)
        // Which review thread I was in is still unknown.
        #expect(Store.relevance(review, thread: thread, mentioned: false, me: me, joined: was) == nil)
        // My part seen comes after this comment: whether there's an earlier one is unknown.
        thread.activity = [t0.addingTimeInterval(60)]
        #expect(Store.relevance(issue, thread: thread, mentioned: false, me: me, joined: was) == nil)
    }
}
