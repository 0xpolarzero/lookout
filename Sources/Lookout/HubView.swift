import AppKit
import SwiftUI

// Lookout as one bar on a screen edge that expands, on hover, into the whole app. This file composes it: the surface,
// the bar at rest with its peek, the page beside it, and the full view (HubOpen.swift).

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
            if oldValue && !pinned {
                quiet = true
                sessionsExpanded = false
            }
        }
    }
    /// No hover panels until the pointer has left the bar (set when the full view closes).
    var quiet = false
    var page: HubPage = .main
    /// The Settings pane that is open: the page header's tabs set it, the form shows it.
    var settingsPane: SettingsPane = .general
    /// "i:<item id>", "c:<repo>" or "a:<session id>": the row the keys act on.
    var selection: String?
    /// The last row the keyboard (or a click on the inbox) picked: the lists scroll to it. Never set by hovering, so
    /// the pointer moving over a row doesn't move the list.
    var keyboardSelection: ScrollRequest?
    /// CI's Passing row is open in place (it also is while CI is the focused section).
    var ciPassingOpen = false
    /// CI is folded to its header because the screen leaves no room for its rows (`LookoutHub.foldsCI`): they aren't
    /// targets while they aren't drawn. Set by the full view's layout.
    var ciFolded = false
    /// Where VoiceOver's cursor is asked to go (a bar cell's Show, the hub opening); the view with that key answers it.
    var voiceOverRequest: VoiceOverRequest?
    /// Which controls have the Tab ring: the key monitor leaves them Return and Space (see `HubKeys.key`).
    @ObservationIgnored let controls = ControlFocus()
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
    /// The inbox header's search field and scroll state (see HubInbox.swift).
    let inbox = InboxState()
    /// New activity shows all its rows, not the first few and "+N more".
    var sessionsExpanded = false
    /// Every session is listed: "+N more" was asked for, or Sessions is the focused section (only an unfocused list is cut
    /// at eight, DESIGN.md 5.3).
    var listsAllSessions: Bool { sessionsExpanded || focus == .agents }
    /// The row whose context menu the keyboard asked for (see `HubKeys.openRowMenu`); the row with that key answers it.
    private(set) var rowMenuRequest: RowMenuRequest?
    func openRowMenu(_ target: String) { rowMenuRequest = RowMenuRequest(target: target, seq: (rowMenuRequest?.seq ?? 0) + 1) }
    /// Asks New session to open its menu of projects (→ on that row); a new request every time.
    private(set) var projectsMenuRequest = 0
    func openProjectsMenu() { projectsMenuRequest += 1 }
    /// Which way the last page change went, so pages slide in from the side you're heading to.
    var forward = true
    /// The page you came from, so going back retraces your steps (Repositories opened from Settings goes back
    /// there; opened from the main view, back to it).
    private(set) var previous: HubPage = .main
    /// Whether the view was pinned before a page pinned it: going back to the main view restores that.
    @ObservationIgnored private var pinnedBeforePage: Bool?
    @ObservationIgnored private var navigating = false

    /// The section the pointer is on: just that one opens beside the bar.
    var section: HubSection? {
        didSet { if section != .controls { menuKeys = false } }
    }
    /// The controls menu was asked for by VoiceOver ("Show controls") and has the keyboard: ↑↓ walk its rows, Return does
    /// one and Esc closes it. `menuPick` is the highlighted row.
    var menuKeys = false
    var menuPick = ControlsRow.keepOpen
    /// The bar is being carried to another edge: no panels meanwhile.
    @ObservationIgnored var dragging = false
    @ObservationIgnored private var dwell: Task<Void, Never>?

    /// The pointer entered a section. The first panel waits for the pointer to settle (so sweeping along the edge
    /// opens nothing); once one is open, moving to another section switches at once, with no transition. Not while the
    /// controls menu has the keyboard: it stays up (with its keys) until Esc or a row closes it.
    func enter(_ next: HubSection) {
        dwell?.cancel()
        guard !dragging, !menuKeys else { return }
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
    var focus: HubSection? {
        // A pick in a section that just shrank is no longer a row the keys may act on.
        didSet { if let selection, !isVisible(selection) { self.selection = nil; keyboardSelection = nil } }
    }

    /// Whether a section's rows show: all of them do, unless another section is the focused one.
    func shows(_ section: HubSection) -> Bool { focus == nil || focus == section }

    /// Whether the row a pick names ("i:" an inbox item, "c:" CI, "a:" a session, "s:" the list's own rows) is on screen.
    func isVisible(_ target: String) -> Bool {
        switch target.prefix(2) {
        case "i:": shows(.inbox)
        case "c:": shows(.ci)
        default: shows(.agents)
        }
    }

    /// A section's header (or ⌘1/2/3) gives it all the room; the same again, or ⌘0, gives it back.
    func toggleFocus(_ section: HubSection) {
        guard section != .controls, page == .main, expanded else { return }
        LookoutHub.animate(LookoutHub.refocus) { focus = focus == section ? nil : section }
    }

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

    /// One step back (Esc, Done): to the page you came from, the main view in the end.
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
    /// Room the expanded view may take along its depth: the screen's usable length less both insets.
    var maxLength: CGFloat = 700
    /// What the full view and a page may take beside the bar on the sides: the room below where the bar starts at rest,
    /// so opening never moves it. Panels hang from the bar's cells and go by `maxLength`; nil: the same.
    var openLength: CGFloat?
    /// The window's width: along the top and bottom, the full view takes what the screen has.
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
    @State var peekSizes: [HubSection: CGSize] = [:]
    /// The last panel drawn, so the surface can shrink back to the bar after the panel is gone.
    @State var lastPeek: PanelGeometry?
    /// The bar's top in the window, for how much room a panel hanging from it has.
    @State var hubTop: CGFloat = 0
    /// The CI block's measured height, for what the lists have left of the full view's length.
    @State var ciHeight: CGFloat = 0
    /// What the sides' lists measured of themselves, for the one below to take what the one above leaves.
    @State var listHeights: [HubSection: ListHeights] = [:]
    /// The strip's trailing group (update button, gear) as laid out; a first guess until it is measured.
    @State var stripTrailingWidth: CGFloat = 140
    @Environment(\.accessibilityReduceMotion) var reduce

    /// The bar's depth: a cell's width on the sides, the strip's height along the top and bottom.
    static let cell = Theme.Metrics.bar
    /// What sits beside the rail on the sides.
    static let detail = HubGeometry.sideDetail
    /// The one outer inset. Pieces pad their own 8 inside it, so text starts 14pt from the hub's side everywhere.
    static let inset = Theme.Metrics.inset
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
    /// The full view of the main page is showing: every section beside (or under) the bar.
    var expanded: Bool { hub.expanded && hub.page == .main }
    /// Settings or Repositories showing: the bar as at rest, and the page beside it.
    var pageOpen: Bool { hub.expanded && hub.page != .main }
    /// The longest the full view (or a page) may be along the sides.
    var fullLength: CGFloat { openLength ?? maxLength }
    /// The rows' content beside the bar (and the strip's segments at full width).
    var showsDetail: Bool { expanded }

    var body: some View {
        let place = currentPlacement
        let peek = peekGeometry
        let shown = peek ?? lastPeek
        let shape = SurfaceShape(barRadii: barRadii(place), panel: shown?.rect, panelRadii: shown?.radii ?? RectangleCornerRadii(),
                                 edge: edge, reveal: peek == nil ? 0 : 1)
        let out = expanded || pageOpen || peek != nil
        Group {
            if showsDetail { openHub } else { restHub }
        }
        .coordinateSpace(.named(Self.barSpace))
        // Only the bar at rest is measured (for the hover panels): nothing to redo while the full view changes.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in if !hub.expanded, barSize != size { barSize = size } }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { if !hub.expanded, hubTop != $0 { hubTop = $0 } }
        .onHover { overBar = $0; hoverChanged() }
        .clipShape(barOutline)
        // The hovered section's panel, outside the bar's clip; the bar's own size doesn't change.
        .overlay(alignment: .topLeading) { peekPanel }
        // One surface under bar and panel, and one outline over them: no line where they meet. Its shadows are static
        // shapes (never a blurred composite of live content); the panel's growing out of the bar is all that moves.
        .background(alignment: .topLeading) { SurfaceLayers(shape: shape, ambient: out).animation(reduce ? nil : Theme.Motion.fade, value: peek != nil) }
        .overlay(alignment: .topLeading) { SurfaceRing(shape: shape).animation(reduce ? nil : Theme.Motion.fade, value: peek != nil) }
        .onChange(of: peek) { _, new in if let new { lastPeek = new } }
        .motion(Theme.Motion.fade, value: peeking != nil)
        .fixedSize()
        // Opening and closing are springs without a bounce, so it never overshoots back past the bar.
        .motion(expanded ? Self.opening : Self.closing, value: expanded)
        .motion(Self.pageSpring, value: hub.page)
        .motion(Self.refocus, value: hub.focus)
        .contextMenu { barMenu }
        .environment(\.colorScheme, .dark)
        .environment(\.controlFocus, hub.controls)
        .environment(\.tipBeside, edge == .right ? .leading : edge == .left ? .trailing : nil)
        .themeResolved()
        .background(SelectionSync(ui: ui, hub: hub))
        .background(SessionFreeze(store: store, hub: hub))
        .background(HubAnnouncer(store: store, hub: hub))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lookout")
        .accessibilityHint("Up and down to pick, Return to open, Delete to finish, Escape to go back")
    }

    /// Right-click on the bar (DESIGN.md 5.7); Lookout has no menu bar, so this is its menu.
    @ViewBuilder var barMenu: some View {
        Button { hub.pinned.toggle() } label: {
            Label(hub.pinned ? "Stop Keeping Open" : "Keep Open", systemImage: hub.pinned ? "pin.slash" : "pin")
        }
        Button { hub.go(.settings) } label: { Label("Settings…", systemImage: "gearshape") }
            .keyboardShortcut(",", modifiers: .command)
        Button { hub.go(.repos) } label: { Label("Repositories…", systemImage: "books.vertical") }
        if store.updater.isRelease {
            Button { Task { await store.updater.update(manual: true) } } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Divider()
        Button { NSApp.terminate(nil) } label: { Label("Quit Lookout", systemImage: "power") }
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: At rest, and with a page

    /// The bar, and beside it (under it along the top and bottom) the page when one is open. The bar is the same view
    /// either way: it is never dimmed and never rebuilt, and the page grows out of it.
    @ViewBuilder var restHub: some View {
        if edge.isHorizontal {
            // The strip and the page share one width, the strip at the leading end.
            SharedWidthStack {
                if edge == .bottom, pageOpen { stripPage }
                stripRow.zIndex(1)
                if edge == .top, pageOpen { stripPage }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                if edge == .right, pageOpen { sidePage }
                barColumn.zIndex(1)
                if edge == .left, pageOpen { sidePage }
            }
        }
    }

    var stripRow: some View {
        HStack(alignment: .center, spacing: 0) { strip }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.cell)
    }

    var sidePage: some View {
        // As tall as the hub opens, whatever the pane holds: moving between panes never resizes the panel, and the rail
        // keeps its cells.
        page
            .frame(width: HubGeometry.pageSide, height: fullLength)
            .transition(.slide(from: edge == .right ? .trailing : .leading, reduce: reduce))
    }

    var stripPage: some View {
        page
            .frame(idealWidth: HubGeometry.pageStrip, maxWidth: .infinity)
            .frame(height: maxLength - Self.cell)
            .transition(reduce ? .opacity.animation(Theme.Motion.fade)
                        : .opacity.combined(with: .offset(y: edge == .top ? -Theme.Space.md : Theme.Space.md)))
    }

    // MARK: Data

    var items: [InboxItem] { store.hubItems(hub) }
    var searching: Bool { !hub.query.isEmpty }
    /// What the inbox list animates on: its items changing, or the filter or search swapping them.
    struct ListKey: Equatable { let revision: Int; let filter: InboxFilter; let query: String }
    var listKey: ListKey { ListKey(revision: store.itemsRevision, filter: hub.filter, query: hub.query) }
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

/// Under the Sessions header: Claude's session files missing or unreadable (nothing when all is well).
struct ClaudeNotice: View {
    let store: Store
    /// Its one line's room, for the lists around it to leave.
    static let height: CGFloat = 24

    /// What it takes of a list's room: its line, or nothing.
    static func room(_ store: Store) -> CGFloat {
        switch store.claudeLink {
        case .missing, .unreadable: height
        default: 0
        }
    }

    @State private var details = false

    var body: some View {
        if Self.room(store) > 0 {
            HStack(spacing: 6) {
                ClaudeLinkStatus(store: store)
                Spacer(minLength: 0)
                // The recovery sentence is more than a tooltip: a button, so keyboard and VoiceOver users have it too.
                Button { details = true } label: {
                    Text("Details").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                        .frame(minHeight: Theme.Metrics.iconButton)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(Theme.Radius.small)
                .popover(isPresented: $details, arrowEdge: .bottom) {
                    Text(ClaudeLinkStatus.describe(store.claudeLink).detail)
                        .font(Theme.Typography.meta).foregroundStyle(Theme.text)
                        .padding(Theme.Space.lg)
                }
                .accessibilityHint(ClaudeLinkStatus.describe(store.claudeLink).detail)
            }
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.red)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        }
    }
}
