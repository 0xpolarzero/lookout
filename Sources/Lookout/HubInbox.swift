import AppKit
import SwiftUI

// The inbox: its cell in the bar, header, tabs, search, empty states and list. The rows are in InboxRow.swift.

/// The inbox header's own state: the search field (open from ⌘F, the magnifier or typing, and while it has a query)
/// and whether the list has scrolled under the header.
@Observable
@MainActor
final class InboxState {
    var searchOpen = false
    /// Mirrors the field's focus, for the key monitor, which leaves a focused field alone.
    var searchFocused = false
    /// Bumped to ask the field for focus.
    var focusRequest = 0
    /// The next focus is the typing's own: the key monitor put a first character in the field, so the caret goes after
    /// it. Any other focus (a click, ⌘F, the magnifier) keeps what the field and the pointer decide.
    var caretAtEnd = false
    var scrolled = false
    /// The rows below the last whole row a list cut short shows (what its `+N more` line says).
    var hiddenBelow = 0
    /// The list is cut and there is no room under it for the `+N more` line, so the header says it (`InboxHeaderCue`).
    var cueInHeader = false

    func startSearch(seeded: Bool = false) {
        searchOpen = true
        if seeded { caretAtEnd = true }
        focusRequest &+= 1
    }

    func endSearch() {
        searchOpen = false
        searchFocused = false
        caretAtEnd = false
    }
}

extension HubState {
    /// The one way into search (⌘F, the magnifier, typing): the results are the inbox's and the sessions', side by side,
    /// so it keeps the hub open (from a peek, which shows one section), gives up any section focus (which would
    /// shrink one of them or leave the field out), then asks the field for the keyboard.
    func beginSearch(seeded: Bool = false) {
        LookoutHub.animate(LookoutHub.refocus) {
            if !pinned { pinned = true }
            focus = nil
            inbox.startSearch(seeded: seeded)
        }
    }

    /// Picks a row from the keyboard (or nothing): the lists follow it.
    func pick(_ target: String?, ui: UIState) {
        selection = target
        if let target { requestScroll(target) } else { keyboardSelection = nil }
        ui.drawerSelection = target.flatMap { $0.hasPrefix("a:") ? String($0.dropFirst(2)) : nil }
    }

    /// The results changed under the typing: the pick stays if it is still shown, else it moves to the first result,
    /// so ↩ never opens a row that has gone from the list.
    func reconcileSelection(among targets: [String], ui: UIState) {
        guard !query.isEmpty, !targets.contains(selection ?? "") else { return }
        pick(targets.first, ui: ui)
    }
}

extension Store {
    /// Every row the arrows walk through, top to bottom: the inbox's, then the sessions'.
    func hubTargets(_ hub: HubState) -> [String] {
        hubItems(hub).map { "i:" + $0.id } + hub.ciTargets(self) + hubSessions(hub).map { "a:" + $0.id }
    }
}

/// Why the inbox has nothing to list, in the order DESIGN.md 5.9 gives them: the first that applies wins.
enum InboxEmpty: Equatable {
    case signedOut, noRepos, firstSync
    /// Needs you is empty and syncing is healthy, so it is true.
    case caughtUp
    /// Needs you is empty but something is wrong with syncing: no claim is made.
    case nothingNew
    case botsQuiet, doneEmpty
}

/// What to tell above the list while it stays: one at a time, the most pressing first.
enum InboxNotice: Equatable {
    case reposFailed(Int)
    case reviewRequestsFailed
    case reviewRequestsCut
    case rateLimited(until: Date?)
    case snoozed(until: Date)

    var message: String {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        return switch self {
        case .reposFailed(let n): "\(plural(n, "repository", "repositories")) didn't sync"
        case .reviewRequestsFailed: "Review requests didn't sync"
        case .reviewRequestsCut: SyncFault.reviewRequestsCut.phrase
        case .rateLimited(let until?): "GitHub is rate limiting. Checking again at \(time(until))."
        case .rateLimited: "GitHub is rate limiting. Checking again soon."
        case .snoozed(let until): "Snoozed until \(time(until))"
        }
    }
}

extension Store {
    /// What replaces the list whatever rows it has: a sign-in problem leaves the cached rows stale, so they aren't shown.
    var inboxReplacement: InboxEmpty? { authError != nil ? .signedOut : nil }

    /// Whether review requests are on and the last search for them failed.
    var reviewRequestsFailing: Bool { settings.reviewRequests && reviewRequestsError != nil }

    /// Whether review requests are on and the last search found only some of them.
    var reviewRequestsPartial: Bool { settings.reviewRequests && reviewRequestsIncomplete }

    /// The cause to show when the list under `filter` is empty.
    func inboxEmpty(_ filter: InboxFilter, now: Date = Date()) -> InboxEmpty {
        if let replacement = inboxReplacement { return replacement }
        if repos.isEmpty { return .noRepos }
        if lastSync == nil { return .firstSync }
        switch filter {
        case .needsYou:
            // Every source checked: the repositories (and the quota they need) and the review-request search.
            let healthy = repoErrors.isEmpty && !rateLimited && !reviewRequestsFailing && !reviewRequestsPartial
                && !isStale(at: now) && !isCIStale(at: now)
            return healthy ? .caughtUp : .nothingNew
        case .bots: return .botsQuiet
        case .done: return .doneEmpty
        }
    }

    /// The banner above the list, if any. Not with a sign-in problem or nothing watched: those replace the list.
    func inboxNotice(now: Date = Date()) -> InboxNotice? {
        guard authError == nil, !repos.isEmpty else { return nil }
        if !repoErrors.isEmpty { return .reposFailed(repoErrors.count) }
        if rateLimited { return .rateLimited(until: rateResetsAt.flatMap { $0 > now ? $0 : nil }) }
        if reviewRequestsFailing { return .reviewRequestsFailed }
        if reviewRequestsPartial { return .reviewRequestsCut }
        if isSnoozed, let until = settings.snoozeUntil { return .snoozed(until: until) }
        return nil
    }
}

extension LookoutHub {
    // MARK: Inbox

    // MARK: Header

    /// 36pt: the tabs, then search and the menu (their room is kept when the list is empty); typing, or ⌘F, swaps
    /// the tabs for the search field.
    @ViewBuilder var inboxHeader: some View {
        Group {
            if hub.inbox.searchOpen || searching { searchField.transition(.opacity) } else { filters.transition(.opacity) }
        }
        .frame(height: Theme.Metrics.pitch)
        // A hairline once the list has scrolled under it.
        .overlay(alignment: .bottom) { if hub.inbox.scrolled { Hairline().transition(.opacity) } }
        .motion(Theme.Motion.fade, value: hub.inbox.scrolled)
    }

    var searchField: some View {
        InboxSearchField(hub: hub, ui: ui, summary: searchCount, targets: store.hubTargets(hub))
    }

    /// What the search found, by kind, each group counted even at none: "3 items · 0 sessions".
    var searchCount: String {
        let found = items.count
        let sessions = store.hubSessions(hub).count
        if found == 0 && sessions == 0 { return "No match" }
        return [plural(found, "item"), store.agents.enabled ? plural(sessions, "session") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The search shows two groups, Inbox and Sessions, each under its own label with its count.
    var searchGroups: Bool { searching && store.agents.enabled && store.inboxReplacement == nil }

    /// Neither group has a result: one "No match" says so, in place of the groups' own lines.
    var searchFoundNothing: Bool { searching && items.isEmpty && store.hubSessions(hub).isEmpty }

    /// One of the two groups found nothing: it is a line saying so ("Inbox 0 · No items match") and the other has the whole
    /// body, which a column of its own would waste half of on a line. Both empty is `searchFoundNothing`'s one "No match".
    var searchSpansBody: Bool { searchGroups && !searchFoundNothing && (items.isEmpty || store.hubSessions(hub).isEmpty) }

    /// Whether the sessions' section is in the layout: the extension is on, and a search that found nothing in either group
    /// has no half-empty Sessions under its "No match".
    var showsSessions: Bool { store.agents.enabled && !searchFoundNothing }

    /// The extension is on and Claude has no sessions to list (a peek leaves this out: its header and New session say it).
    var noClaudeSessions: Bool { store.agents.enabled && !searching && store.sessionGroups.isEmpty }

    var noClaudeSessionsLine: some View { quietLine("No Claude sessions") }

    private func quietLine(_ text: String) -> some View {
        Text(text).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, Theme.Metrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.iconButton, alignment: .leading)
    }

    var filters: some View {
        let rows = !items.isEmpty
        return HStack(spacing: Theme.Space.xs) {
            // The tabs never give up their words: the actions after them are what yields when the column is narrow.
            tabs.fixedSize().layoutPriority(2)
            InboxHeaderCue(hub: hub)
            Spacer(minLength: 0)
            if rows {
                IconButton(symbol: "magnifyingglass", help: "Search", detail: "⌘F") { hub.beginSearch() }
                inboxMenu
            } else {
                // Their room, so the tabs and the right edge don't jump when the first item arrives.
                Color.clear.frame(width: 2 * Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
            }
        }
        .padding(.trailing, 3)
    }

    /// Mark all as read and Done: all read on the first two tabs, Clear Done on Done.
    private var inboxMenu: some View {
        let filter = hub.filter
        return Menu {
            if filter == .done {
                Button("Clear Done") { LookoutHub.animate { store.clearDone() } }
                    .disabled(!store.hasClearableDone)
            } else {
                let rows = store.list(filter)
                Button("Mark all as read") { LookoutHub.animate { store.markAllRead(filter) } }
                    .keyboardShortcut(store.shortcut(.markAllRead).menuShortcut)
                    .disabled(!rows.contains { $0.state == .unread })
                Button("Done: all read") { LookoutHub.animate { store.doneAllRead(filter) } }
                    .disabled(!rows.contains { $0.state == .read })
            }
        } label: {
            InboxMenuGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(HoverFillButtonStyle(shape: Circle(), hitOutset: (Theme.Metrics.iconHit - Theme.Metrics.iconButton) / 2))
        .menuIndicator(.hidden)
        .fixedSize()
        .focusRing(Theme.Metrics.iconButton / 2)
        .tip("More")
        .accessibilityLabel("More")
    }

    var tabs: some View {
        Tabs(label: "Inbox filter", tabs: InboxFilter.allCases.map(tab), selection: hub.filter) { f in
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { hub.filter = f }
        }
        .voiceOverTarget("h:inbox", hub: hub)
    }

    func tab(_ f: InboxFilter) -> Tabs<InboxFilter>.Tab {
        // Unread, like the count in the bar beside it; none once everything's been seen. Amber for what needs you.
        let unread = store.unreadCount(f)
        let help = switch f {
        case .needsYou: "Reviews, mentions and replies from people"
        case .bots: "Comments from bots, kept quiet"
        case .done: "What you marked Done · Restore from here"
        }
        return Tabs.Tab(id: f, title: f.label, count: f == .done || unread == 0 ? nil : unread,
                        countTint: f == .needsYou ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.tertiary), help: help)
    }

    // MARK: Body

    /// What goes under the header: a banner for what is wrong with syncing, the rows (or why there are none), and
    /// the undo line. `cap` is the height the list scrolls within (a peek's: the rows that fit, and "+N more"); the
    /// caller pads the sides.
    func inboxBody(cap: CGFloat, peek: Bool = false) -> some View {
        let notice = store.inboxNotice()
        let undo = store.undoStack.visible(in: .inbox)
        // The banner and the undo line come out of the room the list has, so the whole body stays within `cap`.
        let groupLabel = searchGroups && !searchFoundNothing
        let listCap = cap - (notice == nil ? 0 : Theme.Metrics.banner + Theme.Space.xs)
            - (undo == nil ? 0 : Theme.Metrics.undoLine + Theme.Space.xs)
            - (groupLabel ? SearchGroupLabel.height + Theme.Space.xs : 0)
        return VStack(spacing: Theme.Space.xs) {
            if let notice {
                StatusBanner(symbol: notice.symbol, tint: notice.tint, message: notice.message) {
                    switch notice {
                    case .reposFailed, .reviewRequestsFailed, .reviewRequestsCut: InboxLink("Retry") { store.refreshNow() }
                    case .snoozed: InboxLink("Resume") { store.snooze(for: nil) }
                    case .rateLimited: EmptyView()
                    }
                }
            }
            if groupLabel { SearchGroupLabel(title: "Inbox", count: items.count, message: items.isEmpty ? "No items match" : nil) }
            if store.inboxReplacement != nil || items.isEmpty {
                emptyInbox
            } else {
                InboxList(items: items, cap: listCap, peeking: peek, listKey: listKey, scopeID: searching ? "search" : hub.filter.rawValue,
                          store: store, ui: ui, hub: hub)
            }
            if let undo {
                UndoLine(message: undo.message) { store.undoLast() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: notice) { _, new in
            if let new, NSApp != nil { AccessibilityNotification.Announcement(new.message).post() }
        }
    }

    /// The list is empty, or replaced: the cause, said once, with at most one way out. Searching, only when sessions
    /// found nothing either (they are listed beside the inbox's results).
    @ViewBuilder var emptyInbox: some View {
        if searching && store.inboxReplacement == nil {
            // (A group that found nothing says so in its own label, the other having found something.)
            if searchFoundNothing { EmptyBlock("No match") }
        } else {
            // Its own observation scope, on the minute clock: the cause is judged by the time it is drawn at, so "All caught
            // up" goes when the sync gets stale, and a poll only redraws this block, not the hub.
            Ticking(coarse: true) { now in emptyCause(store.inboxEmpty(hub.filter, now: now), now: now) }
        }
    }

    @ViewBuilder private func emptyCause(_ cause: InboxEmpty, now: Date) -> some View {
        switch cause {
        case .signedOut:
            EmptyBlock(title: "Can't sign in to GitHub", detail: "Lookout uses gh or your saved token.",
                       symbol: "exclamationmark.circle.fill", symbolTint: AnyShapeStyle(Theme.red)) {
                BorderedButton("Open Settings") { hub.go(.settings) }
            }
        case .noRepos:
            EmptyBlock(title: "Nothing watched yet", detail: "Add a repository to start.") {
                BorderedButton("Add a repository") { hub.go(.repos) }
            }
        case .firstSync:
            EmptyBlock("Checking GitHub…")
        case .caughtUp:
            let bots = store.unreadCount(.bots)
            EmptyBlock(title: "All caught up", detail: store.lastSync.map { "Checked \(agoPhrase($0, now: now))" }, symbol: "checkmark.circle") {
                if bots > 0 { InboxLink("\(bots) in Bots") { withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { hub.filter = .bots } } }
            }
        case .nothingNew:
            EmptyBlock("Nothing new")
        case .botsQuiet:
            EmptyBlock("Bots are quiet")
        case .doneEmpty:
            EmptyBlock("Cleared items land here")
        }
    }

    func itemRow(_ item: InboxItem) -> some View {
        InboxRow(item: item, store: store, ui: ui, hub: hub).capEdge()
    }
}

extension InboxNotice {
    var symbol: String {
        if case .snoozed = self { return "moon.fill" }
        return "exclamationmark.circle.fill"
    }

    var tint: AnyShapeStyle {
        if case .snoozed = self { return AnyShapeStyle(Theme.secondary) }
        return AnyShapeStyle(Theme.amber)
    }
}

// MARK: - List

/// The rows, scrolling within `cap`. Owns the rotor namespace ("Unread" walks the unread rows) and tells the header
/// when the list has scrolled under it. A list cut short says how many rows are below in a quiet `+N more` line; a
/// peek's never scrolls, and its "+N more" line keeps the hub open on the inbox.
struct InboxList: View {
    let items: [InboxItem]
    let cap: CGFloat
    var peeking = false
    let listKey: LookoutHub.ListKey
    /// The tab or the search: a new one starts a new list.
    let scopeID: String
    let store: Store
    let ui: UIState
    let hub: HubState
    @Namespace private var rotor
    /// How far the list has scrolled: not state, so scrolling doesn't redraw the rows (only the count below does).
    @State private var scroll = ScrollBox()

    /// Every row is one height (`twoLineRow`, a point apart), so what a cap shows is arithmetic, not measurement.
    static let spacing: CGFloat = 1
    static let pitch = Theme.Metrics.twoLineRow + spacing
    /// The `+N more` line's height, taken from the cap while the list is cut.
    static let moreHeight = Theme.Metrics.iconButton

    /// The whole rows a height holds (at least one).
    static func rowsFitting(_ height: CGFloat) -> Int { max(1, Int(((height + 1.5) / pitch).rounded(.down))) }

    /// Whether `count` rows overflow `cap`.
    static func isCut(count: Int, cap: CGFloat) -> Bool { count > rowsFitting(cap) }

    /// The rows wholly below a list scrolled by `offset`, showing `rows` of them.
    static func hiddenBelow(count: Int, offset: CGFloat, rows: Int) -> Int {
        let shown = CGFloat(rows) * pitch - 1
        return max(0, count - Int(((max(0, offset) + shown + 1.5) / pitch).rounded(.down)))
    }

    /// Cut short and with room for a row and the line that says so: with less, the list is a short scroll and nothing
    /// more, so the body never takes more than it was given.
    private var cut: Bool { Self.isCut(count: items.count, cap: cap) && cap >= Self.moreHeight + Self.pitch - 1 }
    private var rows: Int { Self.rowsFitting(cut ? cap - Self.moreHeight : cap) }

    var body: some View {
        if peeking { peek } else { scrolling }
    }

    /// The rows that fit whole, and what is left as "+N more".
    private var peek: some View {
        let shown = PeekCut.shown(count: items.count, height: Theme.Metrics.twoLineRow, spacing: Self.spacing, cap: cap)
        return VStack(spacing: 0) {
            VStack(spacing: Self.spacing) {
                ForEach(items.prefix(shown)) { InboxRow(item: $0, store: store, ui: ui, hub: hub, rotor: rotor) }
            }
            .accessibilityRotor("Unread") {
                ForEach(items.prefix(shown).filter { $0.state == .unread }) { AccessibilityRotorEntry(Text($0.title), id: $0.id, in: rotor) }
            }
            if shown < items.count {
                MoreRow(text: "+\(items.count - shown) more", label: plural(items.count - shown, "more item"),
                        hint: "Keeps Lookout open to show them") { hub.showAll(.inbox) }
            }
        }
    }

    private var scrolling: some View {
        VStack(spacing: 0) {
            list
            if cut {
                // Scrolled to the end the line stays, as the way back up (its room is kept, so the hub doesn't change height
                // under the pointer).
                if hub.inbox.hiddenBelow > 0 {
                    InboxMoreRow(text: "+\(hub.inbox.hiddenBelow) more", spoken: plural(hub.inbox.hiddenBelow, "more item"),
                                 hint: "Scrolls the list", action: showMore)
                } else {
                    InboxMoreRow(text: "Back to top", spoken: "Back to top", hint: "Scrolls to the first item") {
                        if let first = items.first { hub.requestScroll("i:" + first.id) }
                    }
                }
            }
        }
        .onAppear { refreshHidden() }
        .onChange(of: items.count) { refreshHidden() }
        .onChange(of: cap) { refreshHidden() }
    }

    private var list: some View {
        CappedScroll(cap: cut ? cap - Self.moreHeight : cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count),
                     onOffset: scrolled(to:)) {
            AdaptiveStack(count: items.count, spacing: Self.spacing) {
                ForEach(items) { item in
                    InboxRow(item: item, store: store, ui: ui, hub: hub, rotor: rotor).capEdge().id("i:" + item.id)
                }
            }
            .id(scopeID)
            .transition(.opacity)
            .motion(Theme.Motion.fade, value: listKey)
        }
        .onDisappear { hub.inbox.scrolled = false; hub.inbox.hiddenBelow = 0; hub.inbox.cueInHeader = false }
        .accessibilityRotor("Unread") {
            ForEach(items.filter { $0.state == .unread }) { AccessibilityRotorEntry(Text($0.title), id: $0.id, in: rotor) }
        }
    }

    /// Where the list has scrolled to, from its scroll view's own clip view: a geometry preference is not sent again as a
    /// scroll moves, so the count of rows below and the hairline under the header would never follow it.
    private func scrolled(to offset: CGFloat) {
        let scrolled = offset > 1
        if hub.inbox.scrolled != scrolled { hub.inbox.scrolled = scrolled }
        scroll.offset = offset
        refreshHidden()
    }

    private func refreshHidden() {
        // A list cut with no room for its line (a bar resting that low leaves the inbox one row) says it in the header.
        let overflowing = Self.isCut(count: items.count, cap: cap)
        let hidden = overflowing ? Self.hiddenBelow(count: items.count, offset: scroll.offset, rows: rows) : 0
        if hub.inbox.hiddenBelow != hidden { hub.inbox.hiddenBelow = hidden }
        if hub.inbox.cueInHeader != (overflowing && !cut) { hub.inbox.cueInHeader = overflowing && !cut }
    }

    /// A page further down: the last row of the next screenful scrolls into view.
    private func showMore() {
        let last = min(items.count - 1, items.count - hub.inbox.hiddenBelow + rows - 1)
        if items.indices.contains(last) { hub.requestScroll("i:" + items[last].id) }
    }

    private final class ScrollBox { var offset: CGFloat = 0 }
}

/// "+4 more" in the inbox's header, for a list that is cut short where there is no room under it for the line that says so.
/// Its own view: the count follows the scroll, which the hub's body doesn't read.
private struct InboxHeaderCue: View {
    let hub: HubState

    var body: some View {
        if hub.inbox.cueInHeader, hub.inbox.hiddenBelow > 0 {
            Text("+\(hub.inbox.hiddenBelow) more")
                .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
                .padding(.leading, Theme.Space.sm)
                .accessibilityLabel(plural(hub.inbox.hiddenBelow, "more item"))
        }
    }
}

/// "+3 more", under a list that is cut short, and "Back to top" once it is at the end: `tertiary` text level with the
/// rows' titles. A button, so it is on the Tab ring and VoiceOver can use it; it scrolls a page, or to the first item.
private struct InboxMoreRow: View {
    let text: String
    let spoken: String
    let hint: String
    let action: () -> Void
    @Environment(\.resolved) private var resolved
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Typography.meta)
                .foregroundStyle(hover || focused ? AnyShapeStyle(Theme.secondary) : AnyShapeStyle(resolved.tertiary))
                .padding(.leading, Theme.Metrics.rowPadding + Theme.Metrics.dotSlot + Theme.Metrics.avatar + Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: InboxList.moreHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(Theme.Radius.small, isFocused: focused)
        .reportsControlFocus(focused)
        .onHover { hover = $0 }
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
    }
}

// MARK: - Search

/// The query and what it found: a change of either is something to say.
private struct SearchSaid: Equatable {
    let query: String
    let summary: String
}

/// A real text field (paste, IME and dead keys work): a magnifier, the field, how many results, clear, and the `esc`
/// that ends it. Typing elsewhere seeds it and ⌘F focuses it (see `HubKeys`); the key monitor leaves it alone
/// while it has focus.
struct InboxSearchField: View {
    @Bindable var hub: HubState
    let ui: UIState
    let summary: String
    /// The rows the results show: when they change, the pick follows (edits to the field don't go through the keys).
    let targets: [String]
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").font(Theme.Typography.glyph(12)).foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField("Search inbox and sessions", text: $hub.query,
                      prompt: Text("Search inbox and sessions").foregroundStyle(Theme.tertiary))
                .focused($focused)
                .focusEffectDisabled()
                .foregroundStyle(Theme.text)
                .accessibilityLabel("Search inbox and sessions")
            if !hub.query.isEmpty {
                // Its own element after the field: VoiceOver reads it, and the field keeps its text as its value.
                Text(summary).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
                IconButton(symbol: "xmark.circle.fill", help: "Clear", detail: "Esc") { hub.query = ""; focused = true }
            }
            Text("esc").font(Theme.Typography.keyhint).foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
        }
        .fieldStyle(focused: focused)
        .onAppear { requestFocus() }
        .onChange(of: hub.inbox.focusRequest) { requestFocus() }
        .onChange(of: focused) { _, isFocused in
            hub.inbox.searchFocused = isFocused
            // Only a seeded first character moves the caret (carry on after it instead of replacing it): a click into the
            // middle of the query, or Tab back into the field, keeps the selection the field made.
            guard hub.inbox.caretAtEnd else { return }
            hub.inbox.caretAtEnd = false
            if isFocused { DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) } }
        }
        .onDisappear { hub.inbox.searchFocused = false }
        .onChange(of: targets) { hub.reconcileSelection(among: targets, ui: ui) }
        // What was found, said once the typing has paused, and again when the result changes under a query that stays (a poll
        // brought a match, Claude started a session): the count said is the one now on screen, and an older one is dropped.
        .task(id: SearchSaid(query: hub.query, summary: summary)) {
            guard !hub.query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { Announce.say(summary, after: .zero) }
        }
    }

    private func requestFocus() {
        DispatchQueue.main.async { focused = true }
    }
}

/// A search result group's label: "Inbox 5". The Sessions group's is its section header (see `agentsHeader`).
struct SearchGroupLabel: View {
    let title: String
    let count: Int
    /// What a group with no results says after its count.
    var message: String?
    static let height = Theme.Metrics.iconButton

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.label)
            Text("\(count)").font(Theme.Typography.numeral)
            if let message { Text("· \(message)").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary) }
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, Theme.Metrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(plural(count, "result"))")
        .accessibilityValue(message ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The header's menu button: the same look as an `IconButton`.
private struct InboxMenuGlyph: View {
    @Environment(\.hoverFillHovering) private var hover
    @Environment(\.resolved) private var resolved

    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(Theme.Typography.glyph(14, .medium))
            .foregroundStyle(hover ? Theme.text : resolved.secondary)
            .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
    }
}

/// A text button in `accentText`, 24pt to hit: "Retry", "Resume", "2 in Bots".
struct InboxLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                .frame(minHeight: Theme.Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.small)
    }
}
