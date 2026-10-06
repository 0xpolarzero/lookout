import AppKit
import SwiftUI

// The full view (DESIGN.md 5.3): kept open, every section at once. The first cell never moves from where it is at rest:
// on the sides the inbox tile stays at the rail's top; along the top and bottom the strip's leading edge stays put and
// the hub grows away from it.

extension View {
    /// A named group for VoiceOver (Inbox, CI, Sessions, Controls).
    func section(_ name: String) -> some View {
        accessibilityElement(children: .contain).accessibilityLabel(name)
    }
}

extension LookoutHub {
    @ViewBuilder var openHub: some View {
        if edge.isHorizontal { openStripHub } else { openSideHub }
    }

    /// A section's header slot, one pitch tall: the whole header is the control that gives the section all the room, or
    /// gives it back (DESIGN.md 4.2). Its chevron shows on hover only (and while the section is the focused one, with
    /// `esc`), it is a pointing hand with a "Focus" action for VoiceOver, and its own controls take their clicks first.
    /// `owns`: the header is a `SectionHeader(onFocus:)`, which carries all that itself.
    func headerSlot<Header: View>(_ section: HubSection, owns: Bool = false, @ViewBuilder _ header: () -> Header) -> some View {
        HeaderSlot(section: section, focused: hub.focus == section, owns: owns, toggle: { hub.toggleFocus(section) }, header: header)
    }

    /// Between sections: a hairline across, with its room.
    var openDivider: some View { Hairline().padding(.vertical, Theme.Space.xs) }

    /// The inbox as a header with its counts, when another section has the room.
    var collapsedInboxHeader: some View {
        let needs = store.unreadCount(.needsYou)
        return sectionHeader("Inbox", status: needs > 0 ? [("\(needs) need you", AnyShapeStyle(Theme.amber))] : [])
    }

    /// What the full view of the sides' lists may scroll within: what the screen's length leaves once the fixed parts
    /// are laid out, the inbox first. A focused section takes all of it; shrunk ones are headers.
    var caps: (inbox: CGFloat, agents: CGFloat) {
        let pitch = Theme.Metrics.pitch
        let agents = store.agents.enabled
        let inbox = !shrunk(.inbox)
        let sessions = agents && !shrunk(.agents)
        var fixed = 2 * HubGeometry.lead + pitch * 2 + pitch  // inbox and CI headers, footer
        fixed += (searching ? 0 : pitch + (shrunk(.ci) ? 0 : max(ciHeight, pitch)) + 9) + 9  // CI block and its divider, footer's
        if agents { fixed += pitch + 9 + (sessions ? pitch : 0) }
        if store.updater.showsInPill { fixed += pitch }
        // Never less than a row of each list: a hub that can't fit even that below where the bar rests is the one case
        // `HubGeometry.along` moves.
        let row = Theme.Metrics.twoLineRow
        let free = max(fullLength - fixed, 2 * row)
        switch (inbox, sessions) {
        case (true, true):
            // Whole 44pt session rows, so the last one showing is never cut through its tile.
            let rows = max(1, (free * 0.45 / row).rounded(.down)) * row
            return (max(free - rows, row + 1), rows)
        case (true, false): return (free, 0)
        case (false, true): return (0, free)
        default: return (0, 0)
        }
    }

    // MARK: Cells

    /// The inbox's cell in its slot of the full view: the bar's own cell, so it keeps its look and its action (which
    /// picks the newest item that needs you), one pitch tall with its tile where it is at rest. The cell hangs its tile
    /// 21pt below its top (it has its count beneath); the slot's middle is 18pt down. A cell that is one pitch tall
    /// by itself needs no shift.
    @ViewBuilder var openInboxCell: some View {
        if edge.isHorizontal {
            inboxIcon.frame(height: Theme.Metrics.pitch)
        } else {
            inboxIcon.frame(height: Theme.Metrics.pitch, alignment: .top).offset(y: Theme.Metrics.pitch / 2 - 21)
        }
    }

    // MARK: Sides

    /// One line of the full view on the sides: the rail's cell on the screen side, the content beside it.
    func railRow<Cell: View, Detail: View>(alignment: VerticalAlignment = .center, @ViewBuilder cell: () -> Cell,
                                           @ViewBuilder detail: () -> Detail) -> some View {
        let slot = cell().frame(width: Self.cell)
        let content = detail()
            // The one outer inset, against the rounded side; the rail's cells sit on the other.
            .padding(edge == .right ? .leading : .trailing, Self.inset)
            .frame(width: Self.detail, alignment: .leading)
        return HStack(alignment: alignment, spacing: 0) {
            if edge == .left { slot }
            content
            if edge == .right { slot }
        }
    }

    /// A session on the sides: its tile in the rail and its block beside it, hovered or picked as one row.
    func sideSession(_ r: AgentRow) -> some View {
        SideSessionRow(id: r.id, ui: ui) {
            railRow(alignment: .top, cell: { tile(r, size: Theme.Metrics.tile) }, detail: { sessionBlock(r, twoLines: false, fills: false) })
        }
    }

    /// The rail: its fill and the hairline on its inner edge, as tall as the hub.
    var rail: some View {
        Theme.rail
            .frame(width: Self.cell)
            .overlay(alignment: edge == .right ? .leading : .trailing) { Hairline(axis: .vertical) }
            .frame(maxHeight: .infinity)
    }

    var openSideHub: some View {
        let caps = caps
        return VStack(alignment: .leading, spacing: 0) {
            // Inbox: its header level with its cell, the tile where it is at rest.
            VStack(alignment: .leading, spacing: 0) {
                railRow(cell: { openInboxCell }, detail: {
                    headerSlot(.inbox) { shrunk(.inbox) ? AnyView(collapsedInboxHeader) : AnyView(inboxHeader) }
                })
                if !shrunk(.inbox) { sideInbox(cap: caps.inbox) }
            }
            .section("Inbox")
            if !searching {
                openDivider
                VStack(alignment: .leading, spacing: 0) {
                    railRow(cell: { if !store.ciRepos.isEmpty { ciCell.frame(height: Theme.Metrics.pitch) } },
                            detail: { headerSlot(.ci) { ciHeader } })
                    if !shrunk(.ci) { railRow(cell: { Color.clear }, detail: { ciColumn }) }
                }
                .section("CI")
            }
            if store.agents.enabled {
                openDivider
                VStack(alignment: .leading, spacing: 0) {
                    railRow(cell: { Color.clear.frame(height: Theme.Metrics.pitch) }, detail: { headerSlot(.agents) { agentsHeader } })
                    if !shrunk(.agents) { sideAgents(cap: caps.agents) }
                }
                .section("Sessions")
            }
            if store.updater.showsInPill {
                railRow(cell: { UpdateButton(updater: store.updater, horizontal: false).frame(height: Theme.Metrics.pitch) },
                        detail: { Text(updateText).font(Theme.Typography.control).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.Metrics.rowPadding) })
            }
            openDivider
            railRow(cell: { settingsCell.frame(height: Theme.Metrics.pitch) }, detail: { footerRow }).section("Controls")
        }
        .padding(.vertical, HubGeometry.lead)
        .frame(width: Self.cell + Self.detail)
        .background(alignment: edge == .right ? .trailing : .leading) { rail }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lookout")
    }

    @ViewBuilder func sideInbox(cap: CGFloat) -> some View {
        if items.isEmpty {
            railRow(cell: { Color.clear }, detail: { emptyInbox })
        } else {
            CappedScroll(cap: cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
                AdaptiveStack(count: items.count, alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        railRow(cell: { Color.clear }, detail: { itemRow(item) }).capEdge().id("i:" + item.id)
                    }
                }
                .padding(.bottom, Theme.Space.xs)
                .id(searching ? "search" : hub.filter.rawValue)
                .transition(.opacity)
                .motion(Theme.Motion.fade, value: listKey)
            }
            // Its own width, so a scroller can't widen it and push its rows off the rail's cells.
            .frame(width: Self.cell + Self.detail)
        }
    }

    /// The sessions, each with its tile in the rail, then New session.
    @ViewBuilder func sideAgents(cap: CGFloat) -> some View {
        let rows = agentRows
        railRow(cell: { Color.clear }, detail: { ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding) })
        CappedScroll(cap: cap, hub: hub) {
            VStack(alignment: .leading, spacing: 0) {
                let starts = projectStarts(rows.kept)
                ForEach(rows.kept) { r in
                    sideSession(r)
                        .modifier(AgentReorder(row: r, store: store))
                        .modifier(GroupRule(on: starts.contains(r.id)))
                        .capEdge()
                        .id("a:" + r.id)
                }
                if !rows.pending.isEmpty {
                    railRow(cell: { Color.clear }, detail: { pendingLabel(twoLines: false).frame(height: Theme.Metrics.pitch, alignment: .leading) })
                    ForEach(rows.pending) { r in
                        sideSession(r)
                            .capEdge()
                            .id("a:" + r.id)
                    }
                }
            }
        }
        .frame(width: Self.cell + Self.detail)
        railRow(cell: { newSessionCell }, detail: { newSessionDetail })
    }

    // MARK: Top and bottom

    /// What the strip's cells are 36pt of: one pitch, in the strip's 46.
    private var stripCell: CGFloat { Theme.Metrics.pitch }

    var openStripHub: some View {
        let columns = hub.focus == nil && store.agents.enabled
        let width = HubGeometry.stripWidth(focus: hub.focus, sessions: store.agents.enabled, room: maxWidth)
        let strip = openStripRow(columns: columns, width: width)
        let body = openStripBody(columns: columns, width: width)
        // The columns' inset on the left, so its text starts on the content edge; on the right what puts the last
        // button's centre on the gear's (the footer's own hair is part of it).
        let gearColumn = HubGeometry.lead + (stripCell - Theme.Metrics.iconButton) / 2 - Theme.Space.hair
        let footer = footerRow.padding(.leading, Self.inset).padding(.trailing, gearColumn)
        return VStack(alignment: .leading, spacing: 0) {
            // The strip stays at the screen's edge and the hub grows away from it; the footer is the far end.
            if edge == .bottom { footer.section("Controls"); Hairline().padding(.horizontal, Self.inset); body; Hairline().padding(.horizontal, Self.inset); strip }
            else { strip; Hairline().padding(.horizontal, Self.inset); body; Hairline().padding(.horizontal, Self.inset); footer.section("Controls") }
        }
        .padding(edge == .top ? .bottom : .top, HubGeometry.lead)
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lookout")
    }

    /// The strip kept open: the inbox's cell and header over its column, the sessions' header over theirs, and at the
    /// far end the update cell and the gear.
    func openStripRow(columns: Bool, width: CGFloat) -> some View {
        let trailing = HStack(spacing: 0) {
            if store.updater.showsInPill { UpdateButton(updater: store.updater, horizontal: true).padding(.horizontal, Theme.Space.sm) }
            settingsCell.frame(width: stripCell, height: Self.cell)
        }
        .padding(.trailing, HubGeometry.lead)
        let inbox = HStack(spacing: 0) {
            openInboxCell.frame(width: stripCell, height: Self.cell)
            headerSlot(.inbox) { shrunk(.inbox) ? AnyView(collapsedInboxHeader) : AnyView(inboxHeader) }
                .padding(.leading, Theme.Metrics.contentEdge - Self.inset - Theme.Space.md)
                .padding(.trailing, Self.inset)
        }
        .padding(.leading, HubGeometry.lead)
        return HStack(spacing: 0) {
            if columns {
                inbox.frame(width: HubGeometry.leftColumn)
                Hairline(axis: .vertical, inset: 12).frame(width: HubGeometry.gutter)
                HStack(spacing: 0) {
                    headerSlot(.agents) { agentsHeader }.padding(.trailing, Self.inset)
                    trailing
                }
                .frame(width: width - HubGeometry.leftColumn - HubGeometry.gutter)
            } else {
                inbox
                trailing
            }
        }
        .frame(width: width, height: Self.cell)
    }

    @ViewBuilder func openStripBody(columns: Bool, width: CGFloat) -> some View {
        let room = maxLength - Self.cell - Theme.Metrics.pitch - 2 * HubGeometry.lead - 2
        if columns {
            // Both columns hug the strip their headers are in: along the bottom the shorter one rests on it, so its
            // rows stay next to their header and any void is at the far end, beside the footer.
            HStack(alignment: edge == .bottom ? .bottom : .top, spacing: 0) {
                leftColumn(room: room).frame(width: HubGeometry.leftColumn)
                Hairline(axis: .vertical, inset: 12).frame(width: HubGeometry.gutter)
                rightColumn(room: room).frame(width: width - HubGeometry.leftColumn - HubGeometry.gutter)
            }
        } else {
            singleColumn(room: room)
        }
    }

    /// Inbox, then CI directly under it with its own header; along the bottom, the other way up (the lists keep
    /// their order, the header stays next to the strip it belongs to).
    func leftColumn(room: CGFloat) -> some View {
        let ci = ciBlock
        let inboxCap = max(room - (searching ? 0 : Theme.Metrics.pitch + max(ciHeight, Theme.Metrics.pitch) + 9), 120)
        return VStack(alignment: .leading, spacing: 0) {
            if edge == .bottom {
                if !searching { ci; Hairline().padding(.vertical, Theme.Space.xs) }
                stripInbox(cap: inboxCap).section("Inbox")
            } else {
                stripInbox(cap: inboxCap).section("Inbox")
                if !searching { Hairline().padding(.vertical, Theme.Space.xs); ci }
            }
        }
        .padding(.horizontal, Self.inset)
    }

    func rightColumn(room: CGFloat) -> some View {
        let cap = max(room - Theme.Metrics.pitch, 120)
        return VStack(alignment: .leading, spacing: 0) {
            if edge == .bottom { newSession; stripAgents(cap: cap) } else { stripAgents(cap: cap); newSession }
        }
        .padding(.horizontal, Self.inset)
        .section("Sessions")
    }

    /// Focused: the section has the whole column, the others are their headers; along the bottom the other way up.
    func singleColumn(room: CGFloat) -> some View {
        let focus = hub.focus
        let agents = store.agents.enabled
        let headers = Theme.Metrics.pitch * CGFloat((searching ? 0 : 1) + (agents ? 1 : 0))
        let inboxCap = max(room - headers - (focus == .ci ? max(ciHeight, 0) : 0) - (focus == .agents ? 0 : 0), 120)
        return VStack(alignment: .leading, spacing: 0) {
            let inbox = VStack(spacing: 0) { if !shrunk(.inbox) { stripInbox(cap: inboxCap) } }.section("Inbox")
            let ci = VStack(spacing: 0) { if !searching { ciBlock } }
            let sessions = VStack(alignment: .leading, spacing: 0) {
                if agents {
                    headerSlot(.agents) { agentsHeader }
                    if !shrunk(.agents) { stripAgents(cap: max(room - headers, 120)); newSession }
                }
            }
            .section("Sessions")
            if edge == .bottom { sessions; ci; inbox } else { inbox; ci; sessions }
        }
        .padding(.horizontal, Self.inset)
    }

    var ciBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSlot(.ci) { ciHeader }
            if !shrunk(.ci) { ciColumn }
        }
        .section("CI")
    }

    var newSession: some View {
        NewSessionRow(store: store, style: .twoLines).frame(height: Theme.Metrics.pitch)
    }

    @ViewBuilder func stripInbox(cap: CGFloat) -> some View {
        if items.isEmpty {
            emptyInbox
        } else {
            CappedScroll(cap: cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
                AdaptiveStack(count: items.count, spacing: 1) { ForEach(items) { itemRow($0).id("i:" + $0.id) } }
                    .id(searching ? "search" : hub.filter.rawValue)
                    .transition(.opacity)
                    .motion(Theme.Motion.fade, value: listKey)
            }
        }
    }

    /// The sessions one per line, by project, then the new activity (tile and text in one row, as in a peek).
    @ViewBuilder func stripAgents(cap: CGFloat) -> some View {
        let rows = agentRows
        ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding)
        CappedScroll(cap: cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(rows.kept.count + rows.pending.count)) {
            AdaptiveStack(count: rows.kept.count + rows.pending.count, alignment: .leading, spacing: 0) {
                let starts = projectStarts(rows.kept)
                ForEach(rows.kept) { r in
                    if starts.contains(r.id) { groupDivider }
                    twoLineRow(r).modifier(AgentReorder(row: r, store: store))
                }
                if !rows.pending.isEmpty {
                    if !rows.kept.isEmpty { groupDivider }
                    pendingLabel(twoLines: true).padding(.bottom, Theme.Space.xs)
                    ForEach(rows.pending) { twoLineRow($0) }
                }
            }
        }
    }
}

/// A section header made into the control that focuses its section (see `LookoutHub.headerSlot`).
struct HeaderSlot<Header: View>: View {
    let section: HubSection
    let focused: Bool
    let owns: Bool
    let toggle: () -> Void
    @ViewBuilder let header: Header
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        if owns {
            header.frame(height: Theme.Metrics.pitch)
        } else {
            let help = focused ? "Back to all sections" : "Expand \(section.name)"
            HStack(spacing: 0) {
                header
                if focused { Text("esc").font(Theme.Typography.keyhint).foregroundStyle(Theme.secondary).padding(.trailing, Theme.Space.sm) }
                // Always there, so the header's own controls never move when it shows.
                Image(systemName: focused ? "chevron.up" : "chevron.down")
                    .font(Theme.Typography.glyph(11, .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                    .padding(.trailing, Theme.Space.hair)
                    .opacity(hovering || focused ? 1 : 0)
                    .tip(help)
                    .accessibilityHidden(true)
            }
            .frame(height: Theme.Metrics.pitch)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { inside in
                hovering = inside
                // The pointing hand, pushed and popped in pairs.
                guard inside != cursorPushed else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                cursorPushed = inside
            }
            .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
            .motion(Theme.Motion.hover, value: hovering)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: focused ? "Back to all sections" : "Focus", toggle)
        }
    }
}

/// The highlight of a session's line on the sides, across its content and its rail cell. Whether it is the picked one is
/// compared here, in its own body, so a hover redraws this row alone.
struct SideSessionRow<Content: View>: View {
    let id: String
    let ui: UIState
    @ViewBuilder let content: Content
    @Environment(\.resolved) private var resolved

    var body: some View {
        let selected = ui.drawerSelection == id
        content
            // The one outer inset on both sides: the rounded one and the rail's, against the screen.
            .background(Theme.Radius.shape(Theme.Radius.row).fill(resolved.fill(selected ? Theme.Fill.hover : Theme.Fill.rest))
                .padding(.horizontal, HubGeometry.inset))
            .motion(Theme.Motion.hover, value: selected)
    }
}

// MARK: Old full view

extension LookoutHub {
    // What the old full view's code (HubBar.swift's `openColumn` and `openStrip`, HubInbox's `inboxColumn`) still names.
    // Nothing draws it any more: it goes with that code when the bar's rewrite lands.
    var side: HorizontalAlignment { edge == .right ? .trailing : .leading }
    var rowWidth: CGFloat { showsDetail ? Self.cell + Self.detail : Self.cell }
    var ciExtra: CGFloat { 0 }
    static let listCap: CGFloat = 300
    static let githubWidth: CGFloat = 570
    static let inboxSegment: CGFloat = 370
    static let agentsMin: CGFloat = 260
    static let ciWidth: CGFloat = 300
    func columnWidth(_ section: HubSection) -> CGFloat { Self.githubWidth }
}
