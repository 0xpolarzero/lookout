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

    /// Shrunk to its header because another section is focused (in the full view only).
    func shrunk(_ section: HubSection) -> Bool {
        showsDetail && hub.focus != nil && hub.focus != section
    }

    /// Between sections: a hairline across, with its room.
    var openDivider: some View { Hairline().padding(.vertical, Theme.Space.xs) }

    /// The inbox as a header with its counts, when another section has the room.
    var collapsedInboxHeader: some View {
        let needs = store.unreadCount(.needsYou)
        return SectionHeader(title: "Inbox", status: needs > 0 ? ("\(needs) need you", AnyShapeStyle(Theme.amber)) : nil,
                             expandHelp: "Expand Inbox", onFocus: { hub.toggleFocus(.inbox) }) {}
    }

    /// What the sides' full view takes besides its lists: its header and footer, the dividers, the update row, the padding
    /// at both ends, and whatever each section keeps when it is not a list. `ciBody`: what the CI block takes under its
    /// header (none when it is folded, shrunk or searched away).
    private func fixedLength(ciBody: CGFloat) -> CGFloat {
        let pitch = Theme.Metrics.pitch
        let divider = 2 * Theme.Space.xs + 1
        let agents = store.agents.enabled
        let sessions = agents && !shrunk(.agents)
        // The inbox's header, the footer and its divider, and the padding at both ends.
        var fixed = 2 * HubGeometry.lead + 2 * pitch + divider
        if !searching { fixed += divider + pitch + ciBody }
        if agents { fixed += divider + pitch + (sessions ? pitch + ClaudeNotice.room(store) : 0) }
        if store.updater.showsInPill { fixed += pitch }
        return fixed
    }

    private var ciBodyHeight: CGFloat { max(ciHeight, Theme.Metrics.pitch) }

    /// CI is only its header (its counts in it) where the room below the bar can't give each list a row after it: a
    /// bar resting that low keeps the screen's end as the hub's, and the lists matter more than CI's lines.
    var foldsCI: Bool {
        let lists: CGFloat = store.agents.enabled ? 2 : 1
        return !searching && hub.focus == nil && fullLength - fixedLength(ciBody: ciBodyHeight) < lists * Theme.Metrics.twoLineRow
    }

    /// CI is only its header in the full view: another section is focused, or (on the sides) the room below a low bar
    /// folds it.
    var ciIsHeaderOnly: Bool { showsDetail && (shrunk(.ci) || (!edge.isHorizontal && foldsCI)) }

    /// Whether CI's lines show under its header.
    var showsCIBody: Bool { !shrunk(.ci) && !foldsCI && !store.ciRepos.isEmpty }

    /// What the full view of the sides' lists may scroll within: what the screen's length leaves once the fixed parts
    /// are laid out, the inbox first. A focused section takes all of it; shrunk ones are headers. Both lists end on a
    /// whole row, so the sessions take whatever the inbox's rows leave, and the inbox what the sessions' don't need.
    /// The length is the whole budget: with less than a row left a list is a short scroll, never a taller hub.
    var caps: (inbox: CGFloat, agents: CGFloat) {
        let agents = store.agents.enabled
        let inbox = !shrunk(.inbox)
        let sessions = agents && !shrunk(.agents)
        let row = Theme.Metrics.twoLineRow
        let free = max(fullLength - fixedLength(ciBody: showsCIBody ? ciBodyHeight : 0), 0)
        switch (inbox, sessions) {
        case (true, true):
            let share = free * 0.45
            let need = listHeights[.agents].map { min($0.content, share) } ?? share
            let inboxCap = max(free - max(need, row), min(row, free))
            // Until the inbox is measured, it is taken to use all it may.
            let taken = min(listHeights[.inbox]?.shown ?? inboxCap, inboxCap)
            return (inboxCap, max(free - taken, 0))
        case (true, false): return (free, 0)
        case (false, true): return (0, free)
        default: return (0, 0)
        }
    }

    /// Records what a side list measured of itself (nil when it is gone).
    func record(_ section: HubSection, _ heights: ListHeights?) {
        if listHeights[section] != heights { listHeights[section] = heights }
    }

    /// The cue under a cut list on the sides: on the text of its rows, beside the rail. None where the room is under a
    /// row and its line (`cap`): there is no space to say anything in.
    func sideCue(_ noun: String, cap: CGFloat) -> MoreCue? {
        guard cap >= Theme.Metrics.twoLineRow + Theme.Metrics.pitch else { return nil }
        let rail = Self.cell, inset = Self.inset
        return MoreCue(noun: noun, insets: EdgeInsets(top: 0, leading: edge == .left ? rail : inset, bottom: 0,
                                                      trailing: edge == .left ? inset : rail))
    }

    // MARK: Cells

    /// The inbox's cell in its slot of the full view: the bar's own cell, so it keeps its look and its action (which
    /// picks the newest item that needs you), one pitch tall with its tile where it is at rest.
    var openInboxCell: some View {
        InboxBarCell(axis: barAxis, needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots),
                     show: { show(.inbox) }, action: openInbox)
    }

    /// The other cells of the bar, in the slots of the full view that are theirs.
    @ViewBuilder var openCICell: some View {
        if !store.ciRepos.isEmpty { CIBarCell(axis: barAxis, store: store, show: { show(.ci) }) }
    }

    var openGearCell: some View {
        GearBarCell(axis: barAxis, store: store, hub: hub) { hub.showControls() }
    }

    var openUpdateCell: some View {
        UpdateBarCell(axis: barAxis, updater: store.updater) { hub.go(.settings) }
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
                railRow(alignment: .top, cell: { openInboxCell }, detail: {
                    headerSlot(.inbox, owns: shrunk(.inbox)) { shrunk(.inbox) ? AnyView(collapsedInboxHeader) : AnyView(inboxHeader) }
                })
                if !shrunk(.inbox) { sideInbox(cap: caps.inbox) }
            }
            .section("Inbox")
            if !searching {
                openDivider
                VStack(alignment: .leading, spacing: 0) {
                    if store.ciRepos.isEmpty {
                        // Nothing to say about CI but how to turn it on: one line, not a header over a line.
                        railRow(cell: { Color.clear.frame(height: Theme.Metrics.pitch) }, detail: { noCI })
                    } else {
                        railRow(cell: { openCICell.frame(height: Theme.Metrics.pitch) },
                                detail: { headerSlot(.ci, owns: true) { ciHeader } })
                        if showsCIBody { railRow(cell: { Color.clear }, detail: { ciColumn }) }
                    }
                }
                .section("CI")
            }
            if store.agents.enabled {
                openDivider
                VStack(alignment: .leading, spacing: 0) {
                    railRow(cell: { Color.clear.frame(height: Theme.Metrics.pitch) }, detail: { headerSlot(.agents, owns: true) { agentsHeader } })
                    if !shrunk(.agents) { sideAgents(cap: caps.agents) }
                }
                .section("Sessions")
            }
            if store.updater.showsInPill {
                railRow(cell: { openUpdateCell },
                        detail: { Text(updateText).font(Theme.Typography.control).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.Metrics.rowPadding) })
            }
            openDivider
            railRow(cell: { openGearCell }, detail: { footerRow }).section("Controls")
        }
        .padding(.vertical, HubGeometry.lead)
        .frame(width: Self.cell + Self.detail)
        .background(alignment: edge == .right ? .trailing : .leading) { rail }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lookout")
    }

    /// The inbox's body beside the rail: its banner, rows (or why there are none) and undo line, measured so the list
    /// below it takes what is left.
    func sideInbox(cap: CGFloat) -> some View {
        railRow(cell: { Color.clear }, detail: { inboxBody(cap: cap) })
            .frame(width: Self.cell + Self.detail)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { record(.inbox, ListHeights(shown: $0, content: $0)) }
            .onDisappear { record(.inbox, nil) }
    }

    /// How tall the sessions' rows are altogether, as the list lays them out (its "+N more" row included).
    var agentsContent: CGFloat {
        let listed = store.listedGroups(expanded: hub.sessionsExpanded)
        return SessionGroup.height(listed.groups) + (listed.hidden > 0 ? Theme.Metrics.pitch : 0)
    }

    /// The sessions, each with its tile in the rail, then New session.
    @ViewBuilder func sideAgents(cap: CGFloat) -> some View {
        // (A row of its own only while there is a notice: an empty one would still be as tall as a clear cell's ideal.)
        if ClaudeNotice.room(store) > 0 {
            railRow(cell: { Color.clear }, detail: { ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding) })
        }
        sessionsScroll(cap: cap).frame(width: Self.cell + Self.detail)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { record(.agents, ListHeights(shown: $0, content: agentsContent)) }
            .onDisappear { record(.agents, nil) }
        if noSessionsMatch { railRow(cell: { Color.clear }, detail: { noSessionsLine }) }
        newSessionRow().frame(width: Self.cell + Self.detail)
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
            if store.updater.showsInPill { openUpdateCell.frame(width: stripCell, height: Self.cell) }
            openGearCell
        }
        .padding(.trailing, HubGeometry.lead)
        let inbox = HStack(spacing: 0) {
            openInboxCell
            headerSlot(.inbox, owns: shrunk(.inbox)) { shrunk(.inbox) ? AnyView(collapsedInboxHeader) : AnyView(inboxHeader) }
                .padding(.leading, Theme.Metrics.contentEdge - Self.inset - Theme.Space.md)
                .padding(.trailing, Self.inset)
        }
        .padding(.leading, HubGeometry.lead)
        return HStack(spacing: 0) {
            if columns {
                inbox.frame(width: HubGeometry.leftColumn)
                Hairline(axis: .vertical, inset: 12).frame(width: HubGeometry.gutter)
                HStack(spacing: 0) {
                    headerSlot(.agents, owns: true) { agentsHeader }.padding(.trailing, Self.inset)
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
        let room = HubGeometry.stripRoom(maxLength: maxLength)
        if columns {
            let caps = stripCaps(room: room)
            // Both columns hug the strip their headers are in: along the bottom the shorter one rests on it, so its
            // rows stay next to their header and any void is at the far end, beside the footer.
            HStack(alignment: edge == .bottom ? .bottom : .top, spacing: 0) {
                leftColumn(inboxCap: caps.inbox).frame(width: HubGeometry.leftColumn)
                Hairline(axis: .vertical, inset: 12).frame(width: HubGeometry.gutter)
                rightColumn(cap: caps.sessions).frame(width: width - HubGeometry.leftColumn - HubGeometry.gutter)
            }
        } else {
            singleColumn(room: room)
        }
    }

    /// What CI takes of the left column under the inbox's list: its hairline, its header and its lines (none while
    /// searching).
    private var stripCIRoom: CGFloat {
        searching ? 0 : HubGeometry.stripRule + Theme.Metrics.pitch + max(ciHeight, Theme.Metrics.pitch)
    }

    /// What the two columns' lists may take: the inbox what CI leaves, the sessions what the inbox column's height leaves
    /// them (`HubGeometry.stripCaps`).
    func stripCaps(room: CGFloat) -> (inbox: CGFloat, sessions: CGFloat) {
        HubGeometry.stripCaps(room: room, leftFixed: stripCIRoom, inbox: listHeights[.inbox],
                              rightFixed: Theme.Metrics.pitch + ClaudeNotice.room(store), sessions: listHeights[.agents])
    }

    /// Inbox, then CI directly under it with its own header; along the bottom, the other way up (the lists keep
    /// their order, the header stays next to the strip it belongs to).
    func leftColumn(inboxCap: CGFloat) -> some View {
        let ci = ciBlock
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

    func rightColumn(cap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if edge == .bottom { newSession; stripAgents(cap: cap) } else { stripAgents(cap: cap); newSession }
        }
        .padding(.horizontal, Self.inset)
        .section("Sessions")
    }

    /// Focused: the section has the whole column, the others are their headers; along the bottom the other way up. With
    /// the sessions off the inbox and CI's lines share it: the inbox gets what CI's block leaves.
    func singleColumn(room: CGFloat) -> some View {
        let agents = store.agents.enabled
        let pitch = Theme.Metrics.pitch
        // CI's header, and its lines unless another section is focused.
        let ci = searching ? 0 : pitch + (shrunk(.ci) ? 0 : max(ciHeight, pitch))
        let sessionsHeader = agents ? pitch : 0
        let inboxCap = max(room - ci - sessionsHeader, 120)
        let agentsCap = max(room - ci - sessionsHeader - pitch - ClaudeNotice.room(store), 120)
        return VStack(alignment: .leading, spacing: 0) {
            let inbox = VStack(spacing: 0) { if !shrunk(.inbox) { stripInbox(cap: inboxCap) } }.section("Inbox")
            let ci = VStack(spacing: 0) { if !searching { ciBlock } }
            let sessions = VStack(alignment: .leading, spacing: 0) {
                if agents {
                    headerSlot(.agents) { agentsHeader }
                    if !shrunk(.agents) { stripAgents(cap: agentsCap); newSession }
                }
            }
            .section("Sessions")
            if edge == .bottom { sessions; ci; inbox } else { inbox; ci; sessions }
        }
        .padding(.horizontal, Self.inset)
    }

    var ciBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.ciRepos.isEmpty {
                noCI
            } else {
                headerSlot(.ci, owns: true) { ciHeader }
                if !shrunk(.ci) { ciColumn }
            }
        }
        .section("CI")
    }

    /// CI's rows under its header, measured: the lists around it take what is left.
    var ciColumn: some View {
        ciRows()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
    }

    var newSession: some View { newSessionRow() }

    func stripInbox(cap: CGFloat) -> some View {
        inboxBody(cap: cap)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { record(.inbox, ListHeights(shown: $0, content: $0)) }
            .onDisappear { record(.inbox, nil) }
    }

    /// The sessions one per line, by group (tile and text in one row, as in a peek). `cap`: what the rows may take,
    /// under the notice (when Claude's files are not there).
    @ViewBuilder func stripAgents(cap: CGFloat) -> some View {
        ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding)
        if noSessionsMatch { noSessionsLine }
        sessionsScroll(cap: cap)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { record(.agents, ListHeights(shown: $0, content: agentsContent)) }
            .onDisappear { record(.agents, nil) }
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
