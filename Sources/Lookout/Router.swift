import AppKit
import Foundation

// MARK: - Persisted state

/// The Router: one chat above the Claude sessions, and the cards for what needs you in them.
struct RouterState: Codable, Equatable {
    /// Off by default; only offered while the Claude sessions extension is on.
    var enabled = false
    var enabledAt: Date?
    /// Oldest first.
    var cards: [RouterCard] = []
    /// The conversation with the Router, oldest first.
    var chat: [RouterMessage] = []
    /// The Router's own Claude Code session, to resume it.
    var claudeSessionID: String?
    /// What the feed last saw of each session (see `RouterFeed.Stamp`): a change is an event, the same is not.
    var seen: [String: String] = [:]
    /// The question or plan each session is stopped on, by when it began (ms since 1970, exactly as the transcript says):
    /// a card is made once per wait.
    var waits: [String: Int64] = [:]
    /// The call (`tool_use` id) each of those waits is on, when the transcript said.
    var waitTools: [String: String] = [:]
    /// Waits whose form Lookout's hook was seen holding (session → the wait's ms): that form going away ends the wait.
    var formSeen: [String: Int64] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        enabledAt = try? c.decodeIfPresent(Date.self, forKey: .enabledAt)
        cards = (try? c.decodeIfPresent([RouterCard].self, forKey: .cards)) ?? []
        chat = (try? c.decodeIfPresent([RouterMessage].self, forKey: .chat)) ?? []
        claudeSessionID = try? c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        seen = (try? c.decodeIfPresent([String: String].self, forKey: .seen)) ?? [:]
        waits = (try? c.decodeIfPresent([String: Int64].self, forKey: .waits)) ?? [:]
        waitTools = (try? c.decodeIfPresent([String: String].self, forKey: .waitTools)) ?? [:]
        formSeen = (try? c.decodeIfPresent([String: Int64].self, forKey: .formSeen)) ?? [:]
    }
}

/// Something a session wants from you, open until it is addressed.
struct RouterCard: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Stopped on a question (AskUserQuestion).
        case question
        /// Stopped on a plan to approve (ExitPlanMode).
        case plan
        /// Finished its turn.
        case done
        /// Finished its turn, and its summary says it is blocked.
        case stuck

        /// Made when a turn ends (the others while one waits).
        var isTurn: Bool { self == .done || self == .stuck }
        /// Counted as needing you (amber); `done` is only news.
        var needsYou: Bool { self != .done }
    }

    /// How a card stopped being open.
    enum Addressed: String, Codable {
        /// By hand.
        case you
        /// You sent the session a message after the card.
        case reply
        /// The Router sent the session a message.
        case router
        /// The question or plan stopped waiting (answered here, in the app, anywhere).
        case answered
        /// You opened the session after a turn card.
        case opened
        /// A newer card for the same session.
        case superseded
        /// The session was archived or deleted.
        case gone
    }

    /// `<session>#t<completedTurns>` for a turn, `<session>#w<ms of the wait's start>` for a wait.
    var id: String
    var sessionID: String
    var kind: Kind
    var title: String
    var folder: String?
    var text: String
    /// When it was made, in ms since 1970: kept exactly (a date in the state file loses its fraction of a second), so a
    /// reply in the same second as the card is still told apart from one before it.
    var createdMs: Int64
    var addressedAt: Date?
    var addressedBy: Addressed?
    /// For a question or plan: the call it waits on (`tool_use` id), which ties it to the form Lookout's hook holds.
    var toolUseID: String?

    var createdAt: Date {
        get { Date(timeIntervalSince1970: Double(createdMs) / 1000) }
        set { createdMs = RouterFeed.Stamp.ms(newValue) }
    }

    var isOpen: Bool { addressedAt == nil }

    init(id: String, sessionID: String, kind: Kind, title: String, folder: String?, text: String, createdAt: Date,
         addressedAt: Date? = nil, addressedBy: Addressed? = nil, toolUseID: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.folder = folder
        self.text = text
        createdMs = RouterFeed.Stamp.ms(createdAt)
        self.addressedAt = addressedAt
        self.addressedBy = addressedBy
        self.toolUseID = toolUseID
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, kind, title, folder, text, createdMs, createdAt, addressedAt, addressedBy, toolUseID
    }

    /// Files from before `createdMs` have `createdAt` (a date) instead.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        if let ms = try? c.decode(Int64.self, forKey: .createdMs) {
            createdMs = ms
        } else {
            createdMs = RouterFeed.Stamp.ms(try c.decode(Date.self, forKey: .createdAt))
        }
        addressedAt = try c.decodeIfPresent(Date.self, forKey: .addressedAt)
        addressedBy = try c.decodeIfPresent(Addressed.self, forKey: .addressedBy)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encode(text, forKey: .text)
        try c.encode(createdMs, forKey: .createdMs)
        try c.encodeIfPresent(addressedAt, forKey: .addressedAt)
        try c.encodeIfPresent(addressedBy, forKey: .addressedBy)
        try c.encodeIfPresent(toolUseID, forKey: .toolUseID)
    }

    /// The wait a question or plan card was made for (ms since 1970), from its id.
    var waitMs: Int64? {
        guard !kind.isTurn, let range = id.range(of: "#w", options: .backwards) else { return nil }
        return Int64(id[range.upperBound...])
    }
}

/// A line of the Router chat.
struct RouterMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case you, router
        /// One line per action the Router took ("→ lookout: …").
        case receipt
        case error
        /// A session wrote back to the Router.
        case peer
    }

    var id = UUID()
    var role: Role
    var text: String
    var date: Date
    /// The session a receipt or a peer line is about.
    var sessionID: String?
    /// Your line: the card you replied to.
    var replyTo: String? = nil
    /// Your line: the projects you tagged (folder paths).
    var projects: [String]? = nil
    /// A receipt of a message Lookout rephrased before sending: what you wrote (the receipt says what was sent).
    var original: String? = nil
}

extension RouterMessage {
    /// Lenient: a line that can't be read in full keeps what it can (the fields added later are optional).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        replyTo = try? c.decodeIfPresent(String.self, forKey: .replyTo)
        projects = try? c.decodeIfPresent([String].self, forKey: .projects)
        original = try? c.decodeIfPresent(String.self, forKey: .original)
    }
}


// MARK: - Feed

/// Turns reads of the sessions into cards. Pure: the same reads give the same cards, so the rules are tested here.
enum RouterFeed {
    /// What a turn card says until the app writes the turn's summary.
    static let placeholder = "Finished its turn"
    static let maxCards = 300
    static let maxChat = 500

    /// What changes in a session that the rules care about: turns finished, your last message, when you last opened it.
    struct Stamp: Equatable {
        var turns: Int
        var message: Int64?
        var focus: Int64?

        init(_ session: ClaudeSession) {
            turns = session.completedTurns
            message = session.lastUserMessage.map(Self.ms)
            focus = session.lastFocused.map(Self.ms)
        }

        init?(_ text: String) {
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, let turns = Int(parts[0]) else { return nil }
            self.turns = turns
            message = Int64(parts[1])
            focus = Int64(parts[2])
        }

        var text: String { "\(turns)|\(message.map(String.init) ?? "")|\(focus.map(String.init) ?? "")" }

        /// Dates come from files: one too far out (or not a number) is clamped rather than trapping the conversion.
        static func ms(_ date: Date) -> Int64 {
            let value = (date.timeIntervalSince1970 * 1000).rounded()
            guard value.isFinite else { return 0 }
            return Int64(max(-9e18, min(9e18, value)))
        }
    }

    /// A wait as the transcript shows it: when it began, the call, what kind of card it makes, and its text.
    private struct Wait {
        var ms: Int64
        var toolUseID: String?
        var kind: RouterCard.Kind
        var text: String
    }

    private static func wait(_ activity: ClaudeActivity) -> Wait? {
        guard activity.waitsForYou else { return nil }
        let ms = Stamp.ms(activity.since)
        if activity.tool == "ExitPlanMode" {
            // The card says the plan's title; the row's "Approve the plan: " is the kind tag's job.
            let prefix = "Approve the plan: "
            let text = activity.text.hasPrefix(prefix) ? String(activity.text.dropFirst(prefix.count)) : activity.text
            return Wait(ms: ms, toolUseID: activity.toolUseID, kind: .plan, text: text)
        }
        return Wait(ms: ms, toolUseID: activity.toolUseID, kind: .question, text: activity.text)
    }

    /// Whether a known wait is over, on evidence only: the transcript of the running session moved past its call, the turn
    /// finished (a summary is written once it has), or the form Lookout's hook held for it went away. A session that merely
    /// stopped counting as running (two hours on, the app quit, nothing read yet) is still waiting.
    private static func waitEnded(_ state: RouterState, _ session: ClaudeSession, ms: Int64, toolUseID: String?,
                                  activity: ClaudeActivity?, forms: [String: Set<String>]?) -> Bool {
        if session.running, let activity, wait(activity)?.ms != ms { return true }
        if session.summary != nil { return true }
        if let forms, state.formSeen[session.id] == ms, let toolUseID, forms[session.id]?.contains(toolUseID) != true { return true }
        return false
    }

    /// `forms`: the calls (`tool_use` ids) whose forms Lookout's hook holds, by desktop session; nil until the forms folder
    /// has been read.
    static func update(_ state: inout RouterState, sessions: [ClaudeSession], activity: [String: ClaudeActivity],
                       muted: Set<String>, viewing: String?, forms: [String: Set<String>]? = nil, now: Date) {
        let live = Dictionary(sessions.filter { !$0.isArchived }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for i in state.cards.indices where state.cards[i].isOpen && live[state.cards[i].sessionID] == nil {
            state.cards[i].addressedAt = now
            state.cards[i].addressedBy = .gone
        }

        for session in live.values.sorted(by: { $0.id < $1.id }) {
            let id = session.id
            let stamp = Stamp(session)
            let before = state.seen[id].flatMap(Stamp.init)
            let previous = state.waits[id]
            let read = session.running ? activity[id] : nil
            let current = read.flatMap(wait)
            var ongoing = previous
            if let previous {
                let moved = before.map { stamp.message != $0.message || stamp.turns > $0.turns } ?? false
                if moved || waitEnded(state, session, ms: previous, toolUseID: state.waitTools[id], activity: read, forms: forms) {
                    ongoing = nil
                }
            }
            if let current { ongoing = current.ms }

            // First sight: only what it is now, so turning the Router on doesn't bring the backlog.
            if let before {
                // What addresses the cards there are, before any new one is made (a new one is newer than all of it).
                if stamp.message != before.message, let message = stamp.message {
                    address(&state, id, .reply, now) { message > $0.createdMs }
                }
                if stamp.focus != before.focus, let focused = stamp.focus {
                    address(&state, id, .opened, now) { $0.kind.isTurn && focused > $0.createdMs }
                }
                if let previous, ongoing != previous {
                    address(&state, id, .answered, now) { !$0.kind.isTurn }
                }

                // No card for what you watched happen in the app, nor for muted projects.
                let quiet = id == viewing || muted.contains(session.folderKey)
                if session.completedTurns > before.turns, !quiet {
                    let blocked = session.summary?.blocked == true
                    let detail = session.summary?.detail ?? ""
                    add(&state, RouterCard(id: "\(id)#t\(session.completedTurns)", sessionID: id,
                                           kind: blocked ? .stuck : .done, title: session.title, folder: session.folder,
                                           text: detail.isEmpty ? placeholder : detail, createdAt: now), now)
                }
                if let current, current.ms != previous, !quiet {
                    add(&state, RouterCard(id: "\(id)#w\(current.ms)", sessionID: id, kind: current.kind, title: session.title,
                                           folder: session.folder, text: current.text, createdAt: now, toolUseID: current.toolUseID), now)
                }
            }

            state.waits[id] = ongoing
            if ongoing == nil {
                state.waitTools[id] = nil
            } else if ongoing != previous {
                state.waitTools[id] = current?.toolUseID
            } else if let tool = current?.toolUseID {
                state.waitTools[id] = tool
            }
            if let ongoing, let tool = state.waitTools[id], forms?[id]?.contains(tool) == true {
                state.formSeen[id] = ongoing
            } else if state.formSeen[id] != nil, state.formSeen[id] != ongoing {
                state.formSeen[id] = nil
            }

            // The summary is written after the turn ends: the open card of that turn takes it when it comes.
            if let summary = session.summary,
               let i = state.cards.firstIndex(where: { $0.id == "\(id)#t\(session.completedTurns)" && $0.isOpen }) {
                let kind: RouterCard.Kind = summary.blocked ? .stuck : .done
                let text = summary.detail.isEmpty ? placeholder : summary.detail
                if state.cards[i].kind != kind { state.cards[i].kind = kind }
                if state.cards[i].text != text { state.cards[i].text = text }
            }
            // Open cards follow a renamed session.
            for i in state.cards.indices where state.cards[i].sessionID == id && state.cards[i].isOpen
                && state.cards[i].title != session.title {
                state.cards[i].title = session.title
            }
            state.seen[id] = stamp.text
        }

        // Sessions that are gone are forgotten: one that comes back is seen for the first time again.
        state.seen = state.seen.filter { live[$0.key] != nil }
        state.waits = state.waits.filter { live[$0.key] != nil }
        state.waitTools = state.waitTools.filter { live[$0.key] != nil }
        state.formSeen = state.formSeen.filter { live[$0.key] != nil }
        prune(&state)
    }

    /// Turning the Router on again: what happened to the open cards while it was off is judged from how things are now
    /// (there are no edges to go by). The waits that survive are kept; the sessions are then seen for the first time again.
    static func reconcile(_ state: inout RouterState, sessions: [ClaudeSession], activity: [String: ClaudeActivity],
                          forms: [String: Set<String>]? = nil, now: Date) {
        let live = Dictionary(sessions.filter { !$0.isArchived }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // What changed since the feed last looked, from the stamps saved then (cleared below): a turn that finished while it
        // was off ends its wait even before the app writes the summary.
        func moved(_ session: ClaudeSession) -> (turns: Bool, message: Bool) {
            guard let before = state.seen[session.id].flatMap(Stamp.init) else { return (false, false) }
            let now = Stamp(session)
            return (now.turns > before.turns, now.message != before.message)
        }
        for i in state.cards.indices where state.cards[i].isOpen {
            let card = state.cards[i]
            var by: RouterCard.Addressed?
            if let session = live[card.sessionID] {
                let stamp = Stamp(session)
                let change = moved(session)
                if let message = stamp.message, message > card.createdMs || (change.message && !card.kind.isTurn) {
                    by = .reply
                } else if !card.kind.isTurn, change.turns {
                    by = .answered
                } else if card.kind.isTurn, let focused = stamp.focus, focused > card.createdMs {
                    by = .opened
                } else if !card.kind.isTurn, let ms = card.waitMs,
                          state.waits[session.id] != ms
                            || waitEnded(state, session, ms: ms, toolUseID: card.toolUseID, activity: activity[session.id], forms: forms) {
                    by = .answered
                }
            } else {
                by = .gone
            }
            if let by {
                state.cards[i].addressedAt = now
                state.cards[i].addressedBy = by
            }
        }
        // A wait whose card was just settled is over.
        for (id, ms) in state.waits where !state.cards.contains(where: { $0.sessionID == id && $0.isOpen && $0.waitMs == ms }) {
            if let session = live[id], !waitEnded(state, session, ms: ms, toolUseID: state.waitTools[id], activity: activity[id], forms: forms),
               session.lastUserMessage.map({ Stamp.ms($0) <= ms }) ?? true, moved(session) == (false, false) {
                continue
            }
            state.waits[id] = nil
            state.waitTools[id] = nil
            state.formSeen[id] = nil
        }
        state.seen = [:]
    }

    /// Addresses the open cards of a session that `matches`.
    static func address(_ state: inout RouterState, _ sessionID: String, _ by: RouterCard.Addressed, _ now: Date,
                        where matches: (RouterCard) -> Bool = { _ in true }) {
        for i in state.cards.indices where state.cards[i].sessionID == sessionID && state.cards[i].isOpen && matches(state.cards[i]) {
            state.cards[i].addressedAt = now
            state.cards[i].addressedBy = by
        }
    }

    /// Opens a card again by hand. One open card per session: the session's others are superseded.
    static func reopen(_ state: inout RouterState, _ id: String, now: Date) {
        guard let i = state.cards.firstIndex(where: { $0.id == id }), !state.cards[i].isOpen else { return }
        address(&state, state.cards[i].sessionID, .superseded, now) { $0.id != id }
        state.cards[i].addressedAt = nil
        state.cards[i].addressedBy = nil
    }

    /// One open card per session: a new one supersedes the others. A card made before (and reopened, or addressed) is
    /// not made twice.
    private static func add(_ state: inout RouterState, _ card: RouterCard, _ now: Date) {
        guard !state.cards.contains(where: { $0.id == card.id }) else { return }
        address(&state, card.sessionID, .superseded, now)
        state.cards.append(card)
    }

    /// Keeps the file small: the oldest addressed cards go first, then the oldest open ones; the chat keeps its latest lines.
    static func prune(_ state: inout RouterState) {
        if state.cards.count > maxCards {
            var excess = state.cards.count - maxCards
            let addressed = state.cards.enumerated().filter { !$0.element.isOpen }
                .sorted { $0.element.createdAt < $1.element.createdAt }.prefix(excess).map(\.offset)
            var drop = Set(addressed)
            excess -= drop.count
            if excess > 0 {
                drop.formUnion(state.cards.enumerated().filter { $0.element.isOpen }
                    .sorted { $0.element.createdAt < $1.element.createdAt }.prefix(excess).map(\.offset))
            }
            state.cards = state.cards.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        if state.chat.count > maxChat { state.chat.removeFirst(state.chat.count - maxChat) }
    }
}

// MARK: - Store

extension Store {
    /// Open cards first, newest first in each part.
    var routerCards: [RouterCard] {
        router.cards.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
        }
    }

    var openRouterCards: [RouterCard] { routerCards.filter(\.isOpen) }

    /// Open cards that need you (questions, plans, stuck turns) and open finished turns.
    var routerCounts: (needsYou: Int, done: Int) {
        let open = router.cards.filter(\.isOpen)
        let needsYou = open.filter { $0.kind.needsYou }.count
        return (needsYou, open.count - needsYou)
    }

    /// The form Lookout's hook holds for this card's own question: the one for the very call the card waits on (an older
    /// card never shows a newer question's form, nor a card a form whose call isn't known yet).
    func pendingForm(for card: RouterCard) -> PendingForm? {
        guard card.kind == .question, card.isOpen, let call = card.toolUseID,
              let cli = claudeSessions[card.sessionID]?.cliID, let form = pendingForms[cli], form.toolUseID == call else { return nil }
        return form
    }

    /// The calls whose forms Lookout's hook holds, by desktop session; nil until the forms folder has been read.
    var heldForms: [String: Set<String>]? {
        guard routerFormsLoaded else { return nil }
        var held: [String: Set<String>] = [:]
        guard !pendingForms.isEmpty else { return held }
        for session in claudeSessions.values {
            if let cli = session.cliID, let call = pendingForms[cli]?.toolUseID { held[session.id, default: []].insert(call) }
        }
        return held
    }

    /// The session shown in the app right now: the most recently focused one, if the app is in front. Asked afresh each
    /// time: the app may have gone to the back since the last read.
    var viewingNow: String? {
        guard claudeIsFrontmost() else { return nil }
        return claudeSessions.values.filter { !$0.isArchived }
            .max { ($0.lastFocused ?? .distantPast) < ($1.lastFocused ?? .distantPast) }?.id
    }

    /// Runs the feed on what was read last. Only while both the Router and the sessions extension are on, and once the
    /// app's sessions have been read (before that, every card would look gone).
    func feedRouter(now: Date = Date()) {
        guard router.enabled, agents.enabled, claudeLink == .ok else { return }
        var state = router
        let forms = heldForms
        if routerReconcilePending {
            routerReconcilePending = false
            RouterFeed.reconcile(&state, sessions: Array(claudeSessions.values), activity: claudeActivity, forms: forms, now: now)
        }
        RouterFeed.update(&state, sessions: Array(claudeSessions.values), activity: claudeActivity,
                          muted: Set(agents.mutedFolders), viewing: viewingNow, forms: forms, now: now)
        guard state != router else { return }
        let known = Set(router.cards.map(\.id))
        router = state
        let fresh = state.cards.filter { $0.isOpen && !known.contains($0.id) }
        if !fresh.isEmpty { onNewRouterCards?(fresh) }
    }

    /// By hand: addressed, or open again (which supersedes the session's other open cards).
    func setCardAddressed(_ id: String, _ addressed: Bool, now: Date = Date()) {
        guard let card = router.cards.first(where: { $0.id == id }), card.isOpen == addressed else { return }
        var state = router
        if addressed {
            RouterFeed.address(&state, card.sessionID, .you, now) { $0.id == id }
        } else {
            RouterFeed.reopen(&state, id, now: now)
        }
        router = state
    }

    /// Opens the card's session in Claude; a finished turn has then been seen.
    func openCard(_ id: String, now: Date = Date()) {
        guard let card = router.cards.first(where: { $0.id == id }) else { return }
        openAgent(card.sessionID)
        guard card.isOpen, card.kind.isTurn else { return }
        var state = router
        RouterFeed.address(&state, card.sessionID, .opened, now) { $0.id == id }
        router = state
    }

    /// Every open card of a session (the Router sent it a message, say).
    func addressCards(forSession sessionID: String, by: RouterCard.Addressed, now: Date = Date()) {
        var state = router
        RouterFeed.address(&state, sessionID, by, now)
        if state != router { router = state }
    }

    // MARK: Switching it

    /// The hook, the forms folder and the feed follow the toggle. Installing touches `~/.claude/settings.json`, so it
    /// happens off the main thread; `routerHookError` says why it failed.
    func setRouterEnabled(_ on: Bool, now: Date = Date()) {
        guard on != router.enabled else { return }
        var state = router
        state.enabled = on
        if on {
            state.enabledAt = state.enabledAt ?? now
            // What happened while it was off settles the open cards first (see `RouterFeed.reconcile`).
            routerReconcilePending = true
        }
        router = state
        applyRouterSwitch(install: true)
        if on { feedRouter(now: now) }
    }

    /// At launch: the forms folder and its watcher, and the hook again if the app moved since it was installed.
    func startRouter() {
        guard router.enabled else { return }
        applyRouterSwitch(install: false)
    }

    /// Where the Router's files are, when they may be touched at all: never in a demo, and in a test only where the test said.
    var routerFiles: RouterPaths? {
        if let routerPaths { return routerPaths }
        guard persists, !Store.isDemo else { return nil }
        return RouterPaths.live()
    }

    /// `install` true: install or uninstall as the toggle says. False (launch): re-install only an outdated hook, and the
    /// plugin when it's outdated or missing.
    private func applyRouterSwitch(install: Bool) {
        let on = router.enabled
        guard let paths = routerFiles else { return }
        observePluginQuit()
        // The key goes the moment the Router is switched off, whatever the CLI does next; a switch-on still under way is
        // fenced off from making it again.
        let generation: Int
        if on {
            generation = relayKeyFence.advance()
        } else {
            relayKeyFence.revoke(paths.relayKey, presence: paths.pluginSessions)
            generation = relayKeyFence.current
            relayKeyCache = nil
        }
        if on {
            formBridge.start(dir: paths.forms) { [weak self] forms in
                guard let self, self.router.enabled else { return }
                let first = !self.routerFormsLoaded
                self.routerFormsLoaded = true
                guard first || forms != self.pendingForms else { return }
                if forms != self.pendingForms { self.pendingForms = forms }
                // A form going away ends its wait (answered, or its hook gave up).
                self.feedRouter()
            }
        } else {
            formBridge.stop()
            routerFormsLoaded = false
            if !pendingForms.isEmpty { pendingForms = [:] }
        }
        let executable = routerExecutable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
        let runner = routerPluginRunner ?? (UnderTest.isRunning ? nil : ClaudePluginInstaller.processRunner)
        let findBinary = routerClaudeBinary ?? { RouterAgent.find(in: Claude.root.appendingPathComponent("claude-code", isDirectory: true))?.path }
        let version = ClaudePlugin.version(app: routerAppVersion)
        let previous = routerHookWork
        routerHookWork = Task { [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .utility) { () -> (FormHookInstaller.Status, String?) in
                let installer = FormHookInstaller(claudeDir: paths.claudeDir)
                do {
                    try FormBridge.setEnabled(on, dir: paths.forms)
                    if on {
                        if install || installer.status(executable: executable) == .outdated {
                            try installer.install(executable: executable)
                        }
                    } else if install {
                        try installer.uninstall()
                    }
                    return (installer.status(executable: executable), nil)
                } catch {
                    return (installer.status(executable: executable), error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if self.routerHookStatus != result.0 { self.routerHookStatus = result.0 }
            if self.routerHookError != result.1 { self.routerHookError = result.1 }
            guard let runner else { return }
            let fence = self.relayKeyFence
            let plugin = await Self.switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: findBinary,
                                                    run: runner, fence: fence, generation: generation)
            if self.routerPluginStatus != plugin.status { self.routerPluginStatus = plugin.status }
            if self.routerPluginError != plugin.error { self.routerPluginError = plugin.error }
            if let key = plugin.key, fence.current == generation { self.relayKeyCache = key }
        }
    }

    /// Quitting stops the installer's runs of the CLI (each is ended and its exit confirmed).
    private func observePluginQuit() {
        guard pluginQuitObserver == nil else { return }
        pluginQuitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                    queue: .main) { _ in PluginRuns.shared.shutdown() }
    }

    struct PluginSwitch: Sendable {
        var status: ClaudePluginInstaller.Status?
        var error: String?
        /// The key, read off the main thread, for `signRelay`.
        var key: RelayKeyCache?
    }

    /// On (unless a later switch superseded it): the folder is written at this version, the key made once (fenced: see
    /// `RelayKeyFence`), and Claude Code brought to the folder; at launch only when its plugin is missing or outdated.
    /// Off: the plugin and its marketplace are taken out (the key went already, at the switch).
    /// Runs off the main thread, finding Claude Code there too (`findBinary` walks folders).
    nonisolated static func switchPluginNow(on: Bool, install: Bool, paths: RouterPaths, version: String,
                                            findBinary: @escaping @Sendable () -> String?,
                                            run: @escaping ClaudePluginInstaller.Runner, fence: RelayKeyFence,
                                            generation: Int) async -> PluginSwitch {
        let installer = ClaudePluginInstaller(folder: paths.plugin, binary: findBinary(), run: run)
        do {
            if on {
                guard fence.current == generation else { return PluginSwitch(status: try? await installer.status(version: version)) }
                try ClaudePlugin.write(to: paths.plugin, version: version, presence: paths.pluginSessions, key: paths.relayKey,
                                       registry: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true))
                try fence.ifCurrent(generation) { try ClaudePlugin.ensureKey(at: paths.relayKey) }
                let key = RelayKeyCache.load(paths.relayKey)
                let status = try await installer.status(version: version)
                if install || status == .notInstalled || status == .outdated {
                    try await installer.install(version: version)
                }
                return PluginSwitch(status: try await installer.status(version: version), key: key)
            } else if install {
                try await installer.uninstall()
            }
            return PluginSwitch(status: try await installer.status(version: version))
        } catch {
            return PluginSwitch(status: try? await installer.status(version: version), error: error.localizedDescription)
        }
    }

    /// `switchPluginNow` for a caller that can't wait: blocks its thread until done. Call it off the main thread.
    nonisolated static func switchPlugin(on: Bool, install: Bool, paths: RouterPaths, version: String, binary: String?,
                                         run: @escaping ClaudePluginInstaller.Runner) -> (ClaudePluginInstaller.Status?, String?) {
        final class Box: @unchecked Sendable { var value = PluginSwitch() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let fence = RelayKeyFence()
        let generation = fence.current
        Task.detached {
            box.value = await switchPluginNow(on: on, install: install, paths: paths, version: version, findBinary: { binary },
                                              run: run, fence: fence, generation: generation)
            done.signal()
        }
        done.wait()
        return (box.value.status, box.value.error)
    }

    // MARK: Relaying as the person

    /// The CLI session ids of the sessions Lookout's plugin runs in now (only those can take a message as the person's own):
    /// its presence files under the current key, each bound to a live process Claude Code still registers for that session.
    /// Reads the registry and the presence folder: call it off the main thread.
    nonisolated func sessionsWithPlugin(paths: RouterPaths, keyID: String?) -> Set<String> {
        ClaudePlugin.sessions(in: paths.pluginSessions,
                              registry: ClaudePeers.registry(dir: paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)),
                              keyID: keyID)
    }

    /// `sessionsWithPlugin(paths:keyID:)` for the Router's own files and the key as last read.
    func sessionsWithPlugin() -> Set<String> {
        guard let paths = routerFiles else { return [] }
        return sessionsWithPlugin(paths: paths, keyID: relayKeyCache?.keyID)
    }

    /// `body` signed for the session whose CLI session id is `target`, ready to send as it is; nil when there's no key (the
    /// Router is off, or not set up yet). The key is read off the main thread (by the switch, or `reloadRelayKey`) and used
    /// while its file is the same; here only a stat is made. A key not read yet, or changed, is read again in the
    /// background, and nil is returned meanwhile.
    func signRelay(body: String, target: String) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.sign(body: body, target: target, key: cached.key)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }

    /// Reads the key off the main thread; kept only if no switch came meanwhile. True when there is one.
    @discardableResult
    func reloadRelayKey() async -> Bool {
        guard let paths = routerFiles else { return false }
        let generation = relayKeyFence.current
        // On a queue of its own, not Swift's pool: a busy pool must not hold a message waiting for its key.
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<RelayKeyCache?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: RelayKeyCache.load(paths.relayKey)) }
        }
        guard relayKeyFence.current == generation else { return false }
        if relayKeyCache != loaded { relayKeyCache = loaded }
        return loaded != nil
    }
}
