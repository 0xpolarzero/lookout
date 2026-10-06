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
    var scrolled = false

    func startSearch() {
        searchOpen = true
        focusRequest &+= 1
    }

    func endSearch() {
        searchOpen = false
        searchFocused = false
    }
}

extension HubState {
    /// The one way into search (⌘F, the magnifier, typing): the results are the inbox's and the sessions', side by side,
    /// so it keeps the hub open (from a peek, which shows one section), gives up any section focus (which would
    /// shrink one of them or leave the field out), then asks the field for the keyboard.
    func beginSearch() {
        LookoutHub.animate(LookoutHub.refocus) {
            if !pinned { pinned = true }
            focus = nil
            inbox.startSearch()
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
        hubItems(hub).map { "i:" + $0.id } + hubSessions(hub).map { "a:" + $0.id }
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
    case rateLimited(until: Date?)
    case snoozed(until: Date)

    var message: String {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        return switch self {
        case .reposFailed(let n): "\(plural(n, "repository", "repositories")) didn't sync"
        case .rateLimited(let until?): "GitHub is rate limiting. Checking again at \(time(until))."
        case .rateLimited: "GitHub is rate limiting. Checking again soon."
        case .snoozed(let until): "Snoozed until \(time(until))"
        }
    }
}

extension Store {
    /// Whether the last sync is too old to say "all caught up" (three poll intervals, as the footer says "Not syncing").
    private func syncIsStale(now: Date) -> Bool {
        lastSync.map { now.timeIntervalSince($0) > settings.pollInterval * 3 } ?? false
    }

    /// What replaces the list whatever rows it has: a sign-in problem leaves the cached rows stale, so they aren't shown.
    var inboxReplacement: InboxEmpty? { authError != nil ? .signedOut : nil }

    /// The cause to show when the list under `filter` is empty.
    func inboxEmpty(_ filter: InboxFilter, now: Date = Date()) -> InboxEmpty {
        if let replacement = inboxReplacement { return replacement }
        if repos.isEmpty { return .noRepos }
        if lastSync == nil { return .firstSync }
        switch filter {
        case .needsYou: return repoErrors.isEmpty && rateRemaining != 0 && !syncIsStale(now: now) ? .caughtUp : .nothingNew
        case .bots: return .botsQuiet
        case .done: return .doneEmpty
        }
    }

    /// The banner above the list, if any. Not with a sign-in problem or nothing watched: those replace the list.
    func inboxNotice(now: Date = Date()) -> InboxNotice? {
        guard authError == nil, !repos.isEmpty else { return nil }
        if !repoErrors.isEmpty { return .reposFailed(repoErrors.count) }
        if rateRemaining == 0 { return .rateLimited(until: rateResetsAt.flatMap { $0 > now ? $0 : nil }) }
        if isSnoozed, let until = settings.snoozeUntil { return .snoozed(until: until) }
        return nil
    }
}

/// The inbox in the bar: the tray, and under it (beside it along the top and bottom) one count. Amber for what
/// needs you; the bots' count, grey, only when nothing does. Nothing sits on top of the icon.
struct InboxCell: View {
    let needsYou: Int
    let bots: Int
    let vertical: Bool
    /// Off while the filter chips beside it already show the counts.
    var showsCount = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { InboxCellLabel(needsYou: needsYou, bots: bots, vertical: vertical, showsCount: showsCount) }
            .buttonStyle(.plain)
            .accessibilityLabel("Inbox")
            .accessibilityValue([needsYou > 0 ? "\(needsYou) need you" : nil, bots > 0 ? plural(bots, "bot item") : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Shows what needs you")
            .motion(Theme.Motion.fade, value: needsYou)
            .motion(Theme.Motion.fade, value: bots)
            .motion(Theme.Motion.move, value: showsCount)
    }
}

private struct InboxCellLabel: View {
    let needsYou: Int
    let bots: Int
    let vertical: Bool
    let showsCount: Bool
    @State private var hover = false

    var body: some View {
        Group {
            if vertical {
                // Always as tall as icon + count, so the bar never shifts: the tray just slides to the middle.
                ZStack(alignment: .top) {
                    icon.offset(y: badge == nil ? 9 : 0)
                    if let badge { badge.offset(y: 32) }
                }
                .frame(height: 47, alignment: .top)
            } else {
                HStack(spacing: 6) {
                    icon
                    if let badge { badge }
                }
                // Never squeezed by the tabs beside it.
                .fixedSize()
            }
        }
        .padding(.vertical, vertical ? 7 : 5)
        .padding(.horizontal, vertical ? 4 : 7)
        .frame(minWidth: vertical ? Theme.Metrics.pitch : nil)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .motion(Theme.Motion.hover, value: hover)
    }

    /// The tray; on a solid amber tile (like a session's) when something needs you, so it shows from afar.
    private var icon: some View {
        let lit = needsYou > 0
        return Image(systemName: lit ? "tray.full.fill" : "tray.fill")
            .font(Theme.Typography.glyph(lit ? 13.5 : 15))
            .foregroundStyle(lit ? AnyShapeStyle(Theme.onTint) : hover ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
            .frame(width: 28, height: 28)
            // Hover brightens the tile (or the tray), no box around it.
            .background(Tile.shape(28).fill(lit ? Theme.amber : hover ? Theme.Fill.hover : Theme.Fill.rest))
            .brightness(lit && hover ? 0.06 : 0)
            .motion(Theme.Motion.fade, value: lit)
    }

    private var badge: AnyView? {
        guard showsCount else { return nil }
        // The tile is already amber: the count beside it stays quiet.
        if needsYou > 0 { return AnyView(count(needsYou, fill: Theme.Fill.selected, text: Theme.text)) }
        if bots > 0 { return AnyView(count(bots, fill: Theme.Fill.hover, text: Theme.secondary)) }
        return nil
    }

    private func count(_ n: Int, fill: Color, text: some ShapeStyle) -> some View {
        Text(n > 99 ? "99+" : "\(n)")
            .font(Theme.Typography.glyph(11, .bold).monospacedDigit())
            .contentTransition(.numericText(value: Double(n)))
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 15)
            .background(Capsule().fill(fill))
            .transition(.opacity)
    }
}

extension LookoutHub {
    // MARK: Inbox

    var inboxIcon: some View {
        InboxCell(needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots), vertical: !edge.isHorizontal,
                  showsCount: !(showsDetail && !shrunk(.inbox))) {
            // Straight to what needs you, its newest item picked so the keys act on it at once.
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) {
                hub.go(.main)
                hub.query = ""
                hub.inbox.endSearch()
                hub.filter = .needsYou
            }
            if let first = store.list(.needsYou).first {
                hub.selection = "i:" + first.id
                hub.requestScroll("i:" + first.id)
                ui.drawerSelection = nil
            }
        }
    }


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

    /// What the search found, by kind: "3 items · 2 sessions".
    var searchCount: String {
        let found = items.count
        let sessions = store.agents.enabled ? store.hubSessions(hub).count : 0
        if found == 0 && sessions == 0 { return "No match" }
        return [found == 0 ? nil : plural(found, "item"), sessions == 0 ? nil : plural(sessions, "session")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var filters: some View {
        let rows = !store.list(hub.filter).isEmpty
        return HStack(spacing: Theme.Space.xs) {
            // The tabs never give up their words: the actions after them are what yields when the column is narrow.
            tabs.fixedSize().layoutPriority(2)
            Spacer(minLength: 0)
            if rows {
                IconButton(symbol: "magnifyingglass", help: "Search", detail: "⌘F") { hub.beginSearch() }
                inboxMenu
            } else {
                // Their room, so the tabs and the right edge don't jump when the first item arrives.
                Color.clear.frame(width: 2 * Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
            }
            if showsDetail { focusButton(.inbox) }
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
        .buttonStyle(HoverFillButtonStyle(shape: Circle()))
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
    /// the undo line. `cap` is the height the list scrolls within; the caller pads the sides.
    func inboxBody(cap: CGFloat) -> some View {
        let notice = store.inboxNotice()
        return VStack(spacing: Theme.Space.xs) {
            if let notice {
                StatusBanner(symbol: notice.symbol, tint: notice.tint, message: notice.message) {
                    switch notice {
                    case .reposFailed: InboxLink("Retry") { store.refreshNow() }
                    case .snoozed: InboxLink("Resume") { store.snooze(for: nil) }
                    case .rateLimited: EmptyView()
                    }
                }
            }
            if store.inboxReplacement != nil || items.isEmpty {
                emptyInbox
            } else {
                InboxList(items: items, cap: cap, listKey: listKey, scopeID: searching ? "search" : hub.filter.rawValue,
                          store: store, ui: ui, hub: hub)
            }
            if let undo = store.undoStack.visible(in: .inbox) {
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
            if !store.agents.enabled || store.hubSessions(hub).isEmpty { EmptyBlock("No match") }
        } else {
            switch store.inboxEmpty(hub.filter) {
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
                EmptyBlock(title: "All caught up", detail: store.lastSync.map { "Checked \(agoPhrase($0))" }, symbol: "checkmark.circle") {
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
    }

    func itemRow(_ item: InboxItem) -> some View {
        InboxRow(item: item, store: store, ui: ui, hub: hub).capEdge()
    }

    /// The inbox's list along the top and bottom: what's left once CI's lines are under it.
    var inboxColumn: some View {
        inboxBody(cap: max(160, min(maxLength - Self.cell - 150 - ciExtra, Self.listCap)))
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 8)
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
/// when the list has scrolled under it.
struct InboxList: View {
    let items: [InboxItem]
    let cap: CGFloat
    let listKey: LookoutHub.ListKey
    /// The tab or the search: a new one starts a new list.
    let scopeID: String
    let store: Store
    let ui: UIState
    let hub: HubState
    @Namespace private var rotor

    private static let space = "inbox-list"

    var body: some View {
        CappedScroll(cap: cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count), fades: false, indicators: true) {
            AdaptiveStack(count: items.count, spacing: 1) {
                ForEach(items) { item in
                    InboxRow(item: item, store: store, ui: ui, hub: hub, rotor: rotor).capEdge().id("i:" + item.id)
                }
            }
            .background(alignment: .top) {
                Color.clear.frame(height: 0).background {
                    GeometryReader { Color.clear.preference(key: ScrollOffset.self, value: $0.frame(in: .named(Self.space)).minY) }
                }
            }
            .id(scopeID)
            .transition(.opacity)
            .motion(Theme.Motion.fade, value: listKey)
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(ScrollOffset.self) { offset in
            let scrolled = offset < -1
            if hub.inbox.scrolled != scrolled { hub.inbox.scrolled = scrolled }
        }
        .onDisappear { hub.inbox.scrolled = false }
        .accessibilityRotor("Unread") {
            ForEach(items.filter { $0.state == .unread }) { AccessibilityRotorEntry(Text($0.title), id: $0.id, in: rotor) }
        }
    }
}

private struct ScrollOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Search

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
            // A seeded first character: carry on after it instead of replacing it.
            if isFocused { DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) } }
        }
        .onDisappear { hub.inbox.searchFocused = false }
        .onChange(of: targets) { hub.reconcileSelection(among: targets, ui: ui) }
        // What was found, said once the typing has paused.
        .task(id: hub.query) {
            guard !hub.query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, NSApp != nil { AccessibilityNotification.Announcement(summary).post() }
        }
    }

    private func requestFocus() {
        DispatchQueue.main.async { focused = true }
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
