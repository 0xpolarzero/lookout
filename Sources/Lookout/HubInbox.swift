import AppKit
import SwiftUI

// The inbox: its cell in the bar, header, tabs, search, empty state and rows.

/// An inbox item on two short lines; its actions show on hover or when picked with the keys. Done, Addressed and
/// Resolved items carry a small state tag (never a dimmed row: contrast stays).
struct CompactItemRow: View {
    let item: InboxItem
    let store: Store
    let ui: UIState
    let hub: HubState
    @State private var hover = false

    /// Compared here, in this row's own body: hovering another row doesn't rebuild the whole hub.
    private var selected: Bool { hub.selection == "i:" + item.id }
    private var low: Bool { hub.filter == .bots }
    private var open: Bool { hover || selected }
    private var unread: Bool { item.state == .unread }

    var body: some View {
        Button { store.open(item) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(unread ? (low ? AnyShapeStyle(Theme.tertiary) : AnyShapeStyle(Theme.amber)) : AnyShapeStyle(.clear))
                    .frame(width: 6, height: 6)
                    .padding(.top, 8)
                ZStack(alignment: .bottomTrailing) {
                    Avatar(url: item.avatar, name: item.author)
                    Image(systemName: item.kind.symbol)
                        .font(Theme.Typography.glyph(6, .bold))
                        .foregroundStyle(Theme.onTint)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(Theme.secondary))
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(unread ? Theme.Typography.title : Theme.Typography.body)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // The actions take the timestamp's place; the title stops short of them.
                        Text(shortAgo(item.createdAt)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
                            .opacity(open ? 0 : 1)
                            .frame(width: open ? actionsWidth - 6 : nil, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number) · \(item.kind.label) · @\(item.author)")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                        if !item.state.isOpen { StateTag(state: item.state) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.repo) #\(item.number)")
        .accessibilityValue(unread ? "Unread" : item.state.isOpen ? "" : StateTag.label(item.state))
        .accessibilityHint("Opens it on GitHub")
        .overlay(alignment: .topTrailing) {
            // Centred on the title line (6pt row padding + half its 15pt line = 13.5; the capsule is 26 tall).
            if open { actions.padding(.top, 1).padding(.trailing, 4).transition(.opacity) }
        }
        .contextMenu { InboxItemMenu(item: item, store: store, low: store.isLowPriority(item)) }
        .onHover {
            hover = $0
            if $0 {
                hub.selection = "i:" + item.id
                ui.drawerSelection = nil
            }
        }
        .motion(Theme.Motion.hover, value: open)
    }

    /// Room the action capsule takes over the title line: its buttons, its 2pt insets, and its 4pt from the edge.
    private var actionsWidth: CGFloat { CGFloat(item.state.isOpen ? 3 : 2) * Theme.Metrics.iconButton + 4 + 4 }

    private var actions: some View {
        RowActions {
            if item.state.isOpen {
                IconButton(symbol: unread ? "checkmark" : "circle.fill", help: unread ? "Mark as read" : "Mark as unread",
                           detail: store.shortcut(.toggleRead).display) { unread ? store.markRead(item) : store.markUnread(item) }
                IconButton(symbol: "xmark", help: "Done", detail: "Moves it to Done · \(store.shortcut(.discard).display)") { store.discard(item) }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Back to inbox", detail: store.shortcut(.discard).display) { store.restore(item) }
            }
            IconButton(symbol: "arrow.up.right", help: "Open on GitHub", detail: store.shortcut(.openItem).display) {
                store.open(item)
            }
        }
    }
}

/// What became of an inbox item that's no longer open: Done, Addressed (you replied) or Resolved.
struct StateTag: View {
    let state: ItemState

    static func label(_ state: ItemState) -> String {
        switch state {
        case .addressed: "Addressed"
        case .resolved: "Resolved"
        default: "Done"
        }
    }

    var body: some View {
        let symbol = switch state {
        case .addressed: "arrowshape.turn.up.left"
        case .resolved: "checkmark.circle"
        default: "checkmark"
        }
        Label(Self.label(state), systemImage: symbol)
            .font(Theme.Typography.meta.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize()
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
        // On the sides the same cell at rest and kept open, so it doesn't move (the tabs repeat its count).
        InboxCell(needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots), vertical: !edge.isHorizontal,
                  showsCount: !(showsDetail && !shrunk(.inbox) && edge.isHorizontal)) {
            // Straight to what needs you, its newest item picked so the keys act on it at once.
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) {
                hub.go(.main)
                hub.query = ""
                hub.filter = .needsYou
            }
            if let first = store.list(.needsYou).first {
                hub.selection = "i:" + first.id
                hub.requestScroll("i:" + first.id)
                ui.drawerSelection = nil
            }
        }
    }

    /// The filter chips are the inbox's title and status; typing swaps them for the search.
    @ViewBuilder var inboxHeader: some View {
        Group {
            if searching { searchField.transition(.opacity) } else { filters.transition(.opacity) }
        }
        .frame(height: Theme.Metrics.line)
    }

    var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(Theme.Typography.glyph(12)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                Text(hub.query).font(Theme.Typography.title.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                Capsule().fill(Theme.accent).frame(width: 1.5, height: 14)
            }
            Spacer(minLength: 0)
            Text(searchCount).font(Theme.Typography.meta.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
            KeyCap("Esc")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: Theme.Metrics.line)
        .background(Theme.Radius.shape(Theme.Radius.field).fill(Theme.Fill.field))
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
        HStack(spacing: 4) {
            // The tabs never give up their words: the actions after them are what yields when the column is narrow.
            tabs.fixedSize().layoutPriority(2)
            Spacer(minLength: 0)
            if hub.filter != .done && store.unreadCount(hub.filter) > 0 {
                IconButton(symbol: "checkmark.circle", help: "Mark all as read",
                           detail: "Everything in \(hub.filter.label) · \(store.shortcut(.markAllRead).display)") {
                    withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { store.markAllRead(hub.filter) }
                }
                .transition(.opacity)
            }
            if showsDetail { focusButton(.inbox) }
        }
        .padding(.trailing, 3)
        .motion(Theme.Motion.fade, value: store.unreadCount(hub.filter) > 0)
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
        case .done: "What you marked Done · Back to inbox from here"
        }
        return Tabs.Tab(id: f, title: f.label, count: f == .done || unread == 0 ? nil : unread,
                        countTint: f == .needsYou ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.tertiary), help: help)
    }

    var emptyInbox: some View {
        HStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : hub.filter == .needsYou ? "checkmark.circle" : "tray")
                .font(Theme.Typography.glyph(12))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            Text(searching ? "No inbox item matches" : hub.filter == .needsYou ? "All caught up"
                 : hub.filter == .bots ? "Bots are quiet" : "Nothing here yet")
                .font(Theme.Typography.body).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    func itemRow(_ item: InboxItem) -> some View {
        CompactItemRow(item: item, store: store, ui: ui, hub: hub).capEdge()
    }

    /// The inbox's list along the top and bottom: what's left once CI's lines are under it.
    var inboxColumn: some View {
        CappedScroll(cap: max(160, min(maxLength - Self.cell - 150 - ciExtra, Self.listCap)), hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
            AdaptiveStack(count: items.count, spacing: 1) {
                if items.isEmpty { emptyInbox }
                ForEach(items) { itemRow($0).id("i:" + $0.id) }
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 8)
            .id(searching ? "search" : hub.filter.rawValue)
            .transition(.opacity)
            .motion(Theme.Motion.fade, value: listKey)
        }
    }
}
