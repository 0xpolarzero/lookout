import AppKit
import SwiftUI

// The bar's own pieces: the rows of the full view beside the bar on the sides, and the strip along the top and
// bottom, each cell next to the content it stands for.

extension LookoutHub {
    /// The rows: the bar's cells on the screen side, their content beside them. With a page open, the same cells
    /// as at rest, dimmed, and settings lit at the bottom.
    var barColumn: some View {
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
                    row(alignment: .top, cell: { tile(r, size: 22) }, detail: { sessionBlock(r, twoLines: false) })
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
    @ViewBuilder var strip: some View {
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
                if wide && showsCI && stripShowsCIHeader { ciHeader.transition(.hubReveal) }
            }
            .padding(.leading, Self.inset + 1)
            .padding(.trailing, Self.inset)
            .frame(width: wide ? columnWidth(.ci) : nil, alignment: .leading)
            .frame(maxHeight: .infinity)
            .modifier(probe(.ci))
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
                            ForEach(rows.pending) { tile($0, size: 22) }
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
