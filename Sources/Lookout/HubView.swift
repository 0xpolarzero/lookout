import AppKit
import Carbon
import SwiftUI

// Lookout as one bar on a screen edge that expands, on hover, into the whole app.

enum HubPage { case main, settings, repos }

@Observable
@MainActor
final class HubState {
    var hovering = false
    var pinned = false {
        didSet {
            // Pinned or unpinned by hand on a page: that's what you want once back, not what it was before.
            if !navigating, page != .main { pinnedBeforePage = nil }
            // Just closed with the pointer still over the bar: no panel pops back open under it.
            if oldValue && !pinned { quiet = true }
        }
    }
    /// No hover panels until the pointer has left the bar (set when the full view closes).
    var quiet = false
    var page: HubPage = .main
    /// "i:<item id>" or "a:<session id>": the row the keys act on.
    var selection: String?
    var filter: InboxFilter = .needsYou {
        didSet { selection = nil }
    }
    var toast: String?
    /// Typed while the hub has the keyboard: narrows the inbox and finds sessions, kept or not.
    var query = ""
    /// Which way the last page change went, so pages slide in from the side you're heading to.
    var forward = true
    /// The page you came from, so going back retraces your steps (Repositories opened from Settings goes back
    /// there; opened from the main view, back to it).
    private(set) var previous: HubPage = .main
    /// Whether the view was pinned before a page pinned it: going back to the main view restores that.
    @ObservationIgnored private var pinnedBeforePage: Bool?
    @ObservationIgnored private var navigating = false

    /// The section the pointer is on: just that one opens beside the bar.
    var section: HubSection?
    /// Where that section's panel is (in the hub's window), so the window takes the mouse there too.
    @ObservationIgnored var panelFrame: CGRect = .zero

    /// The whole view, every section at once: kept open (right ⌘, a page, the context menu).
    var expanded: Bool { pinned }
    /// In the full view, the section given all the room it needs; the others shrink to their header (and counts).
    var focus: HubSection?

    /// Settings and Repositories pin the view, so it stays put while you type or drag; back on the main view,
    /// the pin is what it was before.
    func go(_ next: HubPage) {
        guard next != page else { return }
        forward = next.rank > page.rank
        navigating = true
        defer { navigating = false }
        if page == .main {
            pinnedBeforePage = pinned
            pinned = true
        }
        if next == .main {
            if let before = pinnedBeforePage { pinned = before }
            pinnedBeforePage = nil
        }
        previous = page
        page = next
    }

    /// One step back (Esc, the back button): to the page you came from, the main view in the end.
    func back() {
        go(page == .repos && previous == .settings ? .settings : .main)
    }
}

extension HubPage {
    var rank: Int {
        switch self {
        case .main: 0
        case .settings: 1
        case .repos: 2
        }
    }
}

/// The hub's keys, the same in the app and the playground.
@MainActor
final class HubKeys {
    let store: Store
    let ui: UIState
    let hub: HubState
    /// Unpinned and closed from the keyboard (Esc): the app hands focus back.
    var onClose: () -> Void = {}

    init(store: Store, ui: UIState, hub: HubState) {
        self.store = store
        self.ui = ui
        self.hub = hub
    }

    /// The keep-open key: opens (and keeps open), or closes.
    func toggleTap() {
        if HotKeys.debug { NSLog("Lookout keys: tap, pinned %d", hub.pinned ? 1 : 0) }
        if hub.pinned { close() } else { hub.pinned = true }
    }

    func close() {
        // Closing leaves any page: the hub opens on the main view next time.
        hub.go(.main)
        hub.query = ""
        hub.pinned = false
        hub.hovering = false
        onClose()
    }

    /// Returns whether the key was handled. Typing in a text field is left alone, except Esc.
    func key(_ event: NSEvent) -> Bool {
        let editing = event.window?.firstResponder is NSText
        if editing, event.keyCode != UInt16(kVK_Escape) { return false }
        let flags = event.modifierFlags.intersection(Shortcut.relevant)
        let shortcut = Shortcut(event)
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            if editing { event.window?.makeFirstResponder(nil) }
            else if !hub.query.isEmpty { setQuery("") }
            else if hub.page != .main { hub.back() }
            else if hub.focus != nil { withAnimation(LookoutHub.refocus) { hub.focus = nil } }
            else { close() }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            hub.go(.settings)
            return true
        }
        if shortcut == store.shortcut(.refresh) { store.refreshNow(); return true }
        guard hub.expanded, hub.page == .main else { return false }
        // Typing searches: letters and digits start it, Space and ⌫ edit it once it has started.
        if event.keyCode == UInt16(kVK_Delete), flags.isEmpty, !hub.query.isEmpty {
            setQuery(String(hub.query.dropLast()))
            return true
        }
        if flags.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }),
           !(typed == " " && hub.query.isEmpty) {
            setQuery(hub.query + typed)
            return true
        }
        let targets = targets()
        if event.keyCode == 125 || event.keyCode == 126, flags.isEmpty {
            let down = event.keyCode == 125
            let i = targets.firstIndex(of: hub.selection ?? "") ?? (down ? -1 : targets.count)
            let next = min(max(i + (down ? 1 : -1), 0), targets.count - 1)
            if targets.indices.contains(next) { select(targets[next]) }
            return true
        }
        if shortcut == store.shortcut(.markAllRead) {
            withAnimation(.easeOut(duration: 0.2)) { store.markAllRead(hub.filter) }
            return true
        }
        guard let selection = hub.selection else { return false }
        let id = String(selection.dropFirst(2))
        if selection.hasPrefix("i:"), let item = store.items.first(where: { $0.id == id }) {
            if shortcut == store.shortcut(.openItem) { store.open(item) }
            else if shortcut == store.shortcut(.toggleRead) { item.state == .unread ? store.markRead(item) : store.markUnread(item) }
            else if shortcut == store.shortcut(.discard) {
                let i = targets.firstIndex(of: selection) ?? 0
                if targets.indices.contains(i + 1) { select(targets[i + 1]) }
                withAnimation(.easeOut(duration: 0.22)) { item.state.isOpen ? store.discard(item) : store.restore(item) }
            } else { return false }
            return true
        }
        if selection.hasPrefix("a:") {
            if shortcut == store.shortcut(.openItem) { store.openAgent(id) }
            else if shortcut == store.shortcut(.toggleRead) { store.toggleAgentRead(id) }
            else if shortcut == store.shortcut(.keepSession) { withAnimation(.easeOut(duration: 0.22)) { store.keepAgent(id) } }
            else if shortcut == store.shortcut(.removeSession) { withAnimation(.easeOut(duration: 0.22)) { store.dismissAgent(id) } }
            else { return false }
            return true
        }
        return false
    }

    /// Every row the arrows walk through, top to bottom: inbox items, then sessions.
    private func targets() -> [String] {
        store.hubItems(hub).map { "i:" + $0.id } + store.hubSessions(hub).map { "a:" + $0.id }
    }

    /// A new search picks its first result, so ↩ opens it straight away.
    private func setQuery(_ query: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            hub.query = query
            // Searching looks everywhere, and what you type shows in the inbox's header: nothing stays shrunk.
            if !query.isEmpty { hub.focus = nil }
        }
        if let first = targets().first { select(first) } else { hub.selection = nil; ui.drawerSelection = nil }
    }

    func select(_ target: String) {
        hub.selection = target
        ui.drawerSelection = target.hasPrefix("a:") ? String(target.dropFirst(2)) : nil
    }
}

/// The bar and, when expanded, everything behind it: each cell of the bar stays beside the content it stands for.
struct LookoutHub: View {
    let store: Store
    let ui: UIState
    @Bindable var hub: HubState
    /// Room the expanded view may take along its edge.
    var maxLength: CGFloat = 700
    /// Where each section's cells are in the bar, and whether the pointer is on the bar or a section's panel.
    @State var sectionFrames: [HubSection: CGRect] = [:]
    @State var overBar = false
    @State var overPanel = false
    @State var peekLeave: Task<Void, Never>?
    /// The bar's size and the open panel's natural size, to place the panel against the bar's ends.
    @State var barSize: CGSize = .zero
    @State var peekSize: CGSize = .zero


    /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
    static let cell: CGFloat = 46
    /// What sits beside a cell on the sides; the inbox and agents columns along the top and bottom.
    static let detail: CGFloat = 400
    /// The one outer inset. Pieces pad their own 8 inside it, so text starts 14pt from the hub's side everywhere.
    static let inset: CGFloat = 6
    /// Along the top and bottom: the CI column, and the narrowest a page gets under the strip.
    static let ciWidth: CGFloat = 300
    static let pageWidth: CGFloat = 480
    static let opening = Animation.spring(duration: 0.38, bounce: 0.14)
    static let closing = Animation.spring(duration: 0.2, bounce: 0)

    var edge: DockEdge { ui.edge }
    var expanded: Bool { hub.expanded }
    /// Settings or Repositories showing: the bar stays as at rest, dimmed, and the page takes the rows' place.
    var pageOpen: Bool { expanded && hub.page != .main }
    /// The rows' content beside the bar (and the strip's segments at full width).
    var showsDetail: Bool { expanded && hub.page == .main }

    var body: some View {
        let shape = barOutline
        Group {
            if edge.isHorizontal { horizontal } else { vertical }
        }
        .coordinateSpace(.named(Self.barSpace))
        // Only the bar at rest is measured (for the hover panels): nothing to redo while the full view changes.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in if !hub.expanded, barSize != size { barSize = size } }
        .onHover { overBar = $0; hoverChanged() }
        .background(shape.fill(Theme.bg))
        .overlay(shape.strokeBorder(Theme.stroke))
        .clipShape(shape)
        // The hovered section's panel, outside the bar's clip; the bar's own size doesn't change.
        .overlay(alignment: peekAlignment) { peekPanel }
        // The full view's shadow comes from its outline alone (cheap to redraw as it changes); at rest, one for the
        // bar and its panel together, so the panel's doesn't fall across the bar.
        .background { shape.fill(Theme.bg).shadow(color: .black.opacity(expanded ? 0.42 : 0), radius: 20, y: 7) }
        .compositingGroup()
        .shadow(color: .black.opacity(expanded ? 0 : peeking != nil ? 0.42 : 0.22), radius: peeking != nil ? 20 : 6,
                y: peeking != nil ? 7 : 2)
        .animation(.easeOut(duration: 0.16), value: peeking)
        .fixedSize()
        // Opening has a touch of bounce; closing doesn't, so it never overshoots back past the bar.
        .animation(expanded ? Self.opening : Self.closing, value: expanded)
        .animation(.spring(duration: 0.36, bounce: 0.06), value: hub.page)
        .animation(Self.refocus, value: hub.focus)
        .contextMenu {
            Button("Keep Open") { hub.pinned = true }
            Button("Settings…") { hub.go(.settings) }
            Button("Repositories…") { hub.go(.repos) }
            if store.updater.isRelease {
                Button("Check for Updates") { Task { await store.updater.update(manual: true) } }
            }
            Divider()
            Button("Quit Lookout") { NSApp.terminate(nil) }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: ui.drawerSelection) { _, id in
            if let id, hub.selection != "a:" + id { hub.selection = "a:" + id }
        }
    }

    // MARK: Data

    var items: [InboxItem] { store.hubItems(hub) }
    var searching: Bool { !hub.query.isEmpty }
    var agentRows: (kept: [AgentRow], pending: [AgentRow]) {
        if searching { return (store.hubSessions(hub), []) }
        let rows = store.agentRows
        return (rows.kept, Array(rows.pending.prefix(PillView.pendingTiles)))
    }

    // MARK: Vertical (left / right edges)

    /// The screen's side: rows line up against it, so the bar column is straight whatever is beside it.
    var side: HorizontalAlignment { edge == .right ? .trailing : .leading }
    /// A row's width: its cell, and its content beside it when that shows.
    var rowWidth: CGFloat { showsDetail ? Self.cell + Self.detail : Self.cell }

    var vertical: some View {
        // The page slides out from under the bar column, which stays where it is.
        HStack(alignment: .top, spacing: 0) {
            if edge == .right && pageOpen { verticalPage }
            barColumn.zIndex(1)
            if edge == .left && pageOpen { verticalPage }
        }
    }

    var verticalPage: some View {
        page
            .frame(width: Self.detail)
            .modifier(FitHeight(cap: maxLength))
            .transition(.move(edge: edge == .right ? .trailing : .leading))
    }

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
                row(cell: { (expanded ? AnyView(settingsButton) : AnyView(controlsCell)).padding(.vertical, 9) },
                    detail: { footerDetail })
            }
            .modifier(probe(.controls))
        }
        // Opaque, so the page sliding out from under it doesn't show through.
        .background(Theme.bg)
    }

    /// Beside the settings cell: on the left edge, the same pieces mirrored, so pin and repositories sit by
    /// the bar on either side and the sync status out by the rounded side.
    @ViewBuilder var footerDetail: some View {
        if edge == .left {
            HStack(spacing: 9) {
                reposButton
                pinButton
                Spacer(minLength: 0)
                syncStatus
            }
            .frame(height: 40)
        } else {
            footer
        }
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
                CappedScroll(cap: caps.inbox, selection: hub.selection) {
                    VStack(alignment: side, spacing: 1) {
                        ForEach(items) { item in
                            row(cell: { EmptyView() }, detail: { itemRow(item) }).id("i:" + item.id)
                        }
                    }
                    .padding(.bottom, 4)
                    .id(searching ? "search" : hub.filter.rawValue)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.22), value: items.map(\.id))
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
                row(cell: { ciCell }, detail: { linkRow("No CI shown", action: "Choose repositories") { hub.go(.repos) } })
            } else {
                row(cell: { ciCell }, detail: { ciHeader })
                if !shrunk(.ci) {
                    ForEach(Self.ciOrder, id: \.self) { state in
                        row(cell: { ciCount(state) }, detail: { ciLine(state) })
                    }
                    .transition(.hubReveal)
                }
            }
        }
        .modifier(probe(.ci))
        // A search doesn't look in CI.
        .opacity(searching ? 0.4 : 1)
        if store.agents.enabled {
            sectionDivider
            VStack(alignment: side, spacing: 0) { agentRowsView }
                .modifier(probe(.agents))
        }
        if store.updater.showsInPill {
            row(cell: { UpdateButton(updater: store.updater, horizontal: false).padding(.vertical, 4) },
                detail: { Text(updateText).font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 8) })
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder var agentRowsView: some View {
        row(cell: { agentsCell }, detail: { agentsHeader })
        if showsDetail && shrunk(.agents) {
            EmptyView()
        } else if showsDetail {
            Group {
                // The sessions scroll with their tiles, so each stays beside its row.
                CappedScroll(cap: caps.agents, selection: hub.selection) { sessionRows }
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
            ForEach(rows.kept) { r in
                // Its first line level with the tile; what it did, or what it left running, under it.
                row(alignment: .top, cell: { tile(r, size: 26) }, detail: { sessionBlock(r, twoLines: false) })
                    .id("a:" + r.id)
            }
            if !rows.pending.isEmpty {
                row(cell: { Capsule().fill(Color.white.opacity(0.12)).frame(width: 14, height: 1.5).frame(height: 14) },
                    detail: { pendingLabel.padding(.horizontal, 8) })
                ForEach(rows.pending) { r in
                    row(alignment: .top, cell: { tile(r, size: 22) }, detail: { sessionBlock(r, twoLines: false) })
                        .id("a:" + r.id)
                }
            }
        }
    }

    var pendingLabel: some View {
        Text("PENDING").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.tertiary)
    }

    /// Heights the two lists may scroll within: what's left once the fixed parts are laid out, inbox first.
    /// With a section focused, it takes everything the shrunk sections' headers leave.
    var caps: (inbox: CGFloat, agents: CGFloat) {
        switch hub.focus {
        case .inbox: (max(160, maxLength - 260), 0)
        case .agents: (0, max(144, maxLength - 260))
        default: sharedCaps
        }
    }

    /// No section focused: what's left once the fixed parts are laid out, inbox first.
    var sharedCaps: (inbox: CGFloat, agents: CGFloat) {
        let free = max(160, maxLength - 360)
        guard store.agents.enabled else { return (free, 0) }
        // Whole 36pt session rows, so the last one showing is never cut through its tile.
        let agents = max(2, (free * 0.45 / 36).rounded(.down)) * 36
        return (free - agents, agents)
    }

    /// Across the whole view when expanded; a short rule centred in the bar at rest.
    var sectionDivider: some View {
        Rectangle().fill(Theme.stroke)
            .frame(width: showsDetail ? Self.cell + Self.detail : Self.cell - 24, height: 1)
            .frame(width: rowWidth)
            .padding(.vertical, 4)
    }

    // MARK: Horizontal (top / bottom edges)

    var horizontal: some View {
        // The strip and what's under it share one width, so the strip's trailing group sits at the far end.
        SharedWidthStack {
            if edge == .bottom { horizontalBody }
            HStack(alignment: .center, spacing: 0) { strip }
                .frame(height: Self.cell)
                .zIndex(1)
            if edge == .top { horizontalBody }
        }
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
            // CI: its icon and title on the left like the agents', then its counts.
            HStack(spacing: 2) {
                ciCell
                // 6 more than the 2 between the counts: the title as far from its icon as the agents'.
                if wide {
                    Text("CI").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .padding(.leading, 6).padding(.trailing, 2).transition(.hubReveal)
                }
                ForEach(Self.ciOrder, id: \.self) { ciCount($0) }
                if wide { Spacer(minLength: 0); focusButton(.ci) }
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
                    agentsCell
                    if wide && shrunk(.agents) {
                        // Shrunk: just its counts, like CI's.
                        let counts = store.agentCounts
                        dotCount(counts.blocked, Theme.amber)
                        dotCount(counts.done, Theme.accent)
                        Spacer(minLength: 0)
                        focusButton(.agents)
                    } else if wide {
                        agentsHeader.transition(.hubReveal)
                    } else {
                        // (At rest: the tiles.)
                        let rows = agentRows
                        ForEach(rows.kept) { tile($0, size: 26) }
                        if !rows.pending.isEmpty {
                            Capsule().fill(Color.white.opacity(0.12)).frame(width: 1.5, height: 14)
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
        if expanded {
            Spacer(minLength: 0)
            stripDivider
            HStack(spacing: 2) {
                pinButton
                reposButton
                settingsButton
            }
            .padding(.horizontal, Self.inset + 2)
            .transition(.hubReveal)
        }
        if store.updater.showsInPill {
            stripDivider
            UpdateButton(updater: store.updater, horizontal: true).padding(.horizontal, 6)
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
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 22)
    }

    @ViewBuilder var horizontalBody: some View {
        if expanded {
            Group {
                if hub.page == .main {
                    // GitHub on the left (the inbox, CI under it), the sessions on the right; a focused section has
                    // the whole width to itself. The strip above keeps its segments whatever's focused.
                    VStack(spacing: 0) {
                        if let focus = hub.focus {
                            // The strip's width, never its text's.
                            focusedBody(focus).frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 0) {
                                    inboxColumn
                                    Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 12)
                                    ciColumn
                                }
                                .frame(width: Self.githubWidth, alignment: .topLeading)
                                if store.agents.enabled {
                                    columnDivider
                                    // As wide as its segment (with the controls after it), whatever its text would like.
                                    agentsColumn.frame(minWidth: columnWidth(.agents), idealWidth: columnWidth(.agents),
                                                       maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                            // As tall as the taller side, so the sessions' column reaches the bottom (its new
                            // session row with it).
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                                            removal: .opacity.animation(.easeIn(duration: 0.1))))
                } else {
                    page
                        .modifier(FitHeight(cap: maxLength - Self.cell))
                        .frame(idealWidth: Self.pageWidth, maxWidth: .infinity)
                        // Settles toward the strip as it fades in.
                        .transition(.opacity.combined(with: .offset(y: edge == .top ? -8 : 8)))
                }
            }
            .overlay(alignment: edge == .top ? .top : .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
            .transition(.hubReveal)
        }
    }

    var columnDivider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 12)
    }

    /// The inbox's list along the top and bottom: what's left once CI's lines are under it.
    var inboxColumn: some View {
        CappedScroll(cap: max(160, maxLength - Self.cell - 150), selection: hub.selection) {
            VStack(spacing: 1) {
                if items.isEmpty { emptyInbox }
                ForEach(items) { itemRow($0).id("i:" + $0.id) }
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 8)
            .id(searching ? "search" : hub.filter.rawValue)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.22), value: items.map(\.id))
        }
    }

    var ciColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.ciRepos.isEmpty {
                linkRow("No CI shown", action: "Choose repositories") { hub.go(.repos) }
            } else {
                // The state's name starts each line, coloured; its count is in the strip above.
                ForEach(Self.ciOrder, id: \.self) { ciLine($0) }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 8)
        .opacity(searching ? 0.4 : 1)
    }

    /// The sessions along the top and bottom: one column, or two once there are enough to make the view tall (so
    /// it doesn't stretch past what the inbox needs).
    var agentsColumn: some View {
        agentsGrid(columns: agentRows.kept.count + agentRows.pending.count > 5 ? 2 : 1)
    }

    func agentsGrid(columns: Int) -> some View {
        let rows = agentRows
        let grid = Array(repeating: GridItem(.flexible(minimum: 260), spacing: 4, alignment: .top), count: columns)
        return VStack(alignment: .leading, spacing: 0) {
            CappedScroll(cap: maxLength - Self.cell - 60, selection: hub.selection) {
                // One grid, so no hole is left before the pending ones (their smaller, dimmer tiles say what they are).
                LazyVGrid(columns: grid, alignment: .leading, spacing: 2) {
                    ForEach(rows.kept + rows.pending) { twoLineRow($0) }
                }
                .padding(.horizontal, Self.inset)
                .padding(.top, 8)
            }
            // At the bottom, whatever height the column gets.
            Spacer(minLength: 0)
            NewSessionRow(store: store, style: .twoLines)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func twoLineRow(_ r: AgentRow) -> some View {
        sessionBlock(r, twoLines: true).id("a:" + r.id)
    }

    // MARK: Focus

    static let refocus = Animation.spring(duration: 0.34, bounce: 0.06)

    /// Shrunk to its header because another section is focused (in the full view only).
    func shrunk(_ section: HubSection) -> Bool {
        showsDetail && hub.focus != nil && hub.focus != section
    }

    /// Along the top and bottom, the strip's segments: the inbox's and CI's together span the GitHub column under
    /// them; the sessions' (with the controls after it) spans theirs, wider when they come in two columns.
    func columnWidth(_ section: HubSection) -> CGFloat {
        switch section {
        case .inbox: 380
        case .ci: Self.githubWidth - 380 - 1
        default: agentRows.kept.count + agentRows.pending.count > 5 ? 430 : 260
        }
    }

    static let githubWidth: CGFloat = 580

    /// Along the top and bottom, a focused section across the whole width, in as many columns as fit.
    @ViewBuilder func focusedBody(_ section: HubSection) -> some View {
        switch section {
        case .inbox:
            CappedScroll(cap: maxLength - Self.cell - 16, selection: hub.selection) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6, alignment: .top), GridItem(.flexible(), spacing: 6, alignment: .top)],
                          alignment: .leading, spacing: 1) {
                    ForEach(items) { itemRow($0).id("i:" + $0.id) }
                }
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 8)
            }
            .overlay(alignment: .topLeading) { if items.isEmpty { emptyInbox.padding(Self.inset) } }
        case .ci:
            ciColumn
        default:
            agentsGrid(columns: 3)
        }
    }


    /// A count with its colour's dot, as CI's in the bar.
    func dotCount(_ n: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(n == 0 ? Theme.tertiary : color).frame(width: 7, height: 7)
            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(n == 0 ? Theme.tertiary : Theme.text)
        }
    }

    /// A section header's button: give this section all the room (the others shrink to their header), or back.
    func focusButton(_ section: HubSection) -> some View {
        let focused = hub.focus == section
        return IconButton(symbol: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: focused ? "Back to all sections" : "Make room for this",
                          detail: focused ? "Esc" : "The other sections shrink to their counts",
                          size: IconButton.Size.header) {
            withAnimation(Self.refocus) { hub.focus = focused ? nil : section }
        }
    }

    /// A session in the full view: its line, then (short) what it did and what it left running. One block: it
    /// highlights, opens and shows its actions as a whole, wherever the pointer is on it.
    func sessionBlock(_ r: AgentRow, twoLines: Bool) -> some View {
        let selected = ui.drawerSelection == r.id
        return VStack(alignment: .leading, spacing: 0) {
            DrawerRow(row: r, store: store, ui: ui, number: 0, twoLines: twoLines, highlight: hub.query,
                      showsKept: searching, inHub: !twoLines, plain: true)
            // Under the title: past the tile on two-line rows (10 + 24 + 9), else at the title's 8.
            sessionDetails(r)
                .padding(.leading, twoLines ? 43 : 8)
                .padding(.trailing, 8)
                .padding(.top, twoLines ? -4 : -3)
                .padding(.bottom, 7)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.06 : 0)))
        // The same actions as an inbox item's, over the title line's right end, centred on it.
        .overlay(alignment: .topTrailing) {
            if selected {
                AgentActions(row: r, store: store, size: IconButton.Size.row)
                    .padding(.top, twoLines ? 9 : 0)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(r.id) }
        .onHover { if $0 { ui.drawerSelection = r.id } }
    }

    /// At most two short lines: the turn's summary, and what's still running after it.
    @ViewBuilder func sessionDetails(_ r: AgentRow) -> some View {
        let summary = r.session.running ? nil : r.session.summary?.detail
        if summary?.isEmpty == false || !r.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if let summary, !summary.isEmpty {
                    // The summary is Markdown (**bold**, `code`): shown as such, on one line.
                    Text((try? AttributedString(markdown: summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(summary))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                if !r.tasks.isEmpty { RunningLine(tasks: r.tasks) }
            }
        }
    }
}

/// Stacks its views top to bottom, all as wide as the widest: along the top and bottom, the strip spans whatever
/// is under it (columns or a page) and the columns span the strip.
struct SharedWidthStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.reduce(0, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for sub in subviews {
            let height = sub.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            sub.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

/// As tall as its content, up to `cap`; a scroll view inside scrolls past that.
struct FitHeight: ViewModifier {
    let cap: CGFloat

    func body(content: Content) -> some View {
        CapHeightLayout(cap: cap) { content }
    }
}

private struct CapHeightLayout: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        let width = proposal.width ?? sub.sizeThatFits(.unspecified).width
        let height = sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, cap))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
