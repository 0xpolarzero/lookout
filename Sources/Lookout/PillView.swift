import AppKit
import SwiftUI

struct PillView: View {
    let store: Store
    let ui: UIState
    let actions: PillActions
    @State private var ripple = false

    /// How many pending tiles fit before a "+N" tile takes over.
    static let pendingTiles = 4

    var body: some View {
        // Vertical on the left/right edges, horizontal when docked to the top or bottom.
        let horizontal = ui.edge.isHorizontal
        let stack = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        stack {
            group {
                inboxButton
            }
            if !store.ciRepos.isEmpty {
                group {
                    (horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 6))) {
                        ForEach([CIState.success, .failure, .pending], id: \.self) { state in
                            ciCount(state)
                        }
                    }
                    .padding(horizontal ? .horizontal : .vertical, horizontal ? 6 : 8)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggle(.ci) }
                }
            }
            if store.agents.enabled {
                group { agentStrip }
                    .onHover { actions.hoverAgents($0) }
            }
            if store.updater.showsInPill {
                group { UpdateButton(updater: store.updater, horizontal: horizontal) }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.updater.showsInPill)
        // No menu bar icon, so the pill carries the app menu (its update button keeps its own).
        .contextMenu {
            Button("Open Inbox") { actions.toggle(.inbox) }
            Button("Settings…") { actions.toggle(.settings) }
            if store.updater.isRelease {
                Button("Check for Updates") { Task { await store.updater.update(manual: true) } }
            }
            Divider()
            Button("Quit Lookout") { NSApp.terminate(nil) }
        }
        .padding(2)
        .fixedSize()
        // Tile positions in window coordinates: the drawer (its own window, beside the pill) lines its rows up with them.
        .coordinateSpace(.named(PillSpace.name))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { ui.pillSize = $0 }
        .environment(\.colorScheme, .dark)
        .environment(\.systemHelp, true)
        .onChange(of: store.pulse) {
            ripple = false
            withAnimation(.easeOut(duration: 1.1)) { ripple = true }
        }
    }

    // MARK: Agents

    private var expanded: Bool { store.agents.expanded || ui.switcher }

    private var agentStrip: some View {
        let horizontal = ui.edge.isHorizontal
        let rows = store.agentRows
        let axis = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        return axis {
            IconButton(symbol: "asterisk", help: "Agents", size: 28, tint: Theme.claude,
                       active: ui.isOpen && ui.tab == .agents) { actions.toggle(.agents) }
                .overlay(alignment: .bottomTrailing) {
                    if store.claudeLink == .missing || store.claudeLink == .unreadable {
                        badgeIcon("exclamationmark", Theme.red).offset(x: 4, y: 4).help("Can't read Claude's sessions")
                    }
                }
            if expanded {
                // One run of tiles per project, with a little more room between projects than within one.
                ForEach(store.groups(rows.kept), id: \.first!.id) { group in
                    (horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))) {
                        ForEach(group) { row in tile(row, size: 26) }
                    }
                    .padding(horizontal ? .horizontal : .vertical, 3)
                }
                if !rows.pending.isEmpty {
                    if !rows.kept.isEmpty {
                        Capsule().fill(Color.white.opacity(0.12))
                            .frame(width: horizontal ? 1.5 : 14, height: horizontal ? 14 : 1.5)
                    }
                    ForEach(rows.pending.prefix(Self.pendingTiles)) { row in tile(row, size: 22) }
                    if rows.pending.count > Self.pendingTiles {
                        moreTile(rows.pending.count - Self.pendingTiles)
                    }
                }
            } else {
                let counts = store.agentCounts
                agentCount(counts.blocked, Theme.amber, "waiting for you", rows) { $0.status == .blocked }
                agentCount(counts.done, Theme.accent, "done, unread", rows) { $0.status == .finished }
            }
            Button { store.agents.expanded.toggle() } label: {
                Image(systemName: horizontal ? (expanded ? "chevron.left" : "chevron.right") : (expanded ? "chevron.up" : "chevron.down"))
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: horizontal ? 14 : 28, height: horizontal ? 28 : 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Show counts" : "Show your sessions")
        }
        .padding(horizontal ? .horizontal : .vertical, 2)
    }

    private func tile(_ row: AgentRow, size: CGFloat) -> some View {
        Button { store.openAgent(row.id) } label: {
            AgentTile(row: row, size: size, selected: ui.drawerOpen && ui.drawerSelection == row.id)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { ui.drawerSelection = row.id } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillSpace.name)) } action: { ui.tileFrames[row.id] = $0 }
    }

    private func moreTile(_ count: Int) -> some View {
        Button { actions.toggle(.agents) } label: {
            Text("+\(count)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6.6, style: .continuous).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help("\(count) more pending · open Agents")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillSpace.name)) } action: { ui.tileFrames[AgentDrawer.moreID] = $0 }
    }

    private func agentCount(_ count: Int, _ color: Color, _ label: String, _ rows: (kept: [AgentRow], pending: [AgentRow]),
                            _ filter: (AgentRow) -> Bool) -> some View {
        let names = (rows.kept + rows.pending).filter(filter).map(\.session.title)
        return HStack(spacing: 5) {
            Circle().fill(count == 0 ? Theme.tertiary : color).frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(count == 0 ? Theme.tertiary : Theme.text)
        }
        .frame(width: 32, height: 16)
        .contentShape(Rectangle())
        .onTapGesture { actions.toggle(.agents) }
        .help(names.isEmpty ? "Nothing \(label)" : "\(label.capitalized):\n" + names.joined(separator: "\n"))
    }

    private var inboxButton: some View {
        let unread = store.unreadCount(.needsYou)
        let botUnread = store.unreadCount(.bots)
        return IconButton(symbol: unread > 0 ? "tray.full.fill" : "tray.fill", help: "Inbox (\(store.shortcut(.togglePanel).display))", size: 32,
                          tint: unread > 0 ? Theme.text : Theme.secondary,
                          active: ui.isOpen && ui.tab == .inbox) {
            actions.toggle(.inbox)
        }
        .background(
            Circle()
                .stroke(Theme.amber, lineWidth: 2)
                .scaleEffect(ripple ? 1.9 : 1)
                .opacity(ripple ? 0 : 0.9)
                .opacity(store.pulse == 0 ? 0 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                countBadge(unread, fill: Theme.amber, text: Color.black.opacity(0.85))
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // Bots get the same count, muted, on the other corner so it still shows beside the amber one.
        .overlay(alignment: unread > 0 ? .topLeading : .topTrailing) {
            if botUnread > 0 {
                countBadge(botUnread, fill: Color.white.opacity(0.28), text: Theme.text)
                    .offset(x: unread > 0 ? -1 : 5, y: -5)
                    .help("\(botUnread) from bots")
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) { statusBadge.offset(x: 4, y: 4) }
        .animation(.spring(duration: 0.3), value: unread)
        .animation(.spring(duration: 0.3), value: botUnread)
    }

    private func countBadge(_ count: Int, fill: Color, text: Color) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(text)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(fill))
    }

    /// One row per CI state with the number of repos in it; hover lists them.
    private func ciCount(_ state: CIState) -> some View {
        let repos = store.ciRepos(in: state)
        let names = repos.map { "\($0.fullName) (\(store.ci[$0.fullName]?.branch ?? "main"))" }
        return HStack(spacing: 5) {
            CIDot(state: repos.isEmpty ? .none : state, size: 7)
            Text("\(repos.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(repos.isEmpty ? Theme.tertiary : Theme.text)
        }
        .frame(width: 32, height: 16)
        .help(repos.isEmpty ? "No repos \(state.label)" : "\(state.label.capitalized) on main:\n" + names.joined(separator: "\n"))
    }

    /// Settings live in the panel; the pill only surfaces problems and snooze.
    @ViewBuilder private var statusBadge: some View {
        if store.authError != nil || !store.repoErrors.isEmpty {
            badgeIcon("exclamationmark", Theme.red)
                .help(store.authError ?? "Some repositories failed to sync")
        } else if store.isSnoozed {
            badgeIcon("moon.fill", Theme.purple).help("Notifications snoozed")
        }
    }

    private func badgeIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: 14, height: 14)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(Capsule(style: .continuous).fill(Theme.bg))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A new release, fetched in the background: an icon that says what it is on hover; click to restart into it
/// (or to download it, with a ring for progress, if that didn't happen on its own). Right-click for the release
/// notes or to skip that version.
private struct UpdateButton: View {
    let updater: Updater
    let horizontal: Bool
    @State private var hover = false

    var body: some View {
        let version = updater.release?.version ?? ""
        Button { updater.advance() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(Color.white.opacity(hover ? 0.08 : 0))
                    if case .downloading(let fraction) = updater.phase {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 2).padding(3)
                        Circle().trim(from: 0, to: max(0.03, fraction))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(3)
                            .animation(.linear(duration: 0.2), value: fraction)
                    }
                    if updater.phase == .installing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 28, height: 28)
                if horizontal && hover {
                    Text(label(version))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.trailing, 8)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
        .help(help(version))
        .contextMenu {
            if let page = updater.release?.page {
                Button("What's new in \(version)") { NSWorkspace.shared.open(page) }
            }
            Button("Skip \(version)") { updater.skip() }
        }
    }

    private var symbol: String {
        switch updater.phase {
        case .ready: "arrow.clockwise"
        case .failed: "exclamationmark"
        default: "arrow.down"
        }
    }

    private var tint: Color {
        switch updater.phase {
        case .ready: Theme.green
        case .failed: Theme.red
        case .downloading: Theme.secondary
        default: Theme.accent
        }
    }

    private func label(_ version: String) -> String {
        switch updater.phase {
        case .downloading(let fraction): "\(Int(fraction * 100))%"
        case .ready, .installing: "Restart to update"
        case .failed: "Retry update"
        default: "Update to \(version)"
        }
    }

    private func help(_ version: String) -> String {
        switch updater.phase {
        case .available: "Lookout \(version) is available\nClick to download it · right-click for more"
        case .downloading(let fraction): "Downloading Lookout \(version)… \(Int(fraction * 100))%"
        case .ready: "Lookout \(version) is ready\nClick to restart into it"
        case .installing: "Installing Lookout \(version)…"
        case .failed(let message): "Update failed: \(message)\nClick to try again"
        case .idle: ""
        }
    }
}

enum PillSpace {
    static let name = "pill"
}

/// Full titles for the strip's tiles, in a window of its own next to the pill (so opening it never resizes the
/// pill). Beside a vertical pill it's exactly as tall as the pill and each row sits level with its tile; under or
/// over a horizontal one it's a list, each row repeating its tile.
struct AgentDrawer: View {
    let store: Store
    @Bindable var ui: UIState
    let showAgents: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @State private var bubbleHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0

    static let moreID = "more"
    static let width: CGFloat = 300
    private let rowHeight: CGFloat = 30

    private var rows: [AgentRow] {
        let all = store.agentRows
        return all.kept + all.pending.prefix(PillView.pendingTiles)
    }

    private var morePending: Int { max(0, store.agentRows.pending.count - PillView.pendingTiles) }

    var body: some View {
        Group {
            if ui.switcher && !ui.switcherQuery.isEmpty { search }
            else if ui.edge.isHorizontal { listWithCard } else { aligned }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.systemHelp, true)
    }

    // MARK: Beside a vertical pill

    private var aligned: some View {
        let height = ui.pillSize.height
        let placed: [(id: String, row: AgentRow?, y: CGFloat)] =
            rows.compactMap { row in ui.tileFrames[row.id].map { (row.id, row, $0.midY) } }
            + (morePending > 0 ? ui.tileFrames[Self.moreID].map { [(Self.moreID, nil, $0.midY)] } ?? [] : [])
        let top = max(0, (placed.map(\.y).min() ?? 0) - rowHeight / 2 - 6)
        let bottom = min(height, (placed.map(\.y).max() ?? 0) + rowHeight / 2 + 6)
        let selected = placed.first { $0.id == ui.drawerSelection }
        return ZStack(alignment: .topLeading) {
            // Hover is tracked on the panel and its rows together: on the panel alone, the rows (drawn over it)
            // would read as leaving it.
            if !placed.isEmpty {
                ZStack(alignment: .topLeading) {
                    panelShape.frame(width: Self.width, height: bottom - top)
                    ForEach(Array(placed.enumerated()), id: \.element.id) { index, item in
                        Group {
                            if let row = item.row {
                                DrawerRow(row: row, store: store, ui: ui, number: index)
                            } else {
                                moreRow
                            }
                        }
                        .frame(width: Self.width - 12, height: rowHeight)
                        .offset(x: 6, y: item.y - rowHeight / 2 - top)
                    }
                }
                .frame(width: Self.width, height: bottom - top, alignment: .topLeading)
                .onHover(perform: onHover)
                .offset(y: top)
            }
            // New sessions in the listed projects, right under the rows.
            if showsBar(placed.isEmpty) {
                newSessionBar
                    .padding(6)
                    .frame(width: Self.width)
                    .background(panelShape)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .onHover(perform: onHover)
                    .offset(y: bottom + 6)
            }
            // The selected session's summary goes in a card under the drawer, never over other rows.
            if let row = selected?.row, let detail = detail(row) {
                bubble(row, detail)
                    .frame(width: Self.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                    .offset(y: bottom + barSpace + 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.width, height: max(height, alignedBottom(bottom, empty: placed.isEmpty, card: hasCard(selected?.row))),
               alignment: .topLeading)
    }

    private func showsBar(_ empty: Bool) -> Bool { !empty }

    /// Room the new-session bar takes under the rows (with its gap).
    private var barSpace: CGFloat { barHeight + 6 }

    private func alignedBottom(_ bottom: CGFloat, empty: Bool, card: Bool) -> CGFloat {
        let below = (showsBar(empty) ? barSpace : 0) + (card ? 6 + bubbleHeight : 0)
        return below > 0 ? bottom + below : 0
    }

    private func hasCard(_ row: AgentRow?) -> Bool {
        row.flatMap(detail) != nil
    }

    // MARK: Type to find (switcher)

    /// Every session matching what you type, kept or not, best first.
    private var search: some View {
        let results = store.searchSessions(ui.switcherQuery)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Text(ui.switcherQuery).font(.system(size: 13))
                Rectangle().fill(Theme.accent).frame(width: 1.5, height: 15)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .padding(.bottom, 4)
            if results.isEmpty {
                Text("No session matches").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 10).frame(height: 36)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                DrawerRow(row: row, store: store, ui: ui, number: index, twoLines: true, highlight: ui.switcherQuery,
                          showsKept: true)
            }
        }
        .padding(6)
        .frame(width: Self.width + 20)
        .background(panelShape)
    }

    // MARK: Under or over a horizontal pill

    private var list: some View {
        let all = store.agentRows
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index == all.kept.count && !all.kept.isEmpty {
                    Text("PENDING")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                }
                DrawerRow(row: row, store: store, ui: ui, number: index, twoLines: true)
            }
            if morePending > 0 { moreRow.frame(height: rowHeight) }
            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 4).padding(.vertical, 4)
            newSessionBar
        }
        .padding(6)
        .frame(width: Self.width + 20)
        .background(panelShape)
        .onHover(perform: onHover)
    }

    /// The list with the same summary card as beside a vertical pill: in a slot of fixed height under it (over it
    /// when docked at the bottom), so rows never move and the window doesn't resize while you go down the list.
    private var listWithCard: some View {
        let selected = rows.first { $0.id == ui.drawerSelection }
        let slot = ZStack(alignment: ui.edge == .bottom ? .bottom : .top) {
            Color.clear.frame(width: Self.width + 20, height: cardSpace)
            if let row = selected, let detail = detail(row) {
                bubble(row, detail)
                    .frame(width: Self.width + 20)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
            }
        }
        return VStack(spacing: 6) {
            if ui.edge == .bottom { slot }
            list
            if ui.edge != .bottom { slot }
        }
    }

    /// Room kept for the summary card under (or over) the list, so the window doesn't resize while you move along it.
    private var cardSpace: CGFloat { 80 }

    private var panelShape: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }

    /// "New session": a scratch one (no folder) on the row, or one in a listed project from its tile.
    private var newSessionBar: some View {
        NewSessionRow(store: store).frame(height: rowHeight)
    }

    private var moreRow: some View {
        Button(action: showAgents) {
            HStack {
                Text("\(morePending) more pending").foregroundStyle(Theme.secondary)
                Spacer()
                Text("Open Agents").foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ row: AgentRow) -> String? {
        guard !row.session.running, let detail = row.session.summary?.detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// The agent's own summary of where it stopped (with the folder, which the one-line rows leave out).
    private func bubble(_ row: AgentRow?, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let row {
                Text(row.session.folderName).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(3)
        }
        .padding(.horizontal, row == nil ? 10 : 14)
        .padding(.vertical, row == nil ? 7 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Inline in the list it's a soft inset; under the aligned drawer it's a card like the drawer itself.
        .background(RoundedRectangle(cornerRadius: row == nil ? 9 : 14, style: .continuous).fill(row == nil ? Color(white: 0.14) : Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: row == nil ? 9 : 14, style: .continuous)
            .strokeBorder(row == nil ? Color.white.opacity(0.08) : Theme.stroke))
    }
}

private struct DrawerRow: View {
    let row: AgentRow
    let store: Store
    @Bindable var ui: UIState
    let number: Int
    /// Under/over a horizontal pill: tile, title, then project and status on a second line.
    var twoLines = false
    /// Search: the words to highlight in the title.
    var highlight: String?
    /// Search results mix kept sessions and others: say which aren't in your list.
    var showsKept = false

    var body: some View {
        let selected = ui.drawerSelection == row.id
        HStack(spacing: 9) {
            if ui.switcher && number < 9 {
                Text("\(number + 1)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            if twoLines { AgentTile(row: row, size: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: row.unread ? .semibold : .regular))
                    .foregroundStyle(row.unread || row.session.running ? Theme.text : Theme.text.opacity(0.72))
                    .lineLimit(1)
                if twoLines {
                    HStack(spacing: 4) {
                        ProjectLabel(session: row.session, color: row.color).foregroundStyle(Theme.tertiary)
                        Text("·").foregroundStyle(Theme.tertiary)
                        status
                        if showsKept && !row.entry.kept {
                            Text("· not in your list").foregroundStyle(Theme.tertiary)
                        }
                    }
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)

            if selected {
                AgentActions(row: row, store: store, size: 22)
            } else if !twoLines {
                // What a working agent is doing matters more than the end of its title.
                status.font(.system(size: 10.5).monospacedDigit()).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: row.session.running ? 170 : 110, alignment: .trailing)
                    .fixedSize(horizontal: row.session.running, vertical: false)
                    .layoutPriority(row.session.running ? 2 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, selected ? 3 : 10)
        .frame(height: twoLines ? 44 : nil)
        .frame(maxHeight: twoLines ? 44 : .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.white.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(row.id) }
        .onHover { if $0 { ui.drawerSelection = row.id } }
    }

    /// The title, with what you typed picked out.
    private var title: AttributedString {
        var text = AttributedString(row.session.title)
        let lower = row.session.title.lowercased()
        for word in (highlight ?? "").lowercased().split(separator: " ") {
            var from = lower.startIndex
            while let range = lower.range(of: word, range: from..<lower.endIndex) {
                if let r = Range(NSRange(range, in: lower), in: text) { text[r].foregroundColor = Theme.amber }
                from = range.upperBound
            }
        }
        return text
    }

    @ViewBuilder private var status: some View {
        if row.session.running {
            WorkingText(row: row)
        } else {
            Text(row.pending && !row.unread ? (row.entry.kept || showsKept ? row.statusText : "pending") : row.statusText)
                .foregroundStyle(row.statusColor)
        }
    }
}

/// The drawer's last row: a new scratch session on the row itself, one in a listed project from its tile, and
/// every option by name in the menu when there are more projects than tiles.
private struct NewSessionRow: View {
    let store: Store
    @State private var hover = false

    static let maxTiles = 4

    var body: some View {
        let folders = store.agentFolders
        HStack(spacing: 5) {
            Button(action: Self.startScratch) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hover ? Theme.text : Theme.secondary)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(hover ? 0.14 : 0.08)))
                    Text("New session").font(.system(size: 12.5)).foregroundStyle(hover ? Theme.text : Theme.secondary)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help("New Claude session in scratch (no folder)")

            let shown = Array(folders.prefix(Self.maxTiles))
            let initials = Self.initials(shown.map { URL(fileURLWithPath: $0).lastPathComponent })
            ForEach(Array(shown.enumerated()), id: \.element) { i, folder in
                ProjectTile(folder: folder, initials: initials[i], color: store.projectColor(folder)) { store.startAgent(in: folder) }
            }
            if folders.count > Self.maxTiles { menu(folders) }
        }
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.white.opacity(0.08) : .clear))
    }

    private func menu(_ folders: [String]) -> some View {
        Menu {
            Button("Scratch (no folder)", action: Self.startScratch)
            Divider()
            ForEach(folders, id: \.self) { folder in
                Button(URL(fileURLWithPath: folder).lastPathComponent) { store.startAgent(in: folder) }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.tertiary)
        .frame(width: 20, height: 22)
        .help("New session in…")
    }

    /// Two letters per project, told apart from the others shown: the first letters of its first two words
    /// ("lcu-research" → LR), else its first two; on a clash, its first and last.
    static func initials(_ names: [String]) -> [String] {
        func first(_ name: String) -> String {
            let words = name.split { !$0.isLetter && !$0.isNumber }
            if words.count >= 2 { return String([words[0].first!, words[1].first!]) }
            return String(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        }
        var out = names.map { first($0).uppercased() }
        for i in out.indices where out.firstIndex(of: out[i]) != i {
            let letters = names[i].filter { $0.isLetter || $0.isNumber }
            if let a = letters.first, let b = letters.last { out[i] = String([a, b]).uppercased() }
        }
        return out.map { $0.isEmpty ? "?" : $0 }
    }

    /// The app's new-session link with no folder opens its composer with none picked: a scratch session.
    static func startScratch() {
        guard let url = URL(string: "claude://code/new") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A listed project in the new-session row: its colour, its initials, its name on hover.
private struct ProjectTile: View {
    let folder: String
    let initials: String
    let color: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            Text(initials)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(color == nil ? Theme.text.opacity(0.88) : Color.black.opacity(0.78))
                .frame(width: 22, height: 22)
                .background(shape.fill(color ?? Color.white.opacity(0.1)))
                .opacity(hover ? 1 : 0.8)
                .overlay { if hover { shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5).padding(-2.5) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("New Claude session in \(name) (\((folder as NSString).abbreviatingWithTildeInPath))")
    }
}
