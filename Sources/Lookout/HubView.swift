import AppKit
import SwiftUI

// Lookout as one bar on a screen edge that expands, on hover, into the whole app.

enum HubPage { case main, settings, repos }

@Observable
@MainActor
final class HubState {
    var hovering = false
    /// The bar's session cells as the pointer found them, held while it is over the hub (see `BarSessions`).
    var frozenSessions: [BarSessions.Slot]?
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
    /// The last row the keyboard (or a click on the inbox) picked: the lists scroll to it. Never set by hovering, so
    /// the pointer moving over a row doesn't move the list.
    var keyboardSelection: ScrollRequest?
    var filter: InboxFilter = .needsYou {
        didSet { selection = nil; keyboardSelection = nil }
    }
    /// Asks the lists to scroll to a row, even one asked for before (a new request every time).
    func requestScroll(_ id: String) {
        keyboardSelection = ScrollRequest(id: id, seq: (keyboardSelection?.seq ?? 0) + 1)
    }
    @ObservationIgnored var sessionMemo = SessionSearchMemo()
    /// The last search's results (see `Store.hubItems`).
    @ObservationIgnored var searchMemo = SearchMemo()
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
    /// The bar is being carried to another edge: no panels meanwhile.
    @ObservationIgnored var dragging = false
    @ObservationIgnored private var dwell: Task<Void, Never>?

    /// The pointer entered a section. The first panel waits for the pointer to settle (so sweeping along the edge
    /// opens nothing); once one is open, moving to another section switches at once, with no transition.
    func enter(_ next: HubSection) {
        dwell?.cancel()
        guard !dragging else { return }
        if section != nil {
            guard section != next else { return }
            var instant = Transaction(animation: nil)
            instant.disablesAnimations = true
            withTransaction(instant) { section = next }
            return
        }
        dwell = Task { [weak self] in
            try? await Task.sleep(for: Theme.Timing.dwell)
            if !Task.isCancelled, self?.dragging == false { self?.section = next }
        }
    }

    /// The pointer left a section before it settled: nothing opens.
    func cancelDwell() { dwell?.cancel() }

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

/// The bar and, when expanded, everything behind it: each cell of the bar stays beside the content it stands for.
struct LookoutHub: View {
    let store: Store
    let ui: UIState
    @Bindable var hub: HubState
    /// Room the expanded view may take along its edge.
    var maxLength: CGFloat = 700
    /// The window's width: along the top and bottom, the sessions' column takes what the screen has left.
    var maxWidth: CGFloat = .infinity
    /// Room for the bar at rest along its own axis, whatever is open: the screen's height on the sides, its width
    /// along the top and bottom, less the margins. The sessions' cells give way to it (`sessionRoom`).
    var barLength: CGFloat = .infinity
    /// Where each section's cells are in the bar, and whether the pointer is on the bar or a section's panel.
    @State var sectionFrames: [HubSection: CGRect] = [:]
    @State var overBar = false
    @State var overPanel = false
    @State var peekLeave: Task<Void, Never>?
    /// The bar's size and the open panel's natural size, to place the panel against the bar's ends.
    @State var barSize: CGSize = .zero
    /// The CI block's measured height: what it takes beyond its usual few lines comes off the inbox's room.
    @State var ciHeight: CGFloat = 0
    static let ciUsual: CGFloat = 150
    var ciExtra: CGFloat { max(0, ciHeight - Self.ciUsual) }
    @State var peekSizes: [HubSection: CGSize] = [:]
    /// The strip's trailing group (controls, update button) as laid out, for the sessions' segment to leave room
    /// for; a first guess until it's measured.
    @State var stripTrailingWidth: CGFloat = 140
    @Environment(\.accessibilityReduceMotion) var reduce

    /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
    static let cell = Theme.Metrics.bar
    /// What sits beside a cell on the sides; the inbox and agents columns along the top and bottom.
    static let detail: CGFloat = 400
    /// The one outer inset. Pieces pad their own 8 inside it, so text starts 14pt from the hub's side everywhere.
    static let inset = Theme.Metrics.inset
    /// Along the top and bottom: the CI column, and the narrowest a page gets under the strip.
    static let ciWidth: CGFloat = 300
    static let pageWidth: CGFloat = 480
    /// How many pending sessions the hub lists before the rest stay hidden.
    static let pendingTiles = 4
    /// The hub's one coordinate space name (the hosting root's).
    static let rootSpace = "hub-root"
    /// Animations: pass through `.motion` / `.resolved(reduce:)`, which follow Reduce Motion live.
    static let opening = Theme.Motion.move
    static let closing = Theme.Motion.close
    static let pageSpring = Theme.Motion.move
    static let refocus = Theme.Motion.move
    /// The system's current setting, for code with no view (key handlers): read only through `animate`.
    private static var reduceNow: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `withAnimation` for code with no view (key handlers), following Reduce Motion.
    static func animate(_ animation: Animation = Theme.Motion.fade, _ body: () -> Void) {
        withAnimation(animation.resolved(reduce: reduceNow), body)
    }

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
        // Shadows come from shapes alone, in a layer under the bar and its panel (never a blurred composite of their
        // content, which would be redone on every frame of anything animating inside): the panel's can't fall
        // across the bar, which is opaque above it.
        .background(alignment: peekAlignment) { peekShadow }
        .background {
            shape.fill(Theme.bg)
                .shadow(color: .black.opacity(expanded ? 0.42 : peeking != nil ? 0.42 : 0.22),
                        radius: expanded || peeking != nil ? 20 : 6, y: expanded || peeking != nil ? 7 : 2)
        }
        .motion(Theme.Motion.fade, value: peeking != nil)
        .fixedSize()
        // Opening has a touch of bounce; closing doesn't, so it never overshoots back past the bar.
        .motion(expanded ? Self.opening : Self.closing, value: expanded)
        .motion(Self.pageSpring, value: hub.page)
        .motion(Self.refocus, value: hub.focus)
        .contextMenu {
            Toggle("Keep Open", isOn: $hub.pinned)
            Button("Settings…") { hub.go(.settings) }
            Button("Repositories…") { hub.go(.repos) }
            if store.updater.isRelease {
                Button("Check for Updates") { Task { await store.updater.update(manual: true) } }
            }
            Divider()
            Button("Quit Lookout") { NSApp.terminate(nil) }
        }
        .environment(\.colorScheme, .dark)
        .themeResolved()
        .background(SelectionSync(ui: ui, hub: hub))
    }

    // MARK: Data

    var items: [InboxItem] { store.hubItems(hub) }
    var searching: Bool { !hub.query.isEmpty }
    /// What the inbox list animates on: its items changing, or the filter or search swapping them.
    struct ListKey: Equatable { let revision: Int; let filter: InboxFilter; let query: String }
    var listKey: ListKey { ListKey(revision: store.itemsRevision, filter: hub.filter, query: hub.query) }
    var agentRows: (kept: [AgentRow], pending: [AgentRow]) {
        if searching { return (store.hubSessions(hub), []) }
        let rows = store.agentRows
        return (rows.kept, Array(rows.pending.prefix(Self.pendingTiles)))
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
            // (Reduce Motion: no slide, but still a short fade.)
            .transition(reduce ? .opacity.animation(Theme.Motion.fade) : .slide(from: edge == .right ? .trailing : .leading, reduce: false))
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
        let free = max(160, maxLength - 360 - ciExtra)
        guard store.agents.enabled else { return (free, 0) }
        // Whole 36pt session rows, so the last one showing is never cut through its tile.
        let agents = max(2, (free * 0.45 / 36).rounded(.down)) * 36
        return (free - agents, agents)
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

    @ViewBuilder var horizontalBody: some View {
        if expanded {
            Group {
                if hub.page == .main {
                    // GitHub on the left (the inbox, CI under it), the sessions on the right; a focused section has
                    // the whole width to itself. The strip above keeps its segments whatever's focused.
                    VStack(spacing: 0) {
                        if let focus = hub.focus {
                            // The strip's width, never its text's.
                            focusedBody(focus).frame(minWidth: Self.ciWidth, idealWidth: Self.ciWidth, maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                // CI at the bottom (level with the new session row): the room between is the inbox's.
                                VStack(alignment: .leading, spacing: 0) {
                                    inboxColumn
                                    Spacer(minLength: 0)
                                    Hairline(inset: 12)
                                    ciColumn
                                }
                                .frame(width: Self.githubWidth, alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .top)
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
                    .transition(.asymmetric(insertion: .opacity.animation(Theme.Motion.fade.delay(0.1)),
                                            removal: .opacity.animation(Theme.Motion.hover)))
                } else {
                    page
                        .modifier(FitHeight(cap: maxLength - Self.cell))
                        .frame(idealWidth: Self.pageWidth, maxWidth: .infinity)
                        // Settles toward the strip as it fades in.
                        .transition(reduce ? .opacity.animation(Theme.Motion.fade)
                                    : .opacity.combined(with: .offset(y: edge == .top ? -8 : 8)))
                }
            }
            .overlay(alignment: edge == .top ? .top : .bottom) { Hairline() }
            .transition(.hubReveal)
        }
    }

    var columnDivider: some View {
        Hairline(axis: .vertical, inset: 12)
    }

    /// The sessions along the top and bottom: one per line, read top to bottom like the inbox beside them.
    var agentsColumn: some View {
        let rows = agentRows
        return VStack(alignment: .leading, spacing: 0) {
            // Directly under the Sessions header (in the strip above).
            ClaudeNotice(store: store).padding(.horizontal, Self.inset + 8)
            CappedScroll(cap: min(maxLength - Self.cell - 60, Self.listCap + 90), hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(rows.kept.count + rows.pending.count)) {
                // Your sessions by project, a line between projects; then the pending ones, labelled.
                AdaptiveStack(count: rows.kept.count + rows.pending.count, alignment: .leading, spacing: 0) {
                    let starts = projectStarts(rows.kept)
                    ForEach(rows.kept) { r in
                        if starts.contains(r.id) { groupDivider }
                        twoLineRow(r).modifier(AgentReorder(row: r, store: store))
                    }
                    if !rows.pending.isEmpty {
                        if !rows.kept.isEmpty { groupDivider }
                        pendingLabel(twoLines: true).padding(.bottom, 4)
                        ForEach(rows.pending) { twoLineRow($0) }
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.top, 8)
            }
            // At the bottom, whatever height the column gets; a line keeps a row the list cuts off from running into
            // the new session row.
            Spacer(minLength: 0)
            Hairline(inset: Self.inset + 10).padding(.bottom, Theme.Space.xs)
            NewSessionRow(store: store, style: .twoLines)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func twoLineRow(_ r: AgentRow) -> some View {
        sessionBlock(r, twoLines: true).capEdge().id("a:" + r.id)
    }

    /// A line between one project's sessions and the next's.
    var groupDivider: some View {
        Hairline(inset: 10).padding(.vertical, Theme.Space.xs)
    }

    // MARK: Focus

    /// Shrunk to its header because another section is focused (in the full view only).
    func shrunk(_ section: HubSection) -> Bool {
        showsDetail && hub.focus != nil && hub.focus != section
    }

    /// Along the top and bottom, the strip's segments: the inbox's and CI's together span the GitHub column under
    /// them; the sessions' (with the controls after it) spans theirs.
    func columnWidth(_ section: HubSection) -> CGFloat {
        switch section {
        case .inbox: return Self.inboxSegment
        case .ci: return Self.githubWidth - Self.inboxSegment - 1
        default:
            // As much as the screen has left after the measured controls and update button, and the margins.
            let room = maxWidth - Self.githubWidth - 1 - stripTrailingWidth - 2 * Self.inset
            return max(Self.agentsMin, min(Self.detail, room))
        }
    }

    static let githubWidth: CGFloat = 570
    /// The inbox's segment of that column (CI's takes the rest), and the narrowest the sessions' column gets.
    static let inboxSegment: CGFloat = 370
    static let agentsMin: CGFloat = 260
    /// Along the top and bottom, the lists scroll past this, so the view stays compact.
    static let listCap: CGFloat = 300

    /// Along the top and bottom, a focused section across the whole width: the inbox in two columns.
    @ViewBuilder func focusedBody(_ section: HubSection) -> some View {
        switch section {
        case .inbox:
            CappedScroll(cap: maxLength - Self.cell - 16, hub: hub, lazy: true) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.sm, alignment: .top), GridItem(.flexible(), spacing: Theme.Space.sm, alignment: .top)],
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
            agentsColumn
        }
    }


    /// A section header's button: give this section all the room (the others shrink to their header), or back.
    func focusButton(_ section: HubSection) -> some View {
        let focused = hub.focus == section
        return IconButton(symbol: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: focused ? "Back to all sections" : "Expand \(section.name)",
                          detail: focused ? "Esc" : "The other sections shrink to their counts") {
            withAnimation(Self.refocus.resolved(reduce: reduce)) { hub.focus = focused ? nil : section }
        }
    }

    /// A session in the full view (see `SessionBlock`).
    func sessionBlock(_ r: AgentRow, twoLines: Bool) -> some View {
        SessionBlock(row: r, twoLines: twoLines, store: store, ui: ui, hub: hub)
    }
}

/// Stacks its views top to bottom, all as wide as the widest: along the top and bottom, the strip spans whatever
/// is under it (columns or a page) and the columns span the strip.
struct SharedWidthStack: Layout {
    /// What's been measured this pass: the widest's width, and every subview's height at one width.
    struct Cache {
        var width: CGFloat?
        var heightsAt: CGFloat?
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func width(_ subviews: Subviews, _ cache: inout Cache) -> CGFloat {
        if let width = cache.width { return width }
        let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        cache.width = width
        return width
    }

    private func heights(_ subviews: Subviews, at width: CGFloat, _ cache: inout Cache) -> [CGFloat] {
        if cache.heightsAt == width { return cache.heights }
        cache.heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        cache.heightsAt = width
        return cache.heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = width(subviews, &cache)
        return CGSize(width: width, height: heights(subviews, at: width, &cache).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for (sub, height) in zip(subviews, heights(subviews, at: bounds.width, &cache)) {
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


/// Your sessions in the hub can be dragged onto one another to reorder them (pending ones can't).
struct AgentReorder: ViewModifier {
    let row: AgentRow
    let store: Store
    @State private var target = false

    func body(content: Content) -> some View {
        content
            .modifier(Reorderable(row: row, store: store, dropTarget: $target))
            .overlay(Theme.Radius.shape(Theme.Radius.row).strokeBorder(target ? Theme.accent : .clear, lineWidth: 1.5))
    }
}

/// A line along a row's top edge, taking no room of its own: between projects, the rows stay level with the bar's tiles.
struct GroupRule: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if on { Hairline(inset: 8) }
        }
    }
}

/// Under the Sessions header: Claude's session files missing or unreadable (nothing when all is well).
struct ClaudeNotice: View {
    let store: Store

    var body: some View {
        switch store.claudeLink {
        case .missing, .unreadable:
            HStack(spacing: 6) { ClaudeLinkStatus(store: store) }
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.xs)
        default:
            EmptyView()
        }
    }
}
