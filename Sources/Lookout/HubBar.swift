import AppKit
import SwiftUI

// The bar's own pieces: at rest, and beside a page, the same cells in the same order on every edge (`restBar`);
// kept open, the rows of the full view beside the bar on the sides and the strip along the top and bottom, each
// cell next to the content it stands for.

extension LookoutHub {
    /// The bar column on the sides: the rows of the full view, else the rail of cells (as at rest, with a page
    /// beside it: the cells are the same and never dimmed, the gear lit).
    @ViewBuilder var barColumn: some View {
        if showsDetail { openColumn } else { restBar }
    }

    /// The strip along the top and bottom: the full view's segments, else the same cells as at rest.
    @ViewBuilder var strip: some View {
        if showsDetail { openStrip } else { restBar }
    }

    /// The rows: the bar's cells on the screen side, their content beside them.
    var openColumn: some View {
        VStack(alignment: side, spacing: 0) {
            VStack(alignment: side, spacing: 0) { mainRows }
            // Last, settings and the footer. Dragging the line above them sizes the sessions' list.
            sectionDivider
            VStack(alignment: side, spacing: 0) {
                row(cell: { settingsCell.padding(.vertical, 9) }, detail: { footerDetail })
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
            row(cell: { EmptyView() }, detail: { inboxBody(cap: caps.inbox) }).padding(.bottom, 4)
        }
        sectionDivider
        // CI: its cell in the bar beside the header, then its rows (none while searching, which doesn't look in CI).
        VStack(alignment: side, spacing: 0) {
            row(cell: { ciCell }, detail: { if showsCI { ciHeader } })
            if showsCI && !shrunk(.ci) {
                row(cell: { EmptyView() }, detail: { ciRows })
                    .transition(.hubReveal)
            }
        }
        .modifier(probe(.ci))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
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
                // The tiles are part of the rows: each session's sits in the rail beside its text.
                sessionsScroll(cap: caps.agents).frame(width: Self.cell + Self.detail)
                if noSessionsMatch { row(cell: { EmptyView() }, detail: { noSessionsLine }) }
                newSessionRow().frame(width: Self.cell + Self.detail)
            }
            .transition(.hubReveal)
        }
    }

    /// Across the whole view.
    var sectionDivider: some View {
        Hairline().frame(width: rowWidth).padding(.vertical, 4)
    }

    /// The bar along the top or bottom, kept open: each segment as wide as the column under it.
    @ViewBuilder var openStrip: some View {
        HStack(spacing: 8) {
            inboxIcon
            if !shrunk(.inbox) { inboxHeader.transition(.hubReveal) }
            if shrunk(.inbox) { Spacer(minLength: 0); focusButton(.inbox) }
        }
        .padding(.leading, Self.inset + 1)
        .padding(.trailing, Self.inset)
        .frame(width: columnWidth(.inbox), alignment: .leading)
        .frame(maxHeight: .infinity)
        .modifier(probe(.inbox))
        // Without CI there is no cell, so no segment (and no second divider beside it).
        if !store.ciRepos.isEmpty {
            stripDivider
            // CI: its cell; the header only while another section is focused (else the column under it has one).
            HStack(spacing: 8) {
                ciCell
                if showsCI && stripShowsCIHeader { ciHeader.transition(.hubReveal) }
            }
            .padding(.leading, Self.inset + 1)
            .padding(.trailing, Self.inset)
            .frame(width: columnWidth(.ci), alignment: .leading)
            .frame(maxHeight: .infinity)
            .modifier(probe(.ci))
        }
        if store.agents.enabled {
            stripDivider
            HStack(spacing: 8) {
                claudeMark
                agentsHeader.transition(.hubReveal)
            }
            // The asterisk over the column's session tiles (inset, the row's 10, half a 24pt tile).
            .padding(.leading, Self.inset + 10 + 12 - 15)
            .padding(.trailing, Self.inset)
            .frame(width: columnWidth(.agents), alignment: .leading)
            .frame(maxHeight: .infinity)
            .modifier(probe(.agents))
        }
        Spacer(minLength: 0)
        HStack(spacing: 0) {
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
            if store.updater.showsInPill {
                stripDivider
                UpdateButton(updater: store.updater, horizontal: true).padding(.horizontal, 6)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if stripTrailingWidth != width { stripTrailingWidth = width }
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
                // Beside a page, the rail runs the page's height; the cells stay where they were.
                .frame(width: Self.cell)
                .frame(maxHeight: pageOpen ? .infinity : nil, alignment: .top)
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
            CIBarCell(axis: axis, store: store, show: { show(.ci) })
                .modifier(probe(.ci))
        }
        barDivider
        if store.agents.enabled {
            RestSessionCells(store: store, ui: ui, hub: hub, axis: axis, onRail: axis == .vertical, room: sessionRoom) {
                show(.agents, session: $0)
            }
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

    /// What the sessions' cells may take of the bar's length (the "+N" among them): the screen's room less the ends,
    /// the other cells, both dividers and the "+". The rest of the sessions are behind the "+N".
    var sessionRoom: CGFloat {
        let pitch = Theme.Metrics.pitch
        let others = 2 * Self.barEnd + 2 * Self.dividerSlot + 3 * pitch  // inbox, gear, "+"
            + (store.ciRepos.isEmpty ? 0 : pitch) + (store.updater.showsInPill ? pitch : 0)
        return barLength - others
    }

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

    /// A cell's `Show` (VoiceOver, and Return on a focused cell, or the "+N"): keeps the hub open on that cell's
    /// section with the selection there. CI also moves VoiceOver's focus to its header (`showCI`); the others
    /// don't yet (TODO: keyboard package).
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
            hub.showSession(session, store: store, ui: ui)
        case .ci:
            hub.showCI(store, ui: ui)
        case .controls:
            break
        }
    }
}

extension HubState {
    /// The sessions' section as a bar cell shows it: `session` (else the first) picked and scrolled to, and every
    /// session listed when it is one the list would leave out (New activity's "+N more"; the bar's "+N" stands for the
    /// first of those). The keys walk through the same rows.
    func showSession(_ id: String?, store: Store, ui: UIState) {
        query = ""
        if let id, !store.hubSessions(self).contains(where: { $0.id == id }) { sessionsExpanded = true }
        guard let id = id ?? store.hubSessions(self).first?.id else { return }
        selection = "a:" + id
        requestScroll("a:" + id)
        ui.drawerSelection = id
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
    /// Points along the bar for the tiles and the "+N" (`LookoutHub.sessionRoom`).
    let room: CGFloat
    /// Show the sessions' section, picking this session (or the first).
    let show: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let slots = store.barSlots
        let (shown, hidden) = BarSessions.arrange(slots, frozen: hub.frozenSessions, room: room)
        let byID = Dictionary(uniqueKeysWithValues: store.sessionGroups.flatMap(\.rows).map { ($0.id, $0) })
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
            if !hidden.isEmpty {
                MoreSessionsCell(axis: axis, count: hidden.count, waiting: hidden.filter(\.waiting).count) { show(hidden.first?.id) }
            }
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
        hub.frozenSessions = store.barSlots
    }
}
