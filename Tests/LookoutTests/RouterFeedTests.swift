import Foundation
import Testing
@testable import Lookout

/// The rules that make and address the Router's cards (see `RouterFeed`).
@Suite struct RouterFeedRules {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func session(_ id: String = "local_a", turns: Int = 1, message: Double = -10, focused: Double? = -20,
                         summary: String? = "Did the thing", blocked: Bool = false, running: Bool = false,
                         folder: String? = "/code/app", archived: Bool = false, title: String? = nil) -> ClaudeSession {
        ClaudeSession(id: id, title: title ?? "Session \(id)", folder: folder, isArchived: archived, completedTurns: turns,
                      lastActivity: at(message), lastFocused: focused.map(at), lastUserMessage: at(message),
                      // The app writes a turn's summary once it's over: a running session has none.
                      summary: (running ? nil : summary).map { .init(blocked: blocked, detail: $0) }, running: running, cliID: "cli-\(id)")
    }

    private func question(_ since: Double, _ text: String = "Which one?", call: String? = nil) -> ClaudeActivity {
        ClaudeActivity(text: text, since: at(since), waitsForYou: true, tool: "AskUserQuestion", toolUseID: call ?? "toolu_\(since)")
    }

    /// A state that has seen `sessions` once (the first sight records only).
    private func seen(_ sessions: [ClaudeSession], activity: [String: ClaudeActivity] = [:]) -> RouterState {
        var state = RouterState()
        state.enabled = true
        RouterFeed.update(&state, sessions: sessions, activity: activity, muted: [], viewing: nil, now: at(0))
        return state
    }

    private func update(_ state: inout RouterState, _ sessions: [ClaudeSession], activity: [String: ClaudeActivity] = [:],
                        muted: Set<String> = [], viewing: String? = nil, forms: [String: Set<String>]? = nil,
                        tasks: [String: [ClaudeTask]] = [:], inventory: Set<String>? = nil, now: Double) {
        RouterFeed.update(&state, sessions: sessions, activity: activity, muted: muted, viewing: viewing, forms: forms, tasks: tasks,
                          inventory: inventory, now: at(now))
    }

    @Test func theFirstSightOfASessionOnlyRecordsIt() {
        let state = seen([session(turns: 5), session("local_b", running: true)], activity: ["local_b": question(-1)])
        #expect(state.cards.isEmpty)
        #expect(state.seen.count == 2)
        #expect(state.waits["local_b"] == RouterFeed.Stamp.ms(at(-1)))
    }

    @Test func aFinishedTurnMakesADoneCardWithTheAppsSummary() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: "Fixed the **bug**")], now: 1)
        let card = try! #require(state.cards.first)
        #expect(state.cards.count == 1)
        #expect(card.id == "local_a#t2" && card.kind == .done && card.text == "Fixed the **bug**")
        #expect(card.title == "Session local_a" && card.folder == "/code/app" && card.isOpen && card.createdAt == at(1))
        // The same read again makes nothing new.
        update(&state, [session(turns: 2, summary: "Fixed the **bug**")], now: 2)
        #expect(state.cards.count == 1)
    }

    @Test func aBlockedSummaryMakesAStuckCard() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: "Needs a token", blocked: true)], now: 1)
        #expect(state.cards.map(\.kind) == [.stuck])
    }

    @Test func aTurnIsCardedOnceItsSummaryIsWritten() {
        // The count goes up first, the session still counting as running until the app writes the summary: no card yet.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: true)], now: 1)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2, summary: "Can't reach the server", blocked: true)], now: 2)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
        #expect(state.cards.first?.text == "Can't reach the server" && state.cards.first?.kind == .stuck)
        #expect(state.cards.first?.isOpen == true)
    }

    @Test func theSummaryIsFilledInWhenItComesLater() {
        // A turn over with no summary yet (the app gave up counting it as running): the placeholder, then the summary.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: false)], now: 1)
        #expect(state.cards.first?.text == RouterFeed.placeholder && state.cards.first?.kind == .done)
        update(&state, [session(turns: 2, summary: "Can't reach the server", blocked: true)], now: 2)
        #expect(state.cards.count == 1)
        #expect(state.cards.first?.text == "Can't reach the server" && state.cards.first?.kind == .stuck)
    }

    @Test func aQuestionMakesOneCardUntilItIsAnswered() {
        var state = seen([session(running: true)])
        let ask = question(0.5, "Which database?")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 1)
        let ms = Int64(at(0.5).timeIntervalSince1970 * 1000)
        #expect(state.cards.map(\.id) == ["local_a#w\(ms)"])
        #expect(state.cards.first?.kind == .question && state.cards.first?.text == "Which database?")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 2)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        // Answered (here or in the app): the session moves on.
        update(&state, [session(running: true)], activity: ["local_a": ClaudeActivity(text: "Thinking", since: at(3))], now: 3)
        #expect(state.cards[0].addressedBy == .answered && state.cards[0].addressedAt == at(3))
    }

    @Test func aPlanCardSaysThePlansTitle() {
        var state = seen([session(running: true)])
        let plan = ClaudeActivity(text: "Approve the plan: Move the cache", since: at(1), waitsForYou: true, tool: "ExitPlanMode")
        update(&state, [session(running: true)], activity: ["local_a": plan], now: 1)
        #expect(state.cards.first?.kind == .plan && state.cards.first?.text == "Move the cache")
    }

    @Test func aNewWaitAnswersTheOldOneAndCardsItself() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, "First?")], now: 1)
        update(&state, [session(running: true)], activity: ["local_a": question(2, "Second?")], now: 2)
        #expect(state.cards.map(\.text) == ["First?", "Second?"])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
    }

    @Test func aWaitThatEndsWithTheTurnIsAnswered() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        update(&state, [session(turns: 2)], now: 2)
        #expect(state.cards.map(\.kind) == [.question, .done])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
    }

    @Test func aNewCardSupersedesTheSessionsOpenOnes() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        update(&state, [session(turns: 3), session("local_b", turns: 2)], now: 2)
        let a = state.cards.filter { $0.sessionID == "local_a" }
        #expect(a.map(\.id) == ["local_a#t2", "local_a#t3"])
        #expect(a[0].addressedBy == .superseded && a[1].isOpen)
        #expect(state.cards.first { $0.sessionID == "local_b" }?.isOpen == true)
        #expect(state.cards.filter(\.isOpen).count == 2)
    }

    @Test func replyingInTheSessionAddressesItsCards() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, message: 2, running: true)], now: 2)
        #expect(state.cards[0].addressedBy == .reply)
    }

    @Test func openingTheSessionAddressesATurnButNotAWait() {
        var state = seen([session(turns: 1), session("local_b", running: true)])
        update(&state, [session(turns: 2), session("local_b", running: true)], activity: ["local_b": question(1)], now: 1)
        update(&state, [session(turns: 2, focused: 2), session("local_b", focused: 2, running: true)],
               activity: ["local_b": question(1)], now: 2)
        #expect(state.cards.first { $0.sessionID == "local_a" }?.addressedBy == .opened)
        #expect(state.cards.first { $0.sessionID == "local_b" }?.isOpen == true)
    }

    @Test func anArchivedOrDeletedSessionsCardsAreGone() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        update(&state, [session(turns: 2, archived: true)], now: 2)
        #expect(state.cards.allSatisfy { $0.addressedBy == .gone })
        #expect(state.seen.isEmpty && state.waits.isEmpty)
    }

    @Test func noCardForATurnYouWatchedInTheApp() {
        var state = seen([session(turns: 1, running: true)])
        update(&state, [session(turns: 1, running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        update(&state, [session(turns: 2)], viewing: "local_a", now: 2)
        #expect(state.cards.isEmpty)
        // Looking away later doesn't bring them back.
        update(&state, [session(turns: 2)], now: 3)
        #expect(state.cards.isEmpty)
    }

    @Test func aWaitSeenWhileWatchingIsNotCardedOnceYouLookAway() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], viewing: "local_a", now: 1)
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 2)
        #expect(state.cards.isEmpty)
    }

    @Test func mutedProjectsMakeNoCards() {
        var state = seen([session(turns: 1), session("local_b", turns: 1, folder: nil)])
        update(&state, [session(turns: 2), session("local_b", turns: 2, folder: nil)], muted: ["/code/app", ""], now: 1)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2), session("local_b", turns: 2, folder: nil)], now: 2)
        #expect(state.cards.isEmpty)
    }

    @Test func aCardReopenedByHandStaysOpen() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, focused: 2)], now: 2)
        #expect(state.cards[0].addressedBy == .opened)
        state.cards[0].addressedAt = nil
        state.cards[0].addressedBy = nil
        update(&state, [session(turns: 2, focused: 2)], now: 3)
        #expect(state.cards[0].isOpen)
    }

    @Test func aCardAlreadyMadeIsNotMadeTwice() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        // The session's state goes back (a stale read), then forward again.
        update(&state, [session(turns: 1)], now: 2)
        update(&state, [session(turns: 2)], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"])
    }

    @Test func openCardsFollowARenamedSession() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2, title: "Renamed")], now: 2)
        #expect(state.cards[0].title == "Renamed")
    }

    @Test func addressingBySessionOnlyTouchesItsOpenCards() {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        update(&state, [session(turns: 2), session("local_b", turns: 2)], now: 1)
        RouterFeed.address(&state, "local_a", .router, at(2))
        #expect(state.cards.first { $0.sessionID == "local_a" }?.addressedBy == .router)
        #expect(state.cards.first { $0.sessionID == "local_b" }?.isOpen == true)
    }

    @Test func pruningDropsTheOldestAddressedCardsFirst() {
        var state = RouterState()
        for i in 0..<310 {
            var card = RouterCard(id: "c\(i)", sessionID: "s\(i)", kind: .done, title: "", folder: nil, text: "",
                                  createdAt: at(Double(i)))
            if i % 2 == 0 { card.addressedAt = at(Double(i)); card.addressedBy = .you }
            state.cards.append(card)
        }
        RouterFeed.prune(&state)
        #expect(state.cards.count == RouterFeed.maxCards)
        #expect(state.cards.filter(\.isOpen).count == 155)
        #expect(!state.cards.contains { $0.id == "c18" } && state.cards.contains { $0.id == "c20" })

        // All open: the oldest open ones go.
        state.cards = (0..<305).map { RouterCard(id: "o\($0)", sessionID: "s", kind: .done, title: "", folder: nil, text: "",
                                                  createdAt: at(Double($0))) }
        RouterFeed.prune(&state)
        #expect(state.cards.count == RouterFeed.maxCards && state.cards.first?.id == "o5")
    }

    @Test func theChatKeepsItsLatestLines() {
        var state = RouterState()
        state.chat = (0..<510).map { RouterMessage(role: .you, text: "\($0)", date: at(Double($0))) }
        RouterFeed.prune(&state)
        #expect(state.chat.count == RouterFeed.maxChat && state.chat.first?.text == "10")
    }

    @Test func aSavedWaitIsTheSameWaitAfterARelaunch() throws {
        var state = seen([session(running: true)])
        let ask = ClaudeActivity(text: "Q?", since: at(1).addingTimeInterval(0.734), waitsForYou: true, tool: "AskUserQuestion")
        update(&state, [session(running: true)], activity: ["local_a": ask], now: 1)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: enc.encode(state))
        update(&loaded, [session(running: true)], activity: ["local_a": ask], now: 2)
        #expect(loaded.cards.count == 1 && loaded.cards[0].isOpen)
    }

    @Test func theStateDecodesLeniently() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let empty = try dec.decode(RouterState.self, from: Data("{}".utf8))
        #expect(!empty.enabled && empty.cards.isEmpty && empty.chat.isEmpty)
        let odd = try dec.decode(RouterState.self, from: Data(#"{"enabled":true,"cards":[{"kind":"nope"}],"seen":3}"#.utf8))
        #expect(odd.enabled && odd.cards.isEmpty && odd.seen.isEmpty)
    }

    @Test func waitsAFractionOfASecondApartAreTwoWaits() {
        var state = seen([session(running: true)])
        let first = ClaudeActivity(text: "First?", since: at(1), waitsForYou: true, tool: "AskUserQuestion")
        let second = ClaudeActivity(text: "Second?", since: at(1).addingTimeInterval(0.7), waitsForYou: true, tool: "AskUserQuestion")
        update(&state, [session(running: true)], activity: ["local_a": first], now: 1)
        update(&state, [session(running: true)], activity: ["local_a": second], now: 2)
        #expect(state.cards.map(\.text) == ["First?", "Second?"])
        #expect(state.cards[0].addressedBy == .answered && state.cards[1].isOpen)
        #expect(state.cards[1].waitMs == RouterFeed.Stamp.ms(at(1)) + 700)
        // The same wait read again is the same card.
        update(&state, [session(running: true)], activity: ["local_a": second], now: 3)
        #expect(state.cards.count == 2 && state.cards[1].isOpen)
    }

    @Test func aWaitEndsOnlyOnEvidence() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, call: "toolu_q")], forms: [:], now: 1)
        // Past the two-hour mark, after a relaunch, with nothing read yet: none of it says the question was answered.
        update(&state, [session(summary: nil, running: false)], now: 130)
        update(&state, [session(summary: nil, running: false)], forms: nil, now: 131)
        update(&state, [session(running: true)], now: 132)
        #expect(state.cards.count == 1 && state.cards[0].isOpen && state.waits["local_a"] == RouterFeed.Stamp.ms(at(1)))
        #expect(state.cards[0].toolUseID == "toolu_q")
        // The transcript of the running session moved past the call: answered.
        update(&state, [session(running: true)], activity: ["local_a": ClaudeActivity(text: "Thinking", since: at(133))], now: 133)
        #expect(state.cards[0].addressedBy == .answered && state.waits["local_a"] == nil)
    }

    @Test func aPlanPastTheRunningTimeoutStaysOpen() {
        var state = seen([session(running: true)])
        let plan = ClaudeActivity(text: "Approve the plan: Move", since: at(1), waitsForYou: true, tool: "ExitPlanMode", toolUseID: "toolu_p")
        update(&state, [session(running: true)], activity: ["local_a": plan], now: 1)
        update(&state, [session(summary: nil, running: false)], now: 121)
        update(&state, [session(summary: nil, running: false)], now: 600)
        #expect(state.cards[0].kind == .plan && state.cards[0].isOpen)
        // The turn finishing (its summary is written) ends it.
        update(&state, [session(turns: 2, running: false)], now: 601)
        #expect(state.cards[0].addressedBy == .answered)
    }

    @Test func aHeldFormGoingAwayEndsItsQuestion() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1, call: "toolu_q")], forms: ["local_a": ["toolu_q"]], now: 1)
        #expect(state.formSeen["local_a"] == RouterFeed.Stamp.ms(at(1)))
        // Forms not read yet (a relaunch): nothing is known to be gone.
        update(&state, [session(summary: nil, running: false)], forms: nil, now: 130)
        #expect(state.cards[0].isOpen)
        // Another call's form doesn't keep it; its own going away ends it.
        update(&state, [session(summary: nil, running: false)], forms: ["local_a": ["toolu_other"]], now: 131)
        #expect(state.cards[0].addressedBy == .answered)

        // A message from you ends a wait too.
        var other = seen([session(running: true)])
        update(&other, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        update(&other, [session(message: 140, summary: nil, running: false)], now: 141)
        #expect(other.cards[0].addressedBy == .reply && other.waits["local_a"] == nil)
    }

    @Test func turningItOnAgainSettlesTheCardsLeftOpen() {
        var state = seen([session(turns: 1), session("local_b", turns: 1), session("local_c", turns: 1),
                          session("local_d", running: true), session("local_e", running: true), session("local_f", running: true)])
        update(&state, [session(turns: 2), session("local_b", turns: 2), session("local_c", turns: 2),
                        session("local_d", running: true), session("local_e", running: true), session("local_f", running: true)],
               activity: ["local_d": question(1), "local_e": question(1), "local_f": question(1, call: "toolu_f")],
               forms: ["local_f": ["toolu_f"]], now: 1)
        #expect(state.cards.filter(\.isOpen).count == 6)
        // While it was off: you replied in a, opened b, c was archived, d's question was answered; e still waits; f went
        // idle (two hours on) but its form is still held.
        let now = [session(turns: 2, message: 5, running: true), session("local_b", turns: 2, focused: 5),
                   session("local_d", running: true), session("local_e", running: true), session("local_f", summary: nil, running: false)]
        let activity = ["local_d": ClaudeActivity(text: "Thinking", since: at(5)), "local_e": question(1)]
        RouterFeed.reconcile(&state, sessions: now, activity: activity, forms: ["local_f": ["toolu_f"]], now: at(200))
        let by = Dictionary(uniqueKeysWithValues: state.cards.map { ($0.sessionID, $0.addressedBy) })
        #expect(by["local_a"] == .reply && by["local_b"] == .opened && by["local_c"] == .gone && by["local_d"] == .answered)
        #expect(by["local_e"] == RouterCard.Addressed?.none && by["local_f"] == RouterCard.Addressed?.none)
        #expect(state.waits["local_e"] != nil && state.waits["local_f"] != nil && state.waits["local_d"] == nil)
        #expect(state.seen.isEmpty)
        // The next update sees every session afresh and keeps the surviving waits.
        update(&state, now, activity: activity, forms: ["local_f": ["toolu_f"]], now: 201)
        #expect(state.cards.filter(\.isOpen).map(\.sessionID).sorted() == ["local_e", "local_f"])
        #expect(state.waits["local_f"] == RouterFeed.Stamp.ms(at(1)))
    }

    @Test func reopeningACardSupersedesTheSessionsNewerOne() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 3)], now: 2)
        RouterFeed.reopen(&state, "local_a#t2", now: at(3))
        #expect(state.cards.map(\.isOpen) == [true, false])
        #expect(state.cards[1].addressedBy == .superseded)
    }

    @Test func aReplyInTheSameSecondAsTheCardIsToldApartAfterARelaunch() throws {
        var state = seen([session(turns: 1), session("local_b", turns: 1)])
        let made = at(1).addingTimeInterval(0.2)
        RouterFeed.update(&state, sessions: [session(turns: 2), session("local_b", turns: 2)], activity: [:], muted: [], viewing: nil,
                          now: made)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        state = try dec.decode(RouterState.self, from: enc.encode(state))
        #expect(state.cards[0].createdMs == RouterFeed.Stamp.ms(made))
        // 0.5 s later, in the same second: a reply in a, an open of b.
        var a = session(turns: 2)
        a.lastUserMessage = made.addingTimeInterval(0.5)
        var b = session("local_b", turns: 2)
        b.lastFocused = made.addingTimeInterval(0.5)
        RouterFeed.update(&state, sessions: [a, b], activity: [:], muted: [], viewing: nil, now: made.addingTimeInterval(0.6))
        #expect(state.cards.map(\.addressedBy) == [.reply, .opened])

        // A message just before a card (one with nothing else to go by), in the same second, is not a reply to it.
        let question = RouterCard(id: "local_a#w1", sessionID: "local_a", kind: .question, title: "", folder: nil, text: "",
                                  createdAt: made)
        #expect(!(RouterFeed.Stamp.ms(made.addingTimeInterval(-0.1)) > question.replyAfter))
        #expect(RouterFeed.Stamp.ms(made.addingTimeInterval(0.5)) > question.replyAfter)
    }

    @Test func oldStateFilesWithDatesStillDecode() throws {
        let json = #"{"cards":[{"id":"s#t1","sessionID":"s","kind":"done","title":"T","text":"x","createdAt":"2033-05-18T03:33:20Z"}]}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let state = try dec.decode(RouterState.self, from: Data(json.utf8))
        #expect(state.cards.first?.createdAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    /// Off, the plan (or question) is approved and the turn finishes; back on, the session says one more turn, not running,
    /// and no summary yet. The saved stamps show the turn moved: the wait is over.
    @Test(arguments: ["ExitPlanMode", "AskUserQuestion"]) func aTurnThatFinishedWhileOffEndsItsWait(tool: String) {
        var state = seen([session(turns: 3, running: true)])
        let wait = ClaudeActivity(text: "Approve the plan: Move", since: at(1), waitsForYou: true, tool: tool, toolUseID: "toolu_w")
        update(&state, [session(turns: 3, running: true)], activity: ["local_a": wait], now: 1)
        #expect(state.cards.count == 1 && state.cards[0].isOpen)
        let after = session(turns: 4, summary: nil, running: false)
        RouterFeed.reconcile(&state, sessions: [after], activity: [:], now: at(30))
        #expect(state.cards[0].addressedBy == .answered)
        #expect(state.waits["local_a"] == nil && state.waitTools["local_a"] == nil && state.formSeen["local_a"] == nil)
        update(&state, [after], now: 31)
        #expect(state.cards.filter(\.isOpen).isEmpty)
    }

    @Test func aMessageSentWhileOffEndsTheWait() {
        var state = seen([session(running: true)])
        update(&state, [session(running: true)], activity: ["local_a": question(1)], now: 1)
        // The message is older than the card's second would suggest only through the stamp: it moved since the last look.
        var after = session(summary: nil, running: false)
        after.lastUserMessage = at(0.5)
        RouterFeed.reconcile(&state, sessions: [after], activity: [:], now: at(30))
        #expect(state.cards[0].addressedBy == .reply && state.waits["local_a"] == nil)
    }

    @Test func datesAtTheEndsOfTimeAreClampedNotATrap() throws {
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: 1e300)) == Int64(9e18))
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: -1e300)) == Int64(-9e18))
        #expect(RouterFeed.Stamp.ms(Date(timeIntervalSince1970: .nan)) == 0)
        // A session whose file says absurd times, and saved cards at either end of Int64, go through the feed.
        var state = seen([session(turns: 1)])
        var odd = session(turns: 2)
        odd.lastUserMessage = Date(timeIntervalSince1970: 1e300)
        odd.lastFocused = Date(timeIntervalSince1970: -1e300)
        let json = #"{"cards":[{"id":"x#t1","sessionID":"local_a","kind":"done","title":"","text":"","createdMs":-9223372036854775808},{"id":"y#w9223372036854775807","sessionID":"local_a","kind":"question","title":"","text":"","createdMs":9223372036854775807}],"seen":{},"waits":{"local_a":9223372036854775807}}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: Data(json.utf8))
        RouterFeed.update(&state, sessions: [odd], activity: [:], muted: [], viewing: nil, now: at(1))
        RouterFeed.update(&loaded, sessions: [odd], activity: [:], muted: [], viewing: nil, now: at(1))
        RouterFeed.reconcile(&loaded, sessions: [odd], activity: [:], now: at(2))
        _ = loaded.cards.map(\.createdAt)
        #expect(loaded.cards.count == 2)
    }

    // MARK: Turns that leave work running

    private var subagent: [String: [ClaudeTask]] {
        ["local_a": [ClaudeTask(id: "t1", kind: .agent, title: "Explore", since: at(0))]]
    }

    @Test func aTurnThatLeftWorkRunningIsCardedWhenTheWorkIsDone() {
        var state = seen([session(turns: 1)])
        // The turn is over, a subagent still runs: still working, no card.
        update(&state, [session(turns: 2, summary: nil)], tasks: subagent, now: 1)
        update(&state, [session(turns: 2, summary: "First summary")], tasks: subagent, now: 2)
        #expect(state.cards.isEmpty && state.pendingTurns["local_a"]?.turns == 2)
        // It's done: the card, with the summary as it is then.
        update(&state, [session(turns: 2, summary: "Merged the fix", blocked: true)], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].kind == .stuck && state.cards[0].text == "Merged the fix")
        #expect(state.cards[0].createdAt == at(3) && state.pendingTurns.isEmpty)
        // Once: not again on the next read.
        update(&state, [session(turns: 2, summary: "Merged the fix", blocked: true)], now: 4)
        #expect(state.cards.count == 1)
    }

    @Test func aReplyWhileTheWorkRunsMeansNoCard() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        // You wrote to it meanwhile (a new turn under way, then over before the subagent is done).
        update(&state, [session(turns: 2, message: 2, running: true)], now: 2)
        update(&state, [session(turns: 2, message: 2)], tasks: subagent, now: 3)
        update(&state, [session(turns: 2, message: 2)], now: 4)
        #expect(state.cards.isEmpty && state.pendingTurns.isEmpty)
    }

    @Test func aNewerTurnMeanwhileGivesOneCardForTheLatest() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        // Another turn ended (still with work running), then everything is done.
        update(&state, [session(turns: 3, message: 2)], tasks: subagent, now: 3)
        update(&state, [session(turns: 3, message: 2, summary: "All done")], now: 4)
        #expect(state.cards.map(\.id) == ["local_a#t3"] && state.cards[0].text == "All done")
    }

    @Test func aCardAlreadyMadeIsLeftAloneByWorkStartedLater() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], now: 1)
        update(&state, [session(turns: 2)], tasks: subagent, now: 2)
        #expect(state.cards.count == 1 && state.cards[0].isOpen && state.pendingTurns.isEmpty)
    }

    @Test func aPendingTurnSurvivesARelaunchAndTurningTheRouterOnAgain() throws {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, now: 1)
        let enc = JSONEncoder(), dec = JSONDecoder()
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
        var loaded = try dec.decode(RouterState.self, from: enc.encode(state))
        #expect(loaded.pendingTurns["local_a"]?.turns == 2)
        // Switched off and on: the open cards are settled and every session seen afresh; the pending turn still waits.
        RouterFeed.reconcile(&loaded, sessions: [session(turns: 2)], activity: [:], now: at(2))
        update(&loaded, [session(turns: 2)], tasks: subagent, now: 3)
        #expect(loaded.cards.isEmpty)
        update(&loaded, [session(turns: 2)], now: 4)
        #expect(loaded.cards.map(\.id) == ["local_a#t2"])
    }

    // MARK: Knowing whether a turn left work running

    @Test func aLateSummaryThenLiveTasksThenNoneGivesOneCardAfterTheTasks() {
        var state = seen([session(turns: 1)])
        // The count goes up while the session still counts as running: what it leaves running isn't known yet.
        update(&state, [session(turns: 2, summary: nil, running: true)], tasks: [:], inventory: [], now: 1)
        #expect(state.cards.isEmpty)
        // The summary is written; the read that sees it hasn't looked at its tasks yet.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: [], now: 2)
        #expect(state.cards.isEmpty)
        // It has: a subagent still runs.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: subagent, inventory: ["local_a"], now: 3)
        #expect(state.cards.isEmpty)
        // Done: one card.
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: ["local_a"], now: 4)
        update(&state, [session(turns: 2, summary: "Done it")], tasks: [:], inventory: ["local_a"], now: 5)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].createdAt == at(4))
    }

    @Test func aLateSummaryAndNoTasksGivesTheCardOnceTheReadSaysNone() {
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2, summary: nil, running: true)], inventory: [], now: 1)
        update(&state, [session(turns: 2, summary: "Done it")], inventory: [], now: 2)
        #expect(state.cards.isEmpty)
        update(&state, [session(turns: 2, summary: "Done it")], inventory: ["local_a"], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].createdAt == at(3))
    }

    @Test func aReplyTheStoreHadntReadWhenTheTasksEndedStillAddressesTheCard() {
        // The turn ends with a command running. You reply; before the store reads the sessions again, a read of the tasks
        // alone says the command is over, with the sessions as last read (no reply yet): the card is made then.
        var state = seen([session(turns: 1)])
        update(&state, [session(turns: 2)], tasks: subagent, inventory: ["local_a"], now: 1)
        update(&state, [session(turns: 2)], tasks: [:], inventory: ["local_a"], now: 3)
        #expect(state.cards.map(\.id) == ["local_a#t2"] && state.cards[0].isOpen)
        // The next full read has your reply, sent before the card was made: it is a reply to that turn all the same.
        update(&state, [session(turns: 2, message: 2.5, running: true)], now: 4)
        #expect(state.cards[0].addressedBy == .reply)
    }
}
