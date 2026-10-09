import AppKit
import SwiftUI

// The Router's window: what needs you on the left (its cards), the chat with the Router on the right. The bar only says how
// many cards are open and what is running; everything else is here.

// MARK: - Store

extension Store {
    /// The Router works on the sessions: it is on only while the sessions extension is too.
    var routerOn: Bool { router.enabled && agents.enabled }

    /// A card's project, as the lists name and colour it.
    func routerProject(_ card: RouterCard) -> (name: String, color: Color?) {
        let folder = card.folder ?? ""
        return (folderName(folder), projectColor(folder))
    }

    /// The cards the window lists: the open ones, or all of them.
    func routerCards(all: Bool) -> [RouterCard] { all ? routerCards : openRouterCards }

    /// The line of live work, as of `now` (see `RouterStatusLine`).
    func routerStatus(now: Date) -> String { RouterStatusLine.text(allAgentRows, now: now) }

    /// The Router's own process must never reach real sessions from a demo or a playground: it answers for itself there.
    var routerIsPretend: Bool { Store.isDemo || !persists }

    /// Your message to the Router, with the card it replies to and the projects you tagged; in a demo, a canned reply
    /// instead of a real process.
    func sendToRouter(_ text: String, replyTo: String? = nil, projects: [String] = [], now: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if routerIsPretend {
            router.chat.append(RouterMessage(role: .you, text: text, date: now, replyTo: replyTo,
                                             projects: projects.isEmpty ? nil : projects))
            router.chat.append(RouterMessage(role: .router, text: "In a demo the Router only says what it would do.", date: now))
        } else {
            routerAgent.send(text, context: RouterContext(replyTo: replyTo, projects: projects))
        }
    }

    /// Writes a form's answer for its card's session (the hook passes it on) through the shared `FormWriter`, off the main
    /// thread; in a demo, nothing is written. The folder is taken now, on the main thread: none while the Router is off. The
    /// write is dropped if, by the time it happens, the Router or the sessions are off or the card is no longer open.
    func answerForm(_ form: PendingForm, _ answers: [String: String], card: String) async -> Result<Void, Error> {
        if routerIsPretend { return Result { _ = try FormBridge.validate(form, answers) } }
        guard let dir = formBridge.dir else { return .failure(FormWriter.Cancelled()) }
        do {
            try await FormWriter.write(form, answers: answers, dir: dir) { [weak self] in
                guard let self else { return false }
                return self.routerOn && self.router.cards.first(where: { $0.id == card })?.isOpen == true
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// The one-line summary of live work, built from the session rows alone (no model writes it): how many are working, the
/// longest running with what each is doing and for how long, then those waiting on you. "All quiet" when nothing runs.
enum RouterStatusLine {
    /// Named sessions per kind; the count before them says how many there are in all.
    static let shown = 2

    static func text(_ rows: [AgentRow], now: Date) -> String {
        let working = rows.filter { $0.session.running && !$0.waitsForYou }
            .sorted { ($0.workingSince ?? now) < ($1.workingSince ?? now) }
        let waiting = rows.filter(\.waitsForYou)
        if working.isEmpty && waiting.isEmpty { return "All quiet" }
        var parts: [String] = []
        if !working.isEmpty { parts.append("\(working.count) working") }
        parts += working.prefix(shown).map {
            "\($0.projectName): \($0.activity?.text ?? "Working") \(minutes(now.timeIntervalSince($0.workingSince ?? now)))"
        }
        parts += waiting.prefix(shown).map { "\($0.projectName): waiting on you" }
        if waiting.count > shown { parts.append("\(waiting.count - shown) more waiting") }
        return parts.joined(separator: " · ")
    }

    /// Whole minutes: the line is redrawn once a minute, so seconds would only ever be wrong.
    static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t)) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

/// Content redrawn on the minute and only then (ages, the status line): nothing else ticks for it.
struct MinuteTicking<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.everyMinute) { context in content(context.date) }
    }
}

/// The status line wherever it shows: a dot (clay while something works) and the line, cut short at its width.
struct RouterStatusView: View {
    let store: Store
    var lines = 1

    var body: some View {
        MinuteTicking { now in
            let text = store.routerStatus(now: now)
            let quiet = text == "All quiet"
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(quiet ? Theme.tertiary : Theme.claude).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(quiet ? Theme.tertiary : Theme.secondary)
                    .lineLimit(lines).truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sessions: \(text)")
        }
    }
}

// MARK: - Cards

extension RouterCard.Kind {
    var label: String {
        switch self {
        case .question: "Question"
        case .plan: "Plan"
        case .done: "Done"
        case .stuck: "Stuck"
        }
    }

    var color: Color {
        switch self {
        case .question: Theme.amber
        case .plan: Theme.purple
        case .done: Theme.accent
        case .stuck: Theme.red
        }
    }

    var symbol: String {
        switch self {
        case .question: "questionmark.bubble.fill"
        case .plan: "list.bullet.clipboard.fill"
        case .done: "checkmark"
        case .stuck: "exclamationmark.triangle.fill"
        }
    }
}

extension RouterCard.Addressed {
    /// What happened to an addressed card, in a few words.
    var label: String {
        switch self {
        case .you: "Marked addressed"
        case .reply: "You replied"
        case .router: "The Router passed it on"
        case .answered: "Answered"
        case .opened: "Opened"
        case .superseded: "Followed by a newer card"
        case .gone: "Session archived"
        }
    }
}

/// A card's kind in its colour: words and a glyph, never colour alone.
struct KindTag: View {
    let kind: RouterCard.Kind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(Theme.Typography.caption.weight(.semibold))
            .foregroundStyle(kind.color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(kind.color.opacity(0.14)))
            .fixedSize()
    }
}

/// Card text is the app's own summary or the session's question: inline Markdown (**bold**, `code`) as the sessions show it.
enum RouterText {
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A card on two short lines, for the bar's panel: the session and its age, then the kind, the project and the text.
/// Clicking it opens its session in Claude (and picks it in the window).
struct RouterCardLine: View {
    let card: RouterCard
    let store: Store
    /// In a narrow column: the project goes (the kind and the text stay).
    var narrow = false
    let open: (String) -> Void
    @State private var hover = false

    var body: some View {
        let project = store.routerProject(card)
        Button { open(card.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(card.kind.color).frame(width: 6, height: 6).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(card.title).font(Theme.Typography.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(shortAgo(card.createdAt)).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                    HStack(spacing: 6) {
                        KindTag(kind: card.kind)
                        if !narrow {
                            ProjectLabel(name: project.name, color: project.color)
                                .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
                        }
                        Text(RouterText.inline(card.text)).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(card.kind.label): \(card.title)")
        .accessibilityValue("\(project.name), \(card.text), \(AgentRow.spokenAge(Date().timeIntervalSince(card.createdAt))) ago")
        .accessibilityHint("Opens it in Claude")
    }
}

// MARK: - Window model

/// What the window remembers while it is closed (the draft, the picked card, the answers being put together), and what
/// the keys act on.
@Observable
@MainActor
final class RouterModel {
    /// The card the keys act on.
    var selection: String?
    /// Every card, not only the open ones.
    var showAll = false
    var draft = "" {
        didSet { if draft != oldValue { mentionChanged() } }
    }
    /// The card your next message answers: it goes to that card's session ("Replying to …" over the composer).
    var replyTo: String?
    /// Projects tagged with @ (their folders), in the order picked: the Router looks there, and starts a session there.
    var projects: [String] = []
    /// While an @ is being typed: what follows it, and the suggestion picked with ↑↓.
    private(set) var mention: String?
    var mentionIndex = 0
    /// The @ word Esc dismissed: its suggestions stay away until it changes.
    @ObservationIgnored private var dismissedMention: String?
    /// Mirrors the composer's focus, for the keys.
    var composerFocused = false
    /// Bumped to ask the composer for the keyboard.
    var focusRequest = 0
    /// The keys that put the focus in the composer, typed into it once it has it.
    @ObservationIgnored var pendingKeys: [NSEvent] = []
    /// Asks the card list to scroll to a card.
    var scrollRequest: ScrollRequest?
    /// Per form (by its key): the options picked for each question, and the words typed in "Other".
    var picks: [String: [String: [String]]] = [:]
    var other: [String: [String: String]] = [:]
    /// Forms answered from here, until the session moves on, and what was sent.
    var sent: Set<String> = []
    var delivered: [String: [String: String]] = [:]

    /// The form's controls are shut while its answer is written and once it is.
    func locked(_ form: PendingForm) -> Bool { sending.contains(form.id) || sent.contains(form.id) }
    var formErrors: [String: String] = [:]

    /// Whether Claude Code was looked for and isn't there (see `checkClaudeCode`); nil until looked for.
    var claudeCodeMissing: Bool?
    /// Forms whose answer is being written.
    var sending: Set<String> = []
    /// The latest answer being written, for tests to wait on.
    @ObservationIgnored var lastWrite: Task<Void, Never>?
    /// The cards listed at the last reconcile, in order: where a picked card that left the list was.
    @ObservationIgnored private var listed: [String] = []

    func cards(_ store: Store) -> [RouterCard] { store.routerCards(all: showAll) }

    /// Whether a message can go to the Router now: it is on (with the sessions extension) and Claude Code is there.
    func canSend(_ store: Store) -> Bool {
        store.routerOn && !(claudeCodeMissing == true && store.routerAgent.claudeCode == nil)
    }

    /// Looks for Claude Code once the window shows (the app updates its copy now and then): until the search has finished
    /// nothing is said, and Send waits. In a demo it is never missing; under test, `root` stands in for the app's folder.
    func checkClaudeCode(_ store: Store, root: URL? = nil) async {
        if store.routerIsPretend && root == nil { claudeCodeMissing = false; return }
        if store.routerAgent.claudeCode != nil && root == nil { claudeCodeMissing = false; return }
        guard let root = root ?? store.routerAgent.codeRoot else { claudeCodeMissing = false; return }
        let found = await Task.detached(priority: .utility) { RouterAgent.find(in: root) != nil }.value
        if claudeCodeMissing != !found { claudeCodeMissing = !found }
    }

    /// The pick follows the list: kept while it is listed; when the filter or the cards change and it isn't, the nearest
    /// card listed after it (or before it) is picked, else none. Every key acts on the list as it is now.
    func reconcile(store: Store) {
        let ids = cards(store).map(\.id)
        defer { listed = ids }
        guard let id = selection, !ids.contains(id) else { return }
        let visible = Set(ids)
        var next: String?
        if let i = listed.firstIndex(of: id) {
            next = listed[(i + 1)...].first(where: visible.contains) ?? listed[..<i].reversed().first(where: visible.contains)
        }
        selection = next
        if let next { scrollRequest = ScrollRequest(id: next, seq: (scrollRequest?.seq ?? 0) + 1) }
    }

    /// Picks a card (and scrolls to it); a card the Open filter hides shows every card.
    func select(_ id: String?, store: Store) {
        if let id, !showAll, store.openRouterCards.first(where: { $0.id == id }) == nil,
           store.router.cards.contains(where: { $0.id == id }) { showAll = true }
        selection = id
        if let id { scrollRequest = ScrollRequest(id: id, seq: (scrollRequest?.seq ?? 0) + 1) }
    }

    /// ↑↓: the next card up or down, the first (or last) when none is picked.
    func move(down: Bool, store: Store) {
        reconcile(store: store)
        let ids = cards(store).map(\.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: selection ?? "") ?? (down ? -1 : ids.count)
        select(ids[min(max(i + (down ? 1 : -1), 0), ids.count - 1)], store: store)
    }

    /// Space: addressed, or open again. Under Open, an addressed card leaves the list, so the next one is picked.
    func toggleAddressed(store: Store) {
        reconcile(store: store)
        let ids = cards(store).map(\.id)
        guard let id = selection, ids.contains(id), let card = store.router.cards.first(where: { $0.id == id }) else { return }
        let next = ids.firstIndex(of: id).map { i in ids.indices.contains(i + 1) ? ids[i + 1] : i > 0 ? ids[i - 1] : nil } ?? nil
        store.setCardAddressed(id, card.isOpen)
        Announce.say(card.isOpen ? "Addressed" : "Open again")
        if card.isOpen, !showAll { select(next, store: store) }
    }

    /// Sends the draft with its reply and project chips (which go with it); the composer keeps the focus for the next one.
    func send(store: Store) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend(store) else { return }
        let reply = replyTo.flatMap { id in store.router.cards.contains { $0.id == id } ? id : nil }
        store.sendToRouter(text, replyTo: reply, projects: projects)
        caret = nil
        draft = ""
        replyTo = nil
        projects = []
    }

    /// A card clicked: its session opens in Claude first (a finished turn is addressed by that), then the card is picked as it
    /// now is (one the Open filter no longer lists shows every card), so the pick stays on it.
    func open(_ id: String, store: Store) {
        store.openCard(id)
        select(id, store: store)
    }

    /// The composer takes the keyboard (typing anywhere in the window lands there).
    func reply() { focusRequest &+= 1 }

    /// Reply: a "Replying to" chip for that card over the composer, which takes the keyboard. Your words are yours to write.
    func reply(to card: String, store: Store) {
        select(card, store: store)
        replyTo = card
        focusRequest &+= 1
    }

    // MARK: Chips and @

    /// Backspace at the start of the composer: the last chip goes (the projects', then the reply).
    @discardableResult
    func removeLastChip() -> Bool {
        if !projects.isEmpty { projects.removeLast(); return true }
        if replyTo != nil { replyTo = nil; return true }
        return false
    }

    /// The @ word being typed at the end of the draft, if any ("…@look" → "look").
    static func mentionQuery(in text: String, caret: Int? = nil) -> String? { mention(in: text, caret: caret)?.query }

    /// The @ word the caret is in or just after (`caret`: UTF-16 offset, nil for the end): its range (the whole word, past
    /// the caret too) and what is typed between the @ and the caret. An @ inside a word (an email) is not one.
    static func mention(in text: String, caret: Int?) -> (range: Range<String.Index>, query: String)? {
        if let caret, caret < 0 { return nil }
        let utf16 = text.utf16
        let offset = min(caret ?? utf16.count, utf16.count)
        guard let caretIndex = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let at = text[..<caretIndex].lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let typed = text[text.index(after: at)..<caretIndex]
        guard !typed.contains(where: \.isWhitespace) else { return nil }
        let end = text[caretIndex...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        return (at..<end, String(typed))
    }

    /// Where the caret is in the composer (UTF-16 offset; nil: at the end), as its text view says: the @ suggestions follow it.
    var caret: Int? {
        didSet { if caret != oldValue { mentionChanged() } }
    }
    /// Asks the composer to put its caret here (after a pick replaced the @ word).
    var caretRequest: Int?

    /// Takes the caret from the composer's text view; a selection (not a caret) shows no suggestions.
    func followCaret(_ editor: NSTextView) {
        let range = editor.selectedRange()
        let at = range.length == 0 ? range.location : -1
        let next: Int? = at == (draft as NSString).length ? nil : at
        if caret != next { caret = next }
    }

    private func mentionChanged() {
        let query = Self.mentionQuery(in: draft, caret: caret)
        if query != dismissedMention { dismissedMention = nil }
        let next = query == dismissedMention ? nil : query
        if next != mention {
            mention = next
            mentionIndex = 0
        }
    }

    /// The projects the @ word matches, best first (all of them for a bare @); the ones already tagged left out.
    func suggestions(_ store: Store) -> [(folder: String, name: String)] {
        guard let query = mention else { return [] }
        let folders = store.knownFolders.filter { !$0.isEmpty && !projects.contains($0) }
        return RouterMentions.rank(folders.map { ($0, store.folderName($0)) }, query: query, limit: 6)
    }

    /// Return or Tab on a suggestion: the @ word becomes that project's chip.
    func pickMention(_ folder: String) {
        guard mention != nil, let found = Self.mention(in: draft, caret: caret) else { return }
        if !projects.contains(folder) { projects.append(folder) }
        let start = draft.utf16.distance(from: draft.utf16.startIndex, to: found.range.lowerBound.samePosition(in: draft.utf16)!)
        var text = draft
        var range = found.range
        // No double space where the word was.
        if range.upperBound < text.endIndex, text[range.upperBound] == " ",
           range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == " " {
            range = range.lowerBound..<text.index(after: range.upperBound)
        }
        text.removeSubrange(range)
        caret = start
        draft = text
        caretRequest = start
        mention = nil
    }

    /// Esc on the suggestions: they go until the @ word changes.
    func dismissMention() {
        dismissedMention = mention
        mention = nil
    }

    /// ↑↓ in the suggestions.
    func moveMention(down: Bool, count: Int) {
        guard count > 0 else { return }
        mentionIndex = (mentionIndex + (down ? 1 : count - 1)) % count
    }

    // MARK: Forms

    func picked(_ form: PendingForm, _ question: PendingForm.Question) -> [String] { picks[form.id]?[question.question] ?? [] }

    func otherText(_ form: PendingForm, _ question: PendingForm.Question) -> String { other[form.id]?[question.question] ?? "" }

    /// One choice picks it (and clears "Other"); several toggle.
    func pick(_ label: String, in question: PendingForm.Question, of form: PendingForm) {
        guard !locked(form) else { return }
        var current = picked(form, question)
        if question.multiSelect {
            if let i = current.firstIndex(of: label) { current.remove(at: i) } else { current.append(label) }
        } else {
            current = current == [label] ? [] : [label]
            other[form.id, default: [:]][question.question] = ""
        }
        picks[form.id, default: [:]][question.question] = current
        formErrors[form.id] = nil
    }

    /// Typing your own answer to a one-choice question unpicks the option.
    func setOther(_ text: String, in question: PendingForm.Question, of form: PendingForm) {
        guard !locked(form) else { return }
        other[form.id, default: [:]][question.question] = text
        if !question.multiSelect, !text.isEmpty { picks[form.id, default: [:]][question.question] = [] }
        formErrors[form.id] = nil
    }

    /// Every question's answer as the form takes it, or nil while one is missing.
    func answers(_ form: PendingForm) -> [String: String]? {
        var out: [String: String] = [:]
        for q in form.questions {
            let typed = otherText(form, q).trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = picked(form, q) + (typed.isEmpty ? [] : [typed])
            guard !labels.isEmpty else { return nil }
            out[q.question] = q.multiSelect ? FormBridge.joined(labels) : labels[0]
        }
        return out
    }

    /// Lookout writes the answer itself (the hook passes it on to the session).
    /// The file is written off the main thread; "Sent" or the error shows once it is.
    func sendAnswer(_ form: PendingForm, card: String, store: Store) {
        guard let answers = answers(form), !sending.contains(form.id), !sent.contains(form.id) else { return }
        sending.insert(form.id)
        lastWrite = Task { [weak self] in
            let result = await store.answerForm(form, answers, card: card)
            guard let self else { return }
            self.sending.remove(form.id)
            switch result {
            case .success:
                self.sent.insert(form.id)
                self.delivered[form.id] = answers
                self.formErrors[form.id] = nil
                Announce.say("Answer sent")
            case .failure(let error):
                self.formErrors[form.id] = error.localizedDescription
                Announce.say("Couldn't send the answer: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Window content

/// The Router window: the cards for you on the left, the chat on the right.
struct RouterView: View {
    let store: Store
    @Bindable var model: RouterModel
    /// Closes the window (the header's button and Esc share it).
    var close: () -> Void = {}
    /// Looks for Claude Code on showing (off in shots, which set what was found).
    var checksClaudeCode = true

    static let cardsWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            RouterCardsColumn(store: store, model: model)
                .frame(width: Self.cardsWidth)
            Hairline(axis: .vertical)
            RouterChatColumn(store: store, model: model, agent: store.routerAgent)
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
        .tipSpace()
        .task { if checksClaudeCode { await model.checkClaudeCode(store) } }
    }
}

/// "For you": the cards, open ones or all, newest first.
struct RouterCardsColumn: View {
    let store: Store
    @Bindable var model: RouterModel

    var body: some View {
        // Read once per change: the rows get their card, never the list.
        let cards = model.cards(store)
        let ids = cards.map(\.id)
        let counts = store.routerCounts
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("For you").font(Theme.Typography.title).accessibilityAddTraits(.isHeader)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
                Chip(label: "Open", count: counts.needsYou + counts.done, selected: !model.showAll) { model.showAll = false }
                    .tip("Open", "Cards still waiting on you")
                Chip(label: "All", selected: model.showAll) { model.showAll = true }
                    .tip("All", "Addressed cards too")
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(height: 44)
            Hairline()
            if cards.isEmpty {
                Text(model.showAll ? "No cards yet" : "Nothing needs you")
                    .font(Theme.Typography.body).foregroundStyle(Theme.tertiary)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // A plain stack (at most a few hundred cards): a lazy one guesses the heights of rows it hasn't made,
                        // and scrolling to a picked card it hasn't made yet can keep it laying out.
                        MinuteTicking { now in
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(cards) { card in
                                    RouterCardRow(card: card, store: store, model: model, now: now).id(card.id)
                                }
                            }
                        }
                        .padding(Theme.Space.md)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.scrollRequest) { _, request in
                        guard let request else { return }
                        withAnimation(Theme.Motion.hover.resolved(reduce: LookoutHub.reduceNow)) { proxy.scrollTo(request.id) }
                    }
                    .onAppear { if let id = model.selection { proxy.scrollTo(id) } }
                }
            }
        }
        // The pick follows what is listed (a filter change, a card addressed or superseded).
        .onChange(of: ids, initial: true) { model.reconcile(store: store) }
    }
}

/// One card in the window: its kind, project and age, the session, what it says; a question's form. Clicking it opens its
/// session in Claude (and picks it); the form's own controls answer without opening. Reply and Mark addressed show on hover
/// or when picked, and in its context menu.
struct RouterCardRow: View {
    let card: RouterCard
    let store: Store
    @Bindable var model: RouterModel
    var now = Date()
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var selected: Bool { model.selection == card.id }

    var body: some View {
        let project = store.routerProject(card)
        let form = card.isOpen ? store.pendingForm(for: card) : nil
        VStack(alignment: .leading, spacing: 4) {
            summary(project, form: form)
                .contentShape(Rectangle())
                .onTapGesture { open() }
            if let form {
                RouterFormView(form: form, card: card.id, store: store, model: model).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.Radius.shape(Theme.Radius.md).fill(selected ? Theme.Fill.selected : hover ? Theme.Fill.hover : Theme.Fill.rest))
        .overlay {
            if selected && contrast == .increased { Theme.Radius.shape(Theme.Radius.md).strokeBorder(Theme.text.opacity(0.6)) }
        }
        .overlay(alignment: .topTrailing) {
            if hover || selected { actions.padding(.top, 4).padding(.trailing, 4).transition(.opacity) }
        }
        .onHover { hover = $0 }
        .motion(Theme.Motion.hover, value: hover || selected)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.label): \(card.title)")
        .accessibilityValue(spokenValue(project.name))
        .accessibilityHint("Opens it in Claude")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "Reply") { model.reply(to: card.id, store: store) }
        .accessibilityAction(named: card.isOpen ? "Mark addressed" : "Reopen") { store.setCardAddressed(card.id, card.isOpen) }
    }

    /// Its session in Claude, and the card picked (the list has the keys from here: ↑↓ and Space act on the cards).
    private func open() {
        model.open(card.id, store: store)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    @ViewBuilder private func summary(_ project: (name: String, color: Color?), form: PendingForm?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                KindTag(kind: card.kind)
                ProjectLabel(name: project.name, color: project.color)
                    .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                Text(shortAgo(card.createdAt, now: now)).font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .opacity(hover || selected ? 0 : 1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(card.isOpen ? card.kind.color : .clear).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(card.title)
                    .font(card.isOpen ? Theme.Typography.bodyStrong : Theme.Typography.body)
                    .foregroundStyle(card.isOpen ? Theme.text : Theme.secondary)
                    .lineLimit(1)
            }
            // A form asking just what the card says says it itself.
            if form?.questions.map(\.question) != [card.text] {
                Text(RouterText.inline(card.text))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(card.isOpen ? Theme.secondary : Theme.tertiary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
            }
            if !card.isOpen, let by = card.addressedBy {
                Text(by.label).font(Theme.Typography.caption).foregroundStyle(Theme.tertiary).padding(.leading, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spokenValue(_ project: String) -> String {
        let age = AgentRow.spokenAge(now.timeIntervalSince(card.createdAt))
        let state = card.isOpen ? "open" : (card.addressedBy?.label ?? "addressed")
        return "\(project), \(state), \(card.text), \(age == "just now" ? age : age + " ago")"
    }

    private var actions: some View {
        let size = IconButton.Size.row
        return RowActions {
            IconButton(symbol: "arrowshape.turn.up.left", help: "Reply", detail: "Your next message goes to this session · Return",
                       size: size) {
                model.reply(to: card.id, store: store)
            }
            IconButton(symbol: card.isOpen ? "checkmark" : "arrow.uturn.backward", help: card.isOpen ? "Mark addressed" : "Reopen",
                       detail: "Space", size: size) {
                store.setCardAddressed(card.id, card.isOpen)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Reply") { model.reply(to: card.id, store: store) }
        Button(card.isOpen ? "Mark Addressed" : "Reopen") { store.setCardAddressed(card.id, card.isOpen) }
    }
}

/// A question's form, answered here: Lookout writes the answer and the hook gives it to the session, like a click in the app.
struct RouterFormView: View {
    let form: PendingForm
    let card: String
    let store: Store
    @Bindable var model: RouterModel

    var body: some View {
        Group {
            if let answers = model.delivered[form.id], model.sent.contains(form.id) { delivered(answers) } else { controls }
        }
        .padding(10)
        .background(Theme.Radius.shape(Theme.Radius.md).fill(Theme.Fill.faint))
        .overlay(Theme.Radius.shape(Theme.Radius.md).strokeBorder(Theme.stroke))
    }

    /// The questions with their options and "Other…"; all shut while the answer is being written.
    private var controls: some View {
        let locked = model.locked(form)
        let sending = model.sending.contains(form.id)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(form.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 5) {
                    if !question.header.isEmpty { Eyebrow(question.header) }
                    Text(question.question).font(Theme.Typography.bodyMedium).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 5) {
                        ForEach(question.options, id: \.label) { option in
                            OptionChip(label: option.label, detail: option.description, multi: question.multiSelect,
                                       selected: model.picked(form, question).contains(option.label)) {
                                model.pick(option.label, in: question, of: form)
                            }
                        }
                    }
                    TextField("Other…", text: Binding(get: { model.otherText(form, question) },
                                                      set: { model.setOther($0, in: question, of: form) }))
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.meta)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Theme.Radius.shape(Theme.Radius.sm).fill(Theme.Fill.field))
                        .accessibilityLabel("Other answer to \(question.question)")
                }
            }
            .disabled(locked)
            HStack(spacing: 8) {
                if let error = model.formErrors[form.id] {
                    Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ActionButton(sending ? "Sending…" : "Send answer") { model.sendAnswer(form, card: card, store: store) }
                    .disabled(model.answers(form) == nil || locked)
                    .tip("Send answer", "Answers the form in the session, as a click in Claude would")
            }
        }
    }

    /// Once sent: what was answered, to read, not to change.
    private func delivered(_ answers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(form.questions, id: \.question) { question in
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.question).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(answers[question.question] ?? "").font(Theme.Typography.bodyMedium).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Label("Sent", systemImage: "checkmark").font(Theme.Typography.control).foregroundStyle(Theme.green)
                .accessibilityLabel("Answer sent")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An option of a form's question: a capsule that is picked (filled) or not; several can be when the question allows it.
private struct OptionChip: View {
    let label: String
    let detail: String
    let multi: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if multi {
                    Image(systemName: selected ? "checkmark.square.fill" : "square").font(Theme.Typography.glyph(10))
                        .accessibilityHidden(true)
                }
                Text(label).lineLimit(1)
            }
            .font(Theme.Typography.control)
            .foregroundStyle(selected ? Theme.onTint : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(selected ? Theme.amber : Color.clear))
        }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), rest: Theme.Fill.hover, hover: Theme.Fill.selected))
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Picked" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(OptionTip(detail: detail, label: label))
    }
}

private struct OptionTip: ViewModifier {
    let detail: String
    let label: String

    @ViewBuilder func body(content: Content) -> some View {
        if detail.isEmpty { content } else { content.tip(label, detail) }
    }
}

// MARK: - Chat

/// The chat with the Router, then the status line and the composer; what's missing to use it, first.
struct RouterChatColumn: View {
    let store: Store
    @Bindable var model: RouterModel
    let agent: RouterAgent

    var body: some View {
        VStack(spacing: 0) {
            RouterSetupNotice(store: store, model: model, agent: agent)
            RouterChatList(store: store, agent: agent)
            Hairline()
            RouterStatusView(store: store)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.md)
            RouterComposer(store: store, model: model, agent: agent)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.md)
        }
    }
}

/// What stands in the way of using the Router, in one line, and the fix. Nothing when all is well.
struct RouterSetupNotice: View {
    let store: Store
    let model: RouterModel
    let agent: RouterAgent

    var body: some View {
        Group {
            if !store.agents.enabled {
                line("The Router works on your Claude sessions: the sessions extension is off.", color: Theme.amber,
                     action: Claude.isInstalled ? "Turn both on" : nil) {
                    store.setAgentsEnabled(true)
                    store.setRouterEnabled(true)
                }
            } else if !store.router.enabled {
                line("The Router is off.", color: Theme.amber, action: "Turn on") { store.setRouterEnabled(true) }
            } else if model.claudeCodeMissing == true && agent.claudeCode == nil {
                line("Claude Code wasn't found. Install or open the Claude desktop app.", color: Theme.amber,
                     action: "Look again") { Task { await model.checkClaudeCode(store) } }
            } else if let error = store.routerHookError {
                line("The form hook couldn't be installed: \(error)", color: Theme.red, action: nil) {}
            } else if case .failed(let reason) = agent.phase {
                line(reason, color: Theme.red, action: nil) {}
            }
        }
    }

    private func line(_ text: String, color: Color, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(color).accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action { ActionButton(action, action: perform) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .onAppear { Announce.say(text) }
    }
}

/// The conversation, newest at the bottom; one line saying what the Router does while it is empty.
struct RouterChatList: View {
    let store: Store
    let agent: RouterAgent

    var body: some View {
        let chat = store.router.chat
        let working = agent.phase == .working || agent.phase == .starting
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.isEmpty {
                        Text("Ask what needs you, answer a session or pass it a message, or start a new one. "
                             + "The Router only does what you say, and says what it did.")
                            .font(Theme.Typography.body).foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(chat) { RouterMessageView(message: $0, store: store).id($0.id) }
                    if working {
                        Text(agent.phase == .starting ? "Starting…" : "Working…")
                            .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                            .id("working")
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: working) { _, now in if now { proxy.scrollTo("working", anchor: .bottom) } }
        }
    }
}

/// One line of the chat: yours on the right, the Router's on the left, its actions as small receipts that link to the
/// session, errors in red, and what a session wrote back.
struct RouterMessageView: View {
    let message: RouterMessage
    let store: Store
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        switch message.role {
        case .you:
            VStack(alignment: .trailing, spacing: 4) {
                if message.replyTo != nil || !(message.projects ?? []).isEmpty { sentChips }
                youBubble
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You\(spokenChips): \(message.text)")
        case .router:
            Text(RouterText.inline(message.text))
                .font(Theme.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 60)
                .accessibilityLabel("Router: \(message.text)")
        case .receipt:
            receipt
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error: \(message.text)")
        case .peer:
            PeerMessageView(message: message, store: store, title: sessionTitle)
        }
    }

    private var sessionTitle: String? { message.sessionID.flatMap { store.claudeSessions[$0]?.title } }

    /// Your words, in their bubble.
    private var youBubble: some View {
        Text(message.text)
            .font(Theme.Typography.body)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.Radius.shape(Theme.Radius.lg).fill(Theme.Fill.selected))
            .overlay {
                if contrast == .increased { Theme.Radius.shape(Theme.Radius.lg).strokeBorder(Theme.text.opacity(0.5)) }
            }
            .padding(.leading, 80)
    }

    private var replyTitle: String? {
        message.replyTo.map { id in store.router.cards.first { $0.id == id }?.title ?? "a card" }
    }

    /// What went with your line: the card it replied to, the projects tagged.
    private var sentChips: some View {
        HStack(spacing: 4) {
            if let title = replyTitle {
                Label(title, systemImage: "arrowshape.turn.up.left.fill").labelStyle(.titleAndIcon)
            }
            ForEach(message.projects ?? [], id: \.self) { Text("@" + store.folderName($0)) }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.tertiary)
        .lineLimit(1)
    }

    private var spokenChips: String {
        var parts: [String] = []
        if let title = replyTitle { parts.append("replying to \(title)") }
        parts += (message.projects ?? []).map { "project \(store.folderName($0))" }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    private var receipt: some View { ReceiptView(message: message, store: store, title: sessionTitle) }
}

/// "→ lookout: first line", the arrow drawn rather than typed, then a link to the session it was about. A message Lookout
/// rephrased before sending (it named the session, or held parts for others) says so; your own words are on the mark's
/// tooltip, and under the line once it is clicked.
struct ReceiptView: View {
    let message: RouterMessage
    let store: Store
    let title: String?
    @State private var showsOriginal = false

    var body: some View {
        let text = message.text.hasPrefix("→") ? String(message.text.dropFirst()).trimmingCharacters(in: .whitespaces) : message.text
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(Theme.Typography.glyph(9, .bold)).foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
                Text(text).font(Theme.Typography.meta).foregroundStyle(Theme.secondary).lineLimit(2).textSelection(.enabled)
                if let original = message.original {
                    let mark = "rephrased"
                    Button { showsOriginal.toggle() } label: {
                        Text(mark).font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.purple)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(Capsule().fill(Theme.purple.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .tip(mark.capitalized, "You wrote: \(original)")
                    .accessibilityLabel(mark.capitalized)
                    .accessibilityValue("You wrote: \(original)")
                    .accessibilityHint(showsOriginal ? "Hides your words" : "Shows your words")
                }
                if let id = message.sessionID, store.claudeSessions[id] != nil {
                    Button("Open") { store.openAgent(id) }
                        .buttonStyle(.link).font(Theme.Typography.meta).foregroundStyle(Theme.accent)
                        .accessibilityLabel("Open \(title ?? "the session") in Claude")
                }
            }
            if showsOriginal, let original = message.original {
                Text("You wrote: \(original)").font(Theme.Typography.caption).foregroundStyle(Theme.tertiary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Done: \(text)")
    }
}

/// What a session wrote back to the Router, as it wrote it: its name with a link to it, the text cut to three lines with
/// More to read the rest.
struct PeerMessageView: View {
    let message: RouterMessage
    let store: Store
    let title: String?
    static let lines = 3
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        let name = title ?? "a session"
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(Theme.claude).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("From \(name)").font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    if let id = message.sessionID, store.claudeSessions[id] != nil {
                        Button("Open") { store.openAgent(id) }
                            .buttonStyle(.link).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                            .accessibilityLabel("Open \(name) in Claude")
                    }
                }
                Text(RouterText.inline(message.text)).font(Theme.Typography.body).textSelection(.enabled)
                    .lineLimit(expanded ? nil : Self.lines)
                    .fixedSize(horizontal: false, vertical: true)
                    // Whether three lines cut it: the same text laid out without a limit is taller.
                    .background {
                        Text(RouterText.inline(message.text)).font(Theme.Typography.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full in
                                let cut = full > Self.lineHeight * CGFloat(Self.lines) + 2
                                if truncated != cut { truncated = cut }
                            }
                    }
                if truncated {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }
                        .buttonStyle(.link).font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                        .accessibilityLabel(expanded ? "Show less of \(name)'s message" : "Show all of \(name)'s message")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 60)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("From \(name): \(message.text)")
    }

    /// One line of body text (12.5pt).
    static let lineHeight: CGFloat = 16
}

/// The projects an @ word matches: names that start with it first, then ones that contain it, then ones that hold its
/// letters in order (fuzzy); shorter names first within each.
enum RouterMentions {
    static func rank(_ projects: [(String, String)], query: String, limit: Int) -> [(folder: String, name: String)] {
        let q = query.lowercased()
        func score(_ name: String) -> Int? {
            let n = name.lowercased()
            if q.isEmpty || n.hasPrefix(q) { return 0 }
            if n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 1 }
            if n.contains(q) { return 2 }
            var rest = Substring(q)
            for c in n where c == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty ? 3 : nil
        }
        struct Hit { var folder: String; var name: String; var score: Int }
        var hits: [Hit] = []
        for (folder, name) in projects {
            if let s = score(name) { hits.append(Hit(folder: folder, name: name, score: s)) }
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name < b.name
        }
        return hits.prefix(limit).map { (folder: $0.folder, name: $0.name) }
    }
}
