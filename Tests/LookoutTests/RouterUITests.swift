import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Lookout

/// The Router's UI: the status line, the window's keys and model, the banners and the shortcut.
@MainActor
@Suite struct RouterUITests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func demo(_ scenario: Demo.Scenario = .router) -> Store {
        let store = Store()
        Demo.populate(store, scenario)
        store.interceptOpen = { _ in }
        return store
    }

    private func key(_ code: Int, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    /// The composer's text view holding `text`, the caret at `caret` (the end by default), as the keys see it.
    private func editor(_ model: RouterModel, _ text: String, caret: Int? = nil) -> NSTextView {
        model.draft = text
        let view = NSTextView()
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        model.followCaret(view)
        return view
    }

    private func row(_ id: String, folder: String, running: Bool, waits: Bool = false, since: TimeInterval = 0,
                     activity: String = "Running swift test") -> AgentRow {
        let session = ClaudeSession(id: id, title: id, folder: folder, lastActivity: now, lastUserMessage: now.addingTimeInterval(-since),
                                    running: running)
        return AgentRow(session: session, entry: AgentEntry(id: id), label: "AB", project: folder,
                        activity: running ? ClaudeActivity(text: waits ? "Which one?" : activity, since: now, waitsForYou: waits) : nil)
    }

    // MARK: Status line

    @Test func theStatusLineIsQuietWhenNothingRuns() {
        #expect(RouterStatusLine.text([], now: now) == "All quiet")
        #expect(RouterStatusLine.text([row("a", folder: "app", running: false)], now: now) == "All quiet")
    }

    @Test func theStatusLineSaysWhatWorksForHowLongThenWhatWaits() {
        let rows = [
            row("a", folder: "lookout", running: true, since: 12 * 60 + 30),
            row("b", folder: "api", running: true, waits: true, since: 60),
            row("c", folder: "web", running: true, since: 30, activity: "Thinking"),
        ]
        #expect(RouterStatusLine.text(rows, now: now)
                == "2 working · lookout: Running swift test 12m · web: Thinking <1m · api: waiting on you")
    }

    @Test func durationsAreWholeMinutes() {
        #expect(RouterStatusLine.minutes(59) == "<1m")
        #expect(RouterStatusLine.minutes(61) == "1m")
        #expect(RouterStatusLine.minutes(3600) == "1h")
        #expect(RouterStatusLine.minutes(3600 + 5 * 60) == "1h 5m")
    }

    // MARK: Window keys

    @Test func arrowsWalkTheCardsAndSpaceAddressesThePickedOne() {
        let store = demo()
        let model = RouterModel()
        var closed = false
        let keys = RouterKeys(store: store, model: model) { closed = true }
        let open = store.openRouterCards.map(\.id)
        #expect(keys.key(key(kVK_DownArrow), responder: nil))
        #expect(model.selection == open[0])
        #expect(keys.key(key(kVK_DownArrow), responder: nil))
        #expect(model.selection == open[1])
        #expect(keys.key(key(kVK_Space, " "), responder: nil))
        #expect(store.router.cards.first { $0.id == open[1] }?.addressedBy == .you)
        // Under Open, the addressed card leaves the list: the next one is picked.
        #expect(model.selection == open[2])
        #expect(keys.key(key(kVK_Escape), responder: nil) && closed)
    }

    @Test func returnInTheComposerSendsAndShiftReturnDoesNot() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        let editor = NSTextView()
        model.composerFocused = true
        model.draft = "tell lookout to run the tests"
        let before = store.router.chat.count
        #expect(keys.key(key(kVK_Return, "\r", .shift), responder: editor))
        #expect(store.router.chat.count == before && !model.draft.isEmpty)
        #expect(keys.key(key(kVK_Return, "\r"), responder: editor))
        #expect(model.draft.isEmpty)
        #expect(store.router.chat.dropFirst(before).first?.role == .you)
        // Typing in the composer is its own.
        #expect(!keys.key(key(kVK_ANSI_A, "a"), responder: editor))
    }

    @Test func typingWithNothingFocusedGoesToTheComposer() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        let request = model.focusRequest
        #expect(keys.key(key(kVK_ANSI_H, "h"), responder: nil))
        #expect(model.focusRequest != request && model.pendingKeys.count == 1)
    }

    @Test func nothingIsSentWhileTheRouterIsOff() {
        let store = demo(.routerOff)
        let model = RouterModel()
        model.draft = "hello"
        model.send(store: store)
        #expect(store.router.chat.isEmpty && model.draft == "hello")
    }

    @Test func aCardTheOpenFilterHidesShowsEveryCard() {
        let store = demo()
        let model = RouterModel()
        let addressed = store.router.cards.first { !$0.isOpen }!.id
        model.select(addressed, store: store)
        #expect(model.showAll && model.selection == addressed)
    }

    @Test func thePickFollowsTheFilter() {
        let store = demo()
        let model = RouterModel()
        model.showAll = true
        model.reconcile(store: store)
        let all = store.routerCards.map(\.id)
        let addressed = store.routerCards.first { !$0.isOpen }!.id
        model.selection = addressed
        model.reconcile(store: store)
        model.showAll = false
        model.reconcile(store: store)
        // The addressed card isn't listed any more: the nearest listed one is picked, and Space acts on that one only.
        let open = Set(store.openRouterCards.map(\.id))
        #expect(model.selection.map(open.contains) == true)
        let i = all.firstIndex(of: addressed)!
        let expected = all[(i + 1)...].first(where: open.contains) ?? all[..<i].reversed().first(where: open.contains)
        #expect(model.selection == expected)
    }

    @Test func spaceNeverReopensACardThatWasSupersededUnderIt() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        let question = store.openRouterCards.first { $0.kind == .question }!
        model.select(question.id, store: store)
        model.reconcile(store: store)
        // A newer card for the same session supersedes the picked one, which leaves the Open list.
        var newer = question
        newer.id = question.id + "-newer"
        newer.createdAt = Date()
        RouterFeed.address(&store.router, question.sessionID, .superseded, Date())
        store.router.cards.append(newer)
        #expect(keys.key(key(kVK_Space, " "), responder: nil))
        let old = store.router.cards.first { $0.id == question.id }!
        #expect(old.addressedBy == .superseded)
        #expect(model.selection != question.id)
        // Nothing picked at all: Space does nothing.
        model.selection = nil
        let before = store.router.cards
        #expect(keys.key(key(kVK_Space, " "), responder: nil))
        #expect(store.router.cards == before)
    }

    // MARK: Sending

    @Test func theComposerIsShutWhileTheRouterOrTheSessionsAreOff() {
        let store = demo()
        let model = RouterModel()
        #expect(model.canSend(store))
        store.router.enabled = false
        #expect(!model.canSend(store))
        store.router.enabled = true
        store.agents.enabled = false
        #expect(!model.canSend(store))
        model.draft = "hello"
        model.send(store: store)
        #expect(model.draft == "hello")
        // Typing with nothing focused doesn't go to a composer that can't send.
        let keys = RouterKeys(store: store, model: model) {}
        #expect(!keys.key(key(kVK_ANSI_H, "h"), responder: nil))
    }

    @Test func claudeCodeMissingIsSaidOnceLookedForAndSendWaits() async {
        let store = demo()
        let model = RouterModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.claudeCodeMissing == nil && model.canSend(store))
        await model.checkClaudeCode(store, root: dir)
        #expect(model.claudeCodeMissing == true && !model.canSend(store))
        model.draft = "hello"
        model.send(store: store)
        #expect(model.draft == "hello")
        // The app's copy appears: looking again finds it.
        let bin = dir.appendingPathComponent("2.1.293/abc/claude.app/Contents/MacOS")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        await model.checkClaudeCode(store, root: dir)
        #expect(model.claudeCodeMissing == false && model.canSend(store))
    }

    // MARK: Reply and @

    @Test func returnOnAPickedCardRepliesToItAndTheReplyGoesWithTheMessage() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        let card = store.openRouterCards[1]
        model.select(card.id, store: store)
        #expect(keys.key(key(kVK_Return, "\r"), responder: nil))
        #expect(model.replyTo == card.id)
        model.projects = ["/Users/me/code/lookout"]
        model.draft = "go ahead"
        model.send(store: store)
        let line = store.router.chat.last { $0.role == .you }
        #expect(line?.replyTo == card.id && line?.projects == ["/Users/me/code/lookout"])
        // The chips go with the message.
        #expect(model.replyTo == nil && model.projects.isEmpty && model.draft.isEmpty)
    }

    @Test func escClearsTheSuggestionsThenTheReplyThenCloses() {
        let store = demo()
        let model = RouterModel()
        var closed = false
        let keys = RouterKeys(store: store, model: model) { closed = true }
        model.composerFocused = true
        model.replyTo = store.openRouterCards[0].id
        let editor = editor(model, "tell @mi")
        #expect(!model.suggestions(store).isEmpty)
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(model.suggestions(store).isEmpty && model.replyTo != nil && !closed)
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(model.replyTo == nil && !closed)
        #expect(keys.key(key(kVK_Escape), responder: editor))
        #expect(closed)
    }

    @Test func atSuggestsProjectsAndReturnOrTabPicksOne() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        model.composerFocused = true
        _ = editor(model, "check @")
        let all = model.suggestions(store).map(\.name)
        #expect(all.count >= 3)
        var view = editor(model, "check @lc")
        #expect(model.suggestions(store).first?.name == "lcu")
        #expect(keys.key(key(kVK_DownArrow), responder: view))
        let second = model.suggestions(store)[1].folder
        #expect(keys.key(key(kVK_Tab, "\t"), responder: view))
        #expect(model.projects == [second] && model.draft == "check " && model.caretRequest == 6)
        // Picked projects aren't suggested again; Return picks too.
        view = editor(model, "and @")
        #expect(!model.suggestions(store).map(\.folder).contains(second))
        #expect(keys.key(key(kVK_Return, "\r"), responder: view))
        #expect(model.projects.count == 2)
        // An @ inside a word (an email) is not a tag.
        #expect(RouterModel.mentionQuery(in: "me@lookout") == nil)
        #expect(RouterModel.mentionQuery(in: "@look out") == nil)
        #expect(RouterModel.mentionQuery(in: "hey @look") == "look")
    }

    @Test func theSuggestionsFollowTheCaretNotTheEndOfTheText() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        model.composerFocused = true
        // Mid-message: the @ word the caret is in is the one suggested, and picking it keeps the rest of the text.
        let view = editor(model, "ask @lc about the tests", caret: 7)
        #expect(model.suggestions(store).first?.name == "lcu")
        #expect(keys.key(key(kVK_Return, "\r"), responder: view))
        #expect(model.draft == "ask about the tests" && model.caretRequest == 4)
        #expect(model.projects.count == 1)
        // The caret moved off a trailing @ word: no suggestions, and ↑↓ and Return are the composer's again.
        let away = editor(model, "tell @mi", caret: 2)
        #expect(model.suggestions(store).isEmpty)
        #expect(!keys.key(key(kVK_DownArrow), responder: away))
        let before = store.router.chat.count
        #expect(keys.key(key(kVK_Return, "\r"), responder: away))
        #expect(store.router.chat.count > before)
    }

    /// The composer in a window: typing through its own text view, then moving the caret, drives the suggestions.
    @Test(.hostsWindows) func aMountedComposerFollowsTheCaret() async throws {
        let store = demo()
        let model = RouterModel()
        let hosting = NSHostingView(rootView: RouterView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 920, height: 640))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 640), styleMask: .titled, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // Other tests' windows may hold the keyboard: the composer's own field is given it here, once it is drawn.
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? [] + view.subviews.flatMap(fields) }
        func findComposer() -> NSTextField? { fields(hosting).first { $0.placeholderString?.hasPrefix("Message the Router") == true } }
        await waitUntil { findComposer() != nil }
        // The composer asks for the keyboard as it appears, two main-queue hops later, and focusing a field selects all of
        // it: that is done with before the test types and moves the caret, so it can't land in the middle.
        for _ in 0..<3 {
            await drainMainQueue()
            hosting.layoutSubtreeIfNeeded()
        }
        await waitUntilSteady(turns: 10) { (window.firstResponder as? NSTextView)?.selectedRange() }
        let composer = findComposer()
        await waitUntil {
            if !(window.firstResponder is NSTextView), let composer { window.makeFirstResponder(composer) }
            return window.firstResponder is NSTextView
        }
        let field = try #require(window.firstResponder as? NSTextView)
        /// What the view does happens on its next update, which other tests' work on the main actor can hold back.
        func settle(_ done: () -> Bool) async throws {
            await waitUntil(done)
        }
        field.insertText("ask @mi about it", replacementRange: NSRange(location: 0, length: 0))
        try await settle { model.draft == "ask @mi about it" }
        #expect(model.draft == "ask @mi about it" && model.suggestions(store).isEmpty)
        field.setSelectedRange(NSRange(location: 7, length: 0))
        try await settle { !model.suggestions(store).isEmpty }
        #expect(model.suggestions(store).first?.name == "microsandbox")
        // The composer losing the keyboard (here, as SwiftUI may take it from a field in a window that isn't key) ends its
        // editing, which moves the editor's selection: that is not the composer's caret moving.
        window.makeFirstResponder(nil)
        await drainMainQueue()
        await waitUntilSteady(turns: 10) { model.caret }
        #expect(model.caret == 7 && model.suggestions(store).first?.name == "microsandbox")
        // Other text views moving their caret (another window's, one elsewhere in this window, even holding the same text)
        // leave the composer's alone.
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .titled, backing: .buffered,
                             defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let elsewhere = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        other.contentView = elsewhere
        let beside = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        hosting.addSubview(beside)
        defer { beside.removeFromSuperview() }
        for view in [elsewhere, beside] {
            view.string = "ask @mi about it"
            view.setSelectedRange(NSRange(location: 1, length: 0))
        }
        // Whatever the view does with those notifications it does on its next updates: once the caret has read the same over
        // several turns of the main actor, it has had them.
        await drainMainQueue()
        await waitUntilSteady(turns: 10) { model.caret }
        #expect(model.caret == 7 && model.suggestions(store).first?.name == "microsandbox")
        // The composer's own caret moving away still counts (given the keyboard again if the others took it).
        await waitUntil {
            if window.firstResponder !== field, let composer { window.makeFirstResponder(composer) }
            return window.firstResponder === field
        }
        let own = try #require(window.firstResponder as? NSTextView)
        own.setSelectedRange(NSRange(location: 1, length: 0))
        try await settle { model.suggestions(store).isEmpty }
        #expect(model.suggestions(store).isEmpty)
    }

    @Test func aClickedFinishedCardIsOpenedThenStaysPicked() {
        let store = demo()
        let model = RouterModel()
        let done = store.openRouterCards.first { $0.kind == .done }!
        model.open(done.id, store: store)
        model.reconcile(store: store)
        // Opening addressed it; the pick stayed on it (every card shows).
        #expect(store.router.cards.first { $0.id == done.id }?.isOpen == false)
        #expect(model.selection == done.id && model.showAll)
    }

    @Test func returnRepliesOnlyToAListedCard() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        model.reconcile(store: store)
        // Picked, then addressed elsewhere: under Open it isn't listed any more.
        let open = store.openRouterCards.map(\.id)
        model.selection = open[1]
        model.reconcile(store: store)
        store.setCardAddressed(open[1], true)
        #expect(keys.key(key(kVK_Return, "\r"), responder: nil))
        #expect(model.replyTo != open[1] && !model.showAll)
        #expect(model.replyTo.map { id in store.openRouterCards.contains { $0.id == id } } == true)
        // Nothing listed at all: Return only focuses the composer.
        for id in store.openRouterCards.map(\.id) { store.setCardAddressed(id, true) }
        model.replyTo = nil
        let request = model.focusRequest
        #expect(keys.key(key(kVK_Return, "\r"), responder: nil))
        #expect(model.replyTo == nil && model.focusRequest != request)
    }

    @Test func backspaceAtTheStartTakesTheLastChipOff() {
        let store = demo()
        let model = RouterModel()
        let keys = RouterKeys(store: store, model: model) {}
        let editor = NSTextView()
        model.composerFocused = true
        model.replyTo = store.openRouterCards[0].id
        model.projects = ["/a", "/b"]
        #expect(keys.key(key(kVK_Delete), responder: editor))
        #expect(model.projects == ["/a"])
        #expect(keys.key(key(kVK_Delete), responder: editor))
        #expect(keys.key(key(kVK_Delete), responder: editor))
        #expect(model.projects.isEmpty && model.replyTo == nil)
        // Nothing left: the key is the field's.
        #expect(!keys.key(key(kVK_Delete), responder: editor))
        // Not at the start: the field's.
        editor.string = "abc"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        model.projects = ["/a"]
        #expect(!keys.key(key(kVK_Delete), responder: editor) && model.projects == ["/a"])
    }

    @Test func theDemoChatHasARephrasedReceiptAndAnUndeliveredMessage() {
        let chat = demo().router.chat
        #expect(chat.contains { $0.role == .receipt && $0.original != nil })
        #expect(chat.contains { $0.role == .error })
    }

    @Test func settingsSayHowThePluginIsDoing() {
        #expect(SettingsView.pluginLine(.installed, error: nil).0.contains("/reload-plugins"))
        #expect(SettingsView.pluginLine(.installed, error: nil).1 == Theme.green)
        #expect(SettingsView.pluginLine(.noClaudeCode, error: nil).0.contains("Claude desktop app"))
        let failed = SettingsView.pluginLine(.notInstalled, error: "Plugin install failed: marketplace not found")
        #expect(failed.0.hasSuffix("marketplace not found") && failed.1 == Theme.red)
        #expect(SettingsView.pluginLine(nil, error: nil).0.contains("will be installed"))
    }

    @Test func aFailedRemovalStaysInSightWithTheRouterOffAndCanBeTriedAgain() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Lookout.app/Contents/MacOS/Lookout"
        s.routerPluginRunner = cli.runner
        s.routerClaudeBinary = { "/fake/claude" }
        s.routerAppVersion = "1.0.0"
        s.agents.enabled = true
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        cli.failing = "plugin uninstall"
        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        let error = try #require(s.routerRemovalError)
        #expect(error.contains("boom"))
        // Settings shows it, and the button that tries again, though the Router's own lines are hidden while it is off.
        let tree = try await AccessibilityTree.render(SettingsView(store: s, hub: HubState()).frame(width: 440, height: 2400),
                                                      size: CGSize(width: 440, height: 2400))
        #expect(tree.all.contains { $0.role == "AXButton" && $0.label == "Try again" })
        cli.failing = nil
        s.retryRouterRemoval()
        await s.routerHookWork?.value
        #expect(s.routerRemovalError == nil && s.routerPluginStatus == .notInstalled && cli.plugins.isEmpty)
    }

    @Test func fuzzyMentionsRankPrefixesFirst() {
        let ranked = RouterMentions.rank([("/a", "microsandbox"), ("/b", "lcu"), ("/c", "lcu-research"), ("/d", "lookout")],
                                         query: "lc", limit: 6).map(\.name)
        #expect(ranked == ["lcu", "lcu-research"])
        #expect(RouterMentions.rank([("/a", "microsandbox")], query: "msb", limit: 6).map(\.name) == ["microsandbox"])
        #expect(RouterMentions.rank([("/a", "microsandbox")], query: "zz", limit: 6).isEmpty)
    }

    // MARK: Forms

    @Test func aFormIsAnsweredOnceEveryQuestionIs() async {
        let store = demo()
        let card = store.openRouterCards.first { $0.kind == .question }!
        let form = store.pendingForm(for: card)!
        let model = RouterModel()
        #expect(model.answers(form) == nil)
        let q = form.questions[0]
        model.pick("Ask first", in: q, of: form)
        #expect(model.answers(form) == [q.question: "Ask first"])
        // Your own words replace the pick of a one-choice question.
        model.setOther("Ask once a week", in: q, of: form)
        #expect(model.answers(form) == [q.question: "Ask once a week"])
        model.sendAnswer(form, card: card.id, store: store)
        // Written off the main thread: "Sent" shows once it is; meanwhile nothing can be changed or sent again.
        #expect(model.sending.contains(form.id) && !model.sent.contains(form.id) && model.locked(form))
        model.pick("Install silently", in: q, of: form)
        model.setOther("changed my mind", in: q, of: form)
        #expect(model.answers(form) == [q.question: "Ask once a week"])
        await model.lastWrite?.value
        #expect(model.sent.contains(form.id) && model.formErrors[form.id] == nil && model.sending.isEmpty)
        // Once sent: what was answered (read-only), and still nothing to change.
        #expect(model.delivered[form.id] == [q.question: "Ask once a week"] && model.locked(form))
        model.pick("Install silently", in: q, of: form)
        #expect(model.answers(form) == [q.question: "Ask once a week"])
    }

    /// A store that writes for real, its forms folder in `dir` (nil: never started, as with the Router off).
    private func writing(_ dir: URL?) -> Store {
        let store = demo()
        store.stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("router-ui-\(UUID().uuidString).json")
        store.persists = true
        if let dir { store.formBridge.start(dir: dir) { _ in } }
        return store
    }

    @Test func anAnswerIsWrittenToTheFormsFolder() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-forms-\(UUID().uuidString)")
        let store = writing(dir)
        defer { store.formBridge.stop(); store.persists = false; try? FileManager.default.removeItem(at: dir) }
        let card = store.openRouterCards.first { $0.kind == .question }!
        let form = store.pendingForm(for: card)!
        let model = RouterModel()
        model.pick("Ask first", in: form.questions[0], of: form)
        model.sendAnswer(form, card: card.id, store: store)
        await model.lastWrite?.value
        #expect(model.sent.contains(form.id))
        #expect(FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: dir).path))
    }

    @Test func answeringWhileTheRouterIsSwitchedOffWritesNothing() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("router-forms-\(UUID().uuidString)")
        let store = writing(dir)
        defer { store.formBridge.stop(); store.persists = false; try? FileManager.default.removeItem(at: dir) }
        let card = store.openRouterCards.first { $0.kind == .question }!
        let form = store.pendingForm(for: card)!
        let model = RouterModel()
        model.pick("Ask first", in: form.questions[0], of: form)
        model.sendAnswer(form, card: card.id, store: store)
        // Switched off before the write happens.
        store.router.enabled = false
        await model.lastWrite?.value
        #expect(!model.sent.contains(form.id) && !model.locked(form))
        #expect(model.formErrors[form.id] == FormWriter.Cancelled().errorDescription)
        #expect(!FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: dir).path))
    }

    @Test func aRefusedAnswerShowsWhyAndIsNotSent() async {
        let store = demo()
        // A real write (not a demo's), with no forms folder to write to (the Router off): an error, nothing written.
        store.stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("router-ui-\(UUID().uuidString).json")
        store.persists = true
        defer { store.persists = false; try? FileManager.default.removeItem(at: store.stateFile!) }
        let card = store.openRouterCards.first { $0.kind == .question }!
        let form = store.pendingForm(for: card)!
        let model = RouterModel()
        model.pick("Ask first", in: form.questions[0], of: form)
        model.sendAnswer(form, card: card.id, store: store)
        await model.lastWrite?.value
        #expect(!model.sent.contains(form.id) && model.formErrors[form.id] != nil && model.sending.isEmpty)
    }

    @Test func severalChoicesAreJoinedAsTheFormTakesThem() {
        let q = PendingForm.Question(question: "Which?", header: "", multiSelect: true,
                                     options: [.init(label: "A", description: ""), .init(label: "B", description: "")])
        let form = PendingForm(id: "k", cliSessionID: "c", transcriptPath: "", questions: [q], createdAt: now, pid: 0)
        let model = RouterModel()
        model.pick("A", in: q, of: form)
        model.pick("B", in: q, of: form)
        #expect(model.answers(form) == ["Which?": "A, B"])
        model.pick("A", in: q, of: form)
        #expect(model.answers(form) == ["Which?": "B"])
    }

    // MARK: Bar

    /// The kept-open hub's width along the top or bottom of a screen `width` wide.
    private func openWidth(_ edge: DockEdge, _ width: CGFloat, _ scenario: Demo.Scenario = .router) async throws
        -> (hub: CGFloat, column: Bool) {
        let store = demo(scenario)
        let hub = HubState()
        let box = WidthBox()
        let view = LookoutHub(store: store, ui: UIState(persists: false, edge: edge), hub: hub, maxLength: 600, maxWidth: width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box.width = $0 }
            .frame(width: width, height: 800, alignment: .topLeading)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 800), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return box.width > 0
        }
        await waitUntilSteady { box.width }
        let rest = box.width
        hub.pinned = true
        // Kept open, the strip spans its columns: wider than at rest.
        await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return box.width > rest
        }
        // Until the width settles where pinning took it, however slowly the machine lays it out.
        await waitUntilSteady(turns: 10) {
            hosting.layoutSubtreeIfNeeded()
            return box.width
        }
        hosting.layoutSubtreeIfNeeded()
        return (box.width, LookoutHub.routerColumnFits(maxWidth: width, trailing: 140, sessions: !store.sessionsHidden))
    }

    @Test(.hostsWindows) func alongTheTopAndBottomTheRoutersColumnGoesBeforeTheHubOverflows() async throws {
        for edge in [DockEdge.top, .bottom] {
            let narrow = try await openWidth(edge, 1024)
            #expect(narrow.hub <= 1024, "\(edge) at 1024: \(narrow.hub)")
            #expect(!narrow.column)
            let wide = try await openWidth(edge, 1280)
            #expect(wide.hub <= 1280, "\(edge) at 1280: \(wide.hub)")
            #expect(wide.column)
        }
    }

    // MARK: Router only

    @Test(.hostsWindows) func routerOnlyGivesTheRoomBackAlongTheTopAndBottom() async throws {
        for edge in [DockEdge.top, .bottom] {
            for width in [CGFloat(1024), 1280] {
                let only = try await openWidth(edge, width, .routerOnly)
                let both = try await openWidth(edge, width, .router)
                #expect(only.hub <= width, "\(edge) at \(width): \(only.hub)")
                // The Router keeps its column (the sessions' room is its), and the hub is no wider than with the sessions.
                #expect(only.column && only.hub <= both.hub + 0.5, "\(edge) at \(width): \(only.hub) vs \(both.hub)")
            }
        }
    }

    @Test func routerOnlyTakesTheSessionsOffTheBarAndBringsThemBack() async throws {
        func labels(_ scenario: Demo.Scenario, _ configure: @escaping (Store, HubState) -> Void) async throws -> [String] {
            try await AccessibilityTree.render(scenario: scenario, configure: configure).all.map(\.label)
        }
        for edge in [DockEdge.right, .top] {
            for pinned in [false, true] {
                let only = try await AccessibilityTree.render(edge: edge, scenario: .routerOnly) { _, hub in hub.pinned = pinned }
                #expect(!only.all.contains { $0.label == "Sessions" || $0.label == "Calculator display reading" && $0.role == "AXButton" },
                        "\(edge) \(pinned)")
                let back = try await AccessibilityTree.render(edge: edge, scenario: .routerOnly) { store, hub in
                    store.setRouterOnly(false)
                    hub.pinned = pinned
                }
                #expect(back.all.contains { $0.label == "Sessions" }, "\(edge) \(pinned)")
            }
        }
        // The Router's panel lists what works, each line opening its session.
        let peek = try await labels(.routerOnly) { _, hub in hub.section = .router }
        #expect(peek.contains("Agent completion notifications"))
        // Off again with the Router off: the sessions are back whatever the setting says.
        let off = try await labels(.routerOnly) { store, _ in store.setRouterEnabled(false) }
        #expect(off.contains("Sessions"))
    }

    @Test func inRouterOnlyABrokenReadOfClaudesFilesIsStillSaid() async throws {
        func says(_ link: ClaudeLink, _ configure: @escaping (HubState) -> Void) async throws -> Bool {
            let tree = try await AccessibilityTree.render(edge: .top, scenario: .routerOnly) { store, hub in
                store.claudeLink = link
                configure(hub)
            }
            return tree.all.contains { ($0.label + $0.value).contains("Claude's sessions") }
        }
        for state in [{ (hub: HubState) in hub.section = .router }, { (hub: HubState) in hub.pinned = true }] {
            #expect(try await says(.missing, state))
            #expect(try await !says(.ok, state))
        }
    }

    @Test func theWorkingListIsWhatRunsLongestFirstAndOpensIt() {
        let store = demo(.routerOnly)
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        let rows = store.routerWorkingRows
        // The turn that works, and the finished one still running its subagents and command (oldest of them first).
        #expect(rows.map(\.id) == ["local_demo-ci", "local_demo-lookout"])
        #expect(rows[0].tasksText == "3 running" && !rows[0].session.running)
        #expect(!rows.contains { $0.waitsForYou })
        store.openAgent(rows[1].id)
        #expect(opened.first?.contains("Agent completion notifications") == true)
    }

    @Test(.hostsWindows) func turningRouterOnlyOnDropsTheSessionsFocusAndPick() async throws {
        for edge in [DockEdge.right, .top] {
            let store = demo(.router)
            let hub = HubState(), ui = UIState(persists: false, edge: edge)
            hub.pinned = true
            hub.focus = .agents
            hub.selection = "a:local_demo-ci"
            let hosting = NSHostingView(rootView: LookoutHub(store: store, ui: ui, hub: hub, maxLength: 700, maxWidth: 1280)
                .frame(width: 1280, height: 800, alignment: .topLeading))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            // On screen with the sessions focused and one picked; then Router only.
            #expect(hub.focus == .agents && hub.selection == "a:local_demo-ci")
            store.setRouterOnly(true)
            await waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return hub.focus == nil && hub.selection == nil
            }
            #expect(hub.focus == nil, "\(edge): \(String(describing: hub.focus))")
            #expect(hub.selection == nil, "\(edge): \(String(describing: hub.selection))")
            // And the section itself is gone from what the hub draws now.
            let tree = try await AccessibilityTree.render(LookoutHub(store: store, ui: ui, hub: hub, maxLength: 700, maxWidth: 1280)
                .frame(width: 1280, height: 800, alignment: .topLeading), size: CGSize(width: 1280, height: 800))
            #expect(!tree.all.contains { $0.label == "Sessions" }, "\(edge)")
            #expect(tree.all.contains { $0.label == "Inbox" })
        }
    }

    @Test func rowKeysLeaveAHiddenSessionAlone() {
        let store = demo(.routerOnly)
        var opened: [String] = []
        store.interceptOpen = { opened.append($0) }
        let hub = HubState(), ui = UIState(persists: false, edge: .right)
        hub.pinned = true
        let keys = HubKeys(store: store, ui: ui, hub: hub)
        // Picked before the tiles went (not listed now): Return, ⌘K and ⌘⌫ do nothing to it.
        hub.selection = "a:local_demo-ci"
        let pinned = store.agents.entries.first { $0.id == "local_demo-ci" }?.kept
        for shortcut in [store.shortcut(.openItem), store.shortcut(.keepSession), store.shortcut(.removeSession)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.flags, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "", charactersIgnoringModifiers: shortcut.keyCode == 40 ? "k" : "",
                                         isARepeat: false, keyCode: shortcut.keyCode)!
            _ = keys.key(event)
        }
        #expect(opened.isEmpty)
        #expect(store.agents.entries.first { $0.id == "local_demo-ci" }?.kept == pinned)
        keys.followSessionsHidden()
        #expect(hub.selection == nil)
    }

    @Test func theSwitcherSearchesWhenThereAreNoTiles() {
        let store = demo(.routerOnly)
        let hub = HubState(), ui = UIState(persists: false, edge: .right)
        let keys = HubKeys(store: store, ui: ui, hub: hub)
        // No session rows to walk with the arrows while nothing is searched.
        #expect(store.hubTargets(hub).allSatisfy { $0.hasPrefix("i:") })
        keys.showSessions()
        #expect(hub.pinned && hub.searchOpen && hub.selection == nil)
        hub.query = "calc"
        #expect(store.hubTargets(hub).contains("a:local_demo-calc"))
        // With the tiles, it picks the first that needs you, as before.
        let tiles = demo(.router)
        let hub2 = HubState()
        HubKeys(store: tiles, ui: ui, hub: hub2).showSessions()
        #expect(hub2.pinned && !hub2.searchOpen && hub2.selection?.hasPrefix("a:") == true)
    }

    @Test func routerOnlyIsOnUnlessTurnedOffAndRemembered() throws {
        #expect(RouterState().routerOnly)
        let old = try JSONDecoder().decode(RouterState.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.routerOnly)
        var state = RouterState()
        state.routerOnly = false
        let back = try JSONDecoder().decode(RouterState.self, from: JSONEncoder().encode(state))
        #expect(!back.routerOnly)
    }

    @Test func withTheRouterOnTheBarHasNoNewSessionRow() async throws {
        func hasNewSession(_ scenario: Demo.Scenario) async throws -> Bool {
            let tree = try await AccessibilityTree.render(scenario: scenario) { _, hub in hub.pinned = true }
            return tree.all.contains { $0.label == "New session" }
        }
        #expect(try await hasNewSession(.routerOff))
        #expect(try await !hasNewSession(.router))
    }

    /// "All" once froze the window. With a few hundred cards, a card picked far down and the minute clock running, flipping
    /// the filter and scrolling to the picked card stay well within a frame budget.
    @Test(.hostsWindows) func theFilterFlipsQuicklyWithManyCards() async throws {
        let store = demo()
        let base = store.router.cards
        for i in 0..<300 {
            var card = base[i % base.count]
            card.id = "\(card.sessionID)#t\(1000 + i)"
            card.kind = i % 2 == 0 ? .done : .stuck
            card.createdAt = Date().addingTimeInterval(-Double(i) * 60)
            if i % 5 != 0 { card.addressedAt = card.createdAt; card.addressedBy = .opened }
            card.text = String(repeating: "A summary long enough to wrap onto more lines. ", count: 1 + i % 4)
            store.router.cards.append(card)
        }
        let model = RouterModel()
        model.selection = store.openRouterCards.last?.id
        // Offscreen and borderless, as the other window tests (it never needs the keyboard, and a loaded CI runner is slow
        // to bring a titled window up).
        let hosting = NSHostingView(rootView: RouterView(store: store, model: model, checksClaudeCode: false)
            .frame(width: 920, height: 640))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 640), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        // Only the synchronous work is timed, in one go (no suspension where other tests could take the main actor), with a
        // budget a loaded runner keeps well within. A watchdog notes a deadline passed but never ends the process.
        let watchdog = Deadline(seconds: 60, "theFilterFlipsQuicklyWithManyCards: flipping the filter took over a minute")
        let work = ContinuousClock().measure {
            for all in [true, false, true, false] {
                model.showAll = all
                hosting.layoutSubtreeIfNeeded()
                hosting.display()
            }
            model.select(store.routerCards.last?.id, store: store)
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        watchdog.done()
        #expect(work < .seconds(10), "\(work)")
        #expect(!watchdog.passed)
    }

    // MARK: Banners

    @Test func bannersAreForWhatNeedsYouAndNotWhileTheWindowHasTheKeys() {
        let store = demo()
        store.settings.notifications = true
        var posted: [String] = []
        store.notifier.onPost = { posted.append($0.identifier) }
        let cards = store.openRouterCards
        RouterBanners.post(cards, store: store, windowIsKey: true)
        #expect(posted.isEmpty)
        RouterBanners.post(cards, store: store, windowIsKey: false)
        #expect(posted.sorted() == cards.filter(\.kind.needsYou).map { RouterBanners.prefix + $0.id }.sorted())
        posted = []
        store.settings.snoozeUntil = Date().addingTimeInterval(600)
        RouterBanners.post(cards, store: store, windowIsKey: false)
        #expect(posted.isEmpty)
    }

    @Test func aBannersClickOpensTheWindowOnItsCard() {
        let store = demo()
        var opened: String?
        var other: String?
        store.notifier.onOpen = { id, _, _ in other = id }
        RouterBanners.attach(store: store, windowIsKey: { false }) { opened = $0 }
        store.notifier.onOpen?(RouterBanners.prefix + "card#1", nil, false)
        store.notifier.onOpen?("item", nil, false)
        #expect(opened == "card#1" && other == "item")
    }

    // MARK: Shortcut

    @Test func theRoutersKeyIsRegisteredOnlyWhileItIsOn() async {
        let store = Store()
        store.persists = false
        store.agents.enabled = true
        let registrar = Registrar()
        let globals = GlobalShortcuts(store: store, registrar: registrar) { _ in }
        globals.start()
        #expect(registrar.registered[ShortcutAction.router.hotKeyID] == nil)
        store.router.enabled = true
        for _ in 0..<5 { await Task.yield() }
        #expect(registrar.registered[ShortcutAction.router.hotKeyID] == ShortcutAction.router.defaultShortcut)
        store.agents.enabled = false
        for _ in 0..<5 { await Task.yield() }
        #expect(registrar.registered[ShortcutAction.router.hotKeyID] == nil)
        withExtendedLifetime(globals) {}
    }

    @Test func theRoutersDefaultKeyIsFree() {
        let others = ShortcutAction.allCases.filter { $0 != .router }.map(\.defaultShortcut)
        #expect(!others.contains(ShortcutAction.router.defaultShortcut))
        #expect(ShortcutAction.router.defaultShortcut.display.hasPrefix("⌃⌥"))
        #expect(Set(ShortcutAction.allCases.filter(\.isGlobal).map(\.hotKeyID)).count == 3)
    }
}

private final class Registrar: HotKeyRegistrar {
    var registered: [UInt32: Shortcut] = [:]
    var isSuspended = false

    func set(_ id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        registered[id] = shortcut
        return true
    }
}

@MainActor private final class WidthBox {
    var width: CGFloat = 0
}

/// A watchdog on a thread of its own: a main thread stuck in layout can't time itself.
final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var late = false

    /// Whether `seconds` went by before `done()`.
    var passed: Bool { lock.withLock { late } }

    /// After `seconds` without `done()`, says so on stderr (a test stuck on the main thread shows in the log) and marks it
    /// passed for the test to fail on once it returns. It never ends the process.
    init(seconds: Double, _ message: String) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [self] in
            let report = lock.withLock { () -> Bool in
                guard !finished else { return false }
                late = true
                return true
            }
            if report { FileHandle.standardError.write(Data("Deadline passed: \(message)\n".utf8)) }
        }
    }

    func done() {
        lock.withLock { finished = true }
    }
}
