import AppKit
import SwiftUI

// The bar's own pieces: at rest, the same cells in the same order on every edge (`restBar`); kept open, the rows
// of the full view beside the bar on the sides and the strip along the top and bottom, each cell next to the
// content it stands for.

extension LookoutHub {
    /// The bar column on the sides: the rail of cells at rest, the rows of the full view otherwise.
    @ViewBuilder var barColumn: some View {
        if expanded { openColumn } else { restBar }
    }

    /// The strip along the top and bottom: the same cells at rest, the full view's segments otherwise.
    @ViewBuilder var strip: some View {
        if expanded { openStrip } else { restBar }
    }

    /// The rows: the bar's cells on the screen side, their content beside them. With a page open, the same cells
    /// as at rest, dimmed, and settings lit at the bottom.
    var openColumn: some View {
        VStack(alignment: side, spacing: 0) {
            VStack(alignment: side, spacing: 0) { mainRows }
                .opacity(pageOpen ? 0.5 : 1)
            // Last, the controls: a gear at rest (hover for pin, repositories, settings), settings and the
            // footer once open. In the full view, dragging the line above them sizes the sessions' list.
            sectionDivider
            VStack(alignment: side, spacing: 0) {
                row(cell: { Group { if expanded { settingsCell } else { controlsCell } }.padding(.vertical, 9) },
                    detail: { footerDetail })
            }
            .modifier(probe(.controls))
        }
        // Opaque, so the page sliding out from under it doesn't show through.
        .background(Theme.bg)
    }

    /// One line of the expanded view: the bar's cell on the screen side, its content beside it. The cell always
    /// takes its width, empty or not, so content lines up whether or not its row has something in the bar.
    @ViewBuilder
    func row<Cell: View, Detail: View>(alignment: VerticalAlignment = .center, @ViewBuilder cell: () -> Cell,
                                       @ViewBuilder detail: () -> Detail) -> some View {
        let slot = ZStack {
            Color.clear.frame(width: Self.cell, height: 0)
            cell()
        }
        .frame(width: Self.cell)
        HStack(alignment: alignment, spacing: 0) {
            if edge == .left { slot }
            if showsDetail {
                detail()
                    // The one outer inset, against the rounded side; the bar's cells sit on the other.
                    .padding(edge == .right ? .leading : .trailing, Self.inset)
                    .frame(width: Self.detail, alignment: .leading)
                    .transition(.hubReveal)
            }
            if edge == .right { slot }
        }
    }

    @ViewBuilder var mainRows: some View {
        // Inbox
        VStack(alignment: side, spacing: 0) {
            row(cell: { inboxIcon.padding(.top, 2).padding(.bottom, 4) }, detail: { inboxHeader.padding(.top, 6) })
        }
        .modifier(probe(.inbox))
        if showsDetail && !shrunk(.inbox) {
            Group {
                if items.isEmpty {
                    row(cell: { EmptyView() }, detail: { emptyInbox })
                }
                CappedScroll(cap: caps.inbox, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
                    AdaptiveStack(count: items.count, alignment: side, spacing: 1) {
                        ForEach(items) { item in
                            row(cell: { EmptyView() }, detail: { itemRow(item) }).capEdge().id("i:" + item.id)
                        }
                    }
                    .padding(.bottom, 4)
                    .id(searching ? "search" : hub.filter.rawValue)
                    .transition(.opacity)
                    .motion(Theme.Motion.fade, value: listKey)
                }
                // Its own width, so a scroller can't widen it and push its rows off the bar's column.
                .frame(width: Self.cell + Self.detail)
            }
            .transition(.hubReveal)
        }
        sectionDivider
        // CI: its header, then one line per state, its count in the bar beside the repos in it.
        VStack(alignment: side, spacing: 0) {
            if store.ciRepos.isEmpty {
                row(cell: { ciCell }, detail: { linkRow("No CI configured", action: "Choose repositories") { hub.go(.repos) } })
            } else {
                row(cell: { ciCell }, detail: { ciHeader })
                if !shrunk(.ci) {
                    ForEach(Self.ciLineOrder, id: \.self) { state in
                        if state != CIState.none || !ciRepos(listedIn: .none).isEmpty {
                            row(cell: { ciCount(state) }, detail: { ciLine(state) })
                        }
                    }
                    .transition(.hubReveal)
                }
            }
        }
        .modifier(probe(.ci))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
        // A search doesn't look in CI.
        .opacity(searching ? 0.4 : 1)
        if store.agents.enabled {
            sectionDivider
            VStack(alignment: side, spacing: 0) { agentRowsView }
                .modifier(probe(.agents))
        }
        if store.updater.showsInPill {
            row(cell: { UpdateButton(updater: store.updater, horizontal: false).padding(.vertical, 4) },
                detail: { Text(updateText).font(Theme.Typography.control).foregroundStyle(Theme.secondary).padding(.horizontal, 8) })
                .transition(.opacity)
        }
    }

    @ViewBuilder var agentRowsView: some View {
        row(cell: { claudeMark }, detail: { agentsHeader })
        if showsDetail { row(cell: { EmptyView() }, detail: { ClaudeNotice(store: store).padding(.horizontal, Theme.Space.md) }) }
        if showsDetail && shrunk(.agents) {
            EmptyView()
        } else if showsDetail {
            Group {
                // The sessions scroll with their tiles, so each stays beside its row.
                CappedScroll(cap: caps.agents, hub: hub) { sessionRows }
                    .frame(width: Self.cell + Self.detail)
                row(cell: { newSessionCell }, detail: { newSessionDetail })
            }
            .transition(.hubReveal)
        } else {
            sessionRows
        }
    }

    @ViewBuilder var sessionRows: some View {
        let rows = agentRows
        VStack(alignment: side, spacing: 0) {
            // By project, a line between projects, and draggable onto one another, as along the top and bottom.
            let starts = projectStarts(rows.kept)
            ForEach(rows.kept) { r in
                // Its first line level with the tile; what it did, or what it left running, under it.
                row(alignment: .top, cell: { tile(r, size: 26) }, detail: { sessionBlock(r, twoLines: false) })
                    .modifier(ReorderIf(enabled: showsDetail, row: r, store: store))
                    .modifier(GroupRule(on: showsDetail && starts.contains(r.id)))
                    .capEdge()
                    .id("a:" + r.id)
            }
            if !rows.pending.isEmpty {
                row(cell: { Capsule().fill(Theme.Fill.selected).frame(width: 14, height: 1.5).frame(height: 14) },
                    detail: { pendingLabel(twoLines: false) })
                ForEach(rows.pending) { r in
                    row(alignment: .top, cell: { tile(r, size: 26) }, detail: { sessionBlock(r, twoLines: false) })
                        .capEdge()
                        .id("a:" + r.id)
                }
            }
        }
    }

    /// The kept sessions that begin a project's run after the first (none when searching): a line goes above each.
    /// Rows stay keyed by their own session, so reordering never rebuilds them.
    func projectStarts(_ kept: [AgentRow]) -> Set<String> {
        guard !searching else { return [] }
        var starts: Set<String> = []
        for (prev, next) in zip(kept, kept.dropFirst()) where prev.session.folderKey != next.session.folderKey {
            starts.insert(next.id)
        }
        return starts
    }

    /// "New activity", aligned with the text of the rows under it (two-line rows pad 10, one-line 8).
    func pendingLabel(twoLines: Bool) -> some View {
        Text("New activity").font(Theme.Typography.label).foregroundStyle(Theme.secondary)
            .padding(.leading, twoLines ? 10 : 8)
    }

    /// Across the whole view when expanded; a short rule centred in the bar at rest.
    var sectionDivider: some View {
        Hairline()
            .frame(width: showsDetail ? Self.cell + Self.detail : Self.cell - 24)
            .frame(width: rowWidth)
            .padding(.vertical, 4)
    }

    /// The bar along the top or bottom: each segment as wide as the column under it once expanded; with a page
    /// open, back to their size at rest, dimmed.
    @ViewBuilder var openStrip: some View {
        let wide = showsDetail
        Group {
            HStack(spacing: 8) {
                inboxIcon
                if wide && !shrunk(.inbox) { inboxHeader.transition(.hubReveal) }
                if wide && shrunk(.inbox) { Spacer(minLength: 0); focusButton(.inbox) }
            }
            .padding(.leading, Self.inset + 1)
            .padding(.trailing, Self.inset)
            .frame(width: wide ? columnWidth(.inbox) : nil, alignment: .leading)
            .frame(maxHeight: .infinity)
            .modifier(probe(.inbox))
            stripDivider
            // CI: its icon, then the same header as the others (title, status, one expand button); its counts at rest.
            HStack(spacing: 8) {
                ciCell
                if wide && shrunk(.ci) {
                    // Shrunk: the counts fit where the header's words wouldn't.
                    HStack(spacing: 2) { ForEach(Self.ciOrder, id: \.self) { ciCount($0) } }
                    Spacer(minLength: 0)
                    focusButton(.ci)
                } else if wide {
                    ciHeader.transition(.hubReveal)
                } else {
                    HStack(spacing: 2) { ForEach(Self.ciOrder, id: \.self) { ciCount($0) } }
                }
            }
            .padding(.leading, Self.inset + 1)
            .padding(.trailing, Self.inset)
            .frame(width: wide ? columnWidth(.ci) : nil, alignment: .leading)
            .frame(maxHeight: .infinity)
            .modifier(probe(.ci))
            .opacity(searching ? 0.4 : 1)
            if store.agents.enabled {
                stripDivider
                HStack(spacing: 8) {
                    claudeMark
                    if wide {
                        agentsHeader.transition(.hubReveal)
                    } else {
                        // (At rest: the tiles.)
                        let rows = agentRows
                        ForEach(rows.kept) { tile($0, size: 26) }
                        if !rows.pending.isEmpty {
                            Capsule().fill(Theme.Fill.selected).frame(width: 1.5, height: 14)
                            ForEach(rows.pending) { tile($0, size: 26) }
                        }
                    }
                }
                // The asterisk over the column's session tiles (inset, the row's 10, half a 24pt tile).
                .padding(.leading, Self.inset + 10 + 12 - 15)
                .padding(.trailing, Self.inset)
                .frame(width: wide ? columnWidth(.agents) : nil, alignment: .leading)
                .frame(maxHeight: .infinity)
                .modifier(probe(.agents))
            }
        }
        .opacity(pageOpen ? 0.5 : 1)
        if !expanded {
            stripDivider
            controlsCell
                .padding(.horizontal, Self.inset)
                .frame(maxHeight: .infinity)
                .modifier(probe(.controls))
        }
        if expanded { Spacer(minLength: 0) }
        HStack(spacing: 0) {
            if expanded {
                // The rate limit shows here whatever's focused (the sync status itself is in the controls' panel).
                RateNotice(store: store, fill: false).lineLimit(1).padding(.trailing, Self.inset)
                stripDivider
                HStack(spacing: 2) {
                    pinButton
                    reposButton
                    settingsCell
                }
                .padding(.horizontal, Self.inset + 2)
                .transition(.hubReveal)
            }
            if store.updater.showsInPill {
                stripDivider
                UpdateButton(updater: store.updater, horizontal: true).padding(.horizontal, 6)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if expanded, stripTrailingWidth != width { stripTrailingWidth = width }
        }
    }

    var updateText: String {
        let version = store.updater.release?.version ?? ""
        return switch store.updater.phase {
        case .ready: "Lookout \(version) is ready · click to restart into it"
        case .downloading: "Downloading Lookout \(version)…"
        case .installing: "Installing…"
        case .failed(let error): "Update failed · \(error)"
        default: "Lookout \(version) is available"
        }
    }

    var stripDivider: some View {
        Hairline(axis: .vertical).frame(height: 22)
    }
}

// MARK: - At rest

extension LookoutHub {
    /// The bar's own axis: vertical on the sides, horizontal along the top and bottom.
    var barAxis: Axis { edge.isHorizontal ? .horizontal : .vertical }
    /// Space at both ends of the bar along its axis, so a tile sits as far from the rounded end as from the sides.
    static let barEnd = (Theme.Metrics.bar - Theme.Metrics.pitch) / 2

    /// One order on every edge (DESIGN.md 5.1): Inbox, CI | sessions, + | Update, Gear. Side edges stack it on the
    /// rail; along the top and bottom it runs left to right.
    @ViewBuilder var restBar: some View {
        let axis = barAxis
        if axis == .vertical {
            VStack(spacing: 0) { restCells }
                .padding(.vertical, Self.barEnd)
                .frame(width: Self.cell)
                .background(Theme.rail)
        } else {
            HStack(spacing: 0) { restCells }
                .padding(.horizontal, Self.barEnd)
                .frame(height: Self.cell)
        }
    }

    @ViewBuilder var restCells: some View {
        let axis = barAxis
        InboxBarCell(axis: axis, needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots),
                     show: { show(.inbox) }, action: openInbox)
            .modifier(probe(.inbox))
        if !store.ciRepos.isEmpty {
            let summary = CIBarSummary.make(repos: store.ciRepos, status: store.ci, muted: store.mutedCI)
            CIBarCell(axis: axis, summary: summary, show: { show(.ci) }, action: {
                if let repo = summary.open { store.openChecks(repo) } else { show(.ci) }
            })
            .modifier(probe(.ci))
        }
        barDivider
        if store.agents.enabled {
            RestSessionCells(store: store, ui: ui, hub: hub, axis: axis, onRail: axis == .vertical) { show(.agents, session: $0) }
                .modifier(probe(.agents))
            barDivider
        }
        if store.updater.showsInPill {
            UpdateBarCell(axis: axis, updater: store.updater) { hub.go(.settings) }
        }
        GearBarCell(axis: axis, store: store, hub: hub) { show(.controls) }
            .modifier(probe(.controls))
    }

    /// One hairline grammar: 18pt long, 9pt of room each side, whichever way the bar runs.
    var barDivider: some View {
        Group {
            if barAxis == .vertical {
                Hairline().frame(width: 18).frame(width: Self.cell, height: Self.dividerSlot)
            } else {
                Hairline(axis: .vertical).frame(height: 18).frame(width: Self.dividerSlot, height: Self.cell)
            }
        }
        .accessibilityHidden(true)
    }
    static let dividerSlot: CGFloat = 19

    /// The inbox cell's click: straight to what needs you, its newest item picked so the keys act on it at once.
    func openInbox() {
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

    /// A cell's `Show` (VoiceOver, and Return on a focused cell): keeps the hub open on that cell's section with
    /// the selection there. TODO(keyboard package): move VoiceOver focus into the section as well.
    func show(_ section: HubSection, session: String? = nil) {
        withAnimation(Self.opening.resolved(reduce: reduce)) {
            hub.go(.main)
            hub.focus = nil
            hub.pinned = true
        }
        switch section {
        case .inbox:
            openInbox()
        case .agents:
            if let id = session ?? store.agentRows.kept.first?.id ?? store.agentRows.pending.first?.id {
                hub.selection = "a:" + id
                ui.drawerSelection = id
            }
        case .ci, .controls:
            break
        }
    }
}

/// The session cells of the bar at rest: their tiles by group, the "+N", the "+". The order and the groups they
/// show are frozen while the pointer is over the hub (a session's marks still update) and applied, with a fade,
/// once it leaves.
struct RestSessionCells: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let axis: Axis
    let onRail: Bool
    /// Show the sessions' section, picking this session (or the first).
    let show: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let rows = store.agentRows
        let slots = BarSessions.slots(kept: rows.kept, pending: rows.pending)
        let (shown, hidden) = BarSessions.arrange(slots, frozen: hub.frozenSessions)
        let byID = Dictionary(uniqueKeysWithValues: (rows.kept + rows.pending).map { ($0.id, $0) })
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            if slots.isEmpty { SessionsAnchorCell(axis: axis) { show(nil) } }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, slot in
                if let row = byID[slot.id] {
                    BarTile(row: row, axis: axis, onRail: onRail, store: store, ui: ui, hub: hub) { show(row.id) }
                        .padding(axis == .vertical ? .top : .leading, BarSessions.gap(shown, before: index))
                        .transition(.opacity)
                }
            }
            if hidden > 0 { MoreSessionsCell(axis: axis, count: hidden) { show(nil) } }
            NewSessionBarCell(axis: axis, store: store) { show(nil) }
        }
        .animation(reduce ? nil : Theme.Motion.fade, value: shown.map { $0.id + $0.group })
        .onAppear { if hub.hovering { freeze() } }
        .onDisappear { hub.frozenSessions = nil }
        .onChange(of: hub.hovering) { _, over in
            if over { freeze() } else { hub.frozenSessions = nil }
        }
    }

    /// Keeps the order and the groups as they are now, whatever the sessions do until the pointer leaves.
    private func freeze() {
        let rows = store.agentRows
        hub.frozenSessions = BarSessions.slots(kept: rows.kept, pending: rows.pending)
    }
}

/// The sessions' side panel under its header: one 36pt row beside each of the bar's tiles, in the bar's order,
/// with the bar's gap (and a line in it) between groups and the new session row beside the "+", so every row
/// stays level with its tile.
struct PeekSessionRows: View {
    let store: Store
    let ui: UIState
    let hub: HubState

    var body: some View {
        let rows = store.agentRows
        let shown = BarSessions.arrange(BarSessions.slots(kept: rows.kept, pending: rows.pending),
                                        frozen: hub.frozenSessions, visible: .max).shown
        let byID = Dictionary(uniqueKeysWithValues: (rows.kept + rows.pending).map { ($0.id, $0) })
        let pending = Set(rows.pending.map(\.id))
        VStack(alignment: .leading, spacing: 0) {
            // (The bar's asterisk stands here until there is a session.)
            if shown.isEmpty { Color.clear.frame(height: Theme.Metrics.pitch) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, slot in
                if let row = byID[slot.id] {
                    let gap = BarSessions.gap(shown, before: index)
                    if gap > 0 { Hairline(inset: 8).frame(height: gap) }
                    DrawerRow(row: row, store: store, ui: ui, number: 0, inHub: true)
                        .frame(height: Theme.Metrics.pitch)
                        .sessionMenu(row, store)
                        .modifier(ReorderIf(enabled: !pending.contains(row.id), row: row, store: store))
                }
            }
            NewSessionRow(store: store, style: .detail).frame(height: Theme.Metrics.pitch)
        }
    }
}
