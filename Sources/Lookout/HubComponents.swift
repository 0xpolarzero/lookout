import AppKit
import SwiftUI

// Building blocks of the hub.

/// The bottom edges of the rows that mark themselves with `.capEdge()`, in the scrolled content's own space.
struct CapEdges: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

extension View {
    /// Marks a row of a `CappedScroll`'s content: the list may stop at its bottom edge, never through it.
    func capEdge() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: CapEdges.self, value: [proxy.frame(in: .named(CappedScrollSpace.name)).maxY])
            }
        }
    }
}

enum CappedScrollSpace {
    static let name = "capped-content"

    /// The tallest height up to `cap` that ends on a row's bottom edge, when the cap falls inside a measured row (a
    /// row ends past it). A lazy list only measures the rows it has laid out: with none ending past the cap, the cut
    /// is somewhere unmeasured, and the cap itself stands.
    static func fit(cap: CGFloat, edges: [CGFloat]) -> CGFloat {
        guard edges.contains(where: { $0 > cap + 0.5 }) else { return cap }
        return edges.filter { $0 <= cap + 0.5 }.max().map { min($0, cap) } ?? cap
    }

    /// `fit` for a lazy list, which only measures the rows it has realized (and may report a stray edge far past the
    /// rest while it settles): the rows beyond the last measured edge within the cap are taken to repeat the measured
    /// pitch (the gaps between consecutive edges within it, which must agree within a point), and the cap snaps down to a whole number of them.
    /// Never below the first row; with fewer than two edges within the cap there is no pitch to go by.
    static func fitLazy(cap: CGFloat, edges: [CGFloat]) -> CGFloat {
        let within = edges.filter { $0 <= cap + 0.5 }
        guard within.count >= 2, let last = within.last else { return fit(cap: cap, edges: edges) }
        let gaps = zip(within, within.dropFirst()).map { $1 - $0 }
        // Only uniform rows can be extrapolated; otherwise the unmeasured rows' heights are unknown.
        guard let pitch = gaps.max(), pitch > 1, gaps.allSatisfy({ pitch - $0 <= 1 }) else { return fit(cap: cap, edges: edges) }
        return min(last + ((cap - last + 0.5) / pitch).rounded(.down) * pitch, cap)
    }
}

/// A vertical stack that is lazy only for long lists: a list of up to 150 rows is laid out whole, so every row's edge is measured
/// (`CappedScroll` can then cut between rows, not through one).
struct AdaptiveStack<Content: View>: View {
    let count: Int
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    /// Whether a list of `count` rows is laid out lazily.
    static func isLazy(_ count: Int) -> Bool { count > 150 }

    var body: some View {
        if !Self.isLazy(count) {
            VStack(alignment: alignment, spacing: spacing, content: content)
        } else {
            LazyVStack(alignment: alignment, spacing: spacing, content: content)
        }
    }
}

/// Scrolls only once its content is taller than `cap`; otherwise exactly as tall as the content. Cut short, it stops
/// at the last row that fits whole (rows mark themselves with `.capEdge()`), its fade saying "more below". Follows
/// the keyboard selection (never the pointer's: hovering a row mustn't move the list under it).
struct CappedScroll<Content: View>: View {
    let cap: CGFloat
    /// Read here, in this view's own body, so the parent doesn't depend on it.
    var hub: HubState?
    /// The content is a lazy stack or grid: it only measures the rows its viewport reaches, so the list starts at the
    /// cap (a full viewport) and only shrinks once content measured *at the cap* turns out shorter.
    var lazy = false
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0
    @State private var viewport: CGFloat = 0
    /// Lazy only: the content's height, once measured in a viewport as tall as the cap and found shorter than it.
    @State private var lazyShort: CGFloat?
    @State private var edges: [CGFloat] = []
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        // Whole rows only; with no rows marked (or none ending within the cap) the plain cap.
        let limit = lazy ?CappedScrollSpace.fitLazy(cap: cap, edges: edges) : CappedScrollSpace.fit(cap: cap, edges: edges)
        // A lazy list's measured height can lag behind the rows it has since laid out: they count too.
        let cut = lazy ? lazyShort == nil : max(height, edges.last ?? 0) > cap + 0.5
        let shown = cut ? limit : lazy ? lazyShort ?? cap : height
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content()
                    .coordinateSpace(.named(CappedScrollSpace.name))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        // The first measure lands as is (the hub's own spring reveals it); later ones glide.
                        if height == 0 { height = h } else { withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { height = h } }
                        settle()
                    }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                viewport = h
                settle()
            }
            .onPreferenceChange(CapEdges.self) { new in
                let sorted = Array(Set(new.map { ($0 * 2).rounded() / 2 })).sorted()
                if sorted != edges {
                    edges = sorted
                    // Rows came or went: measure again at the cap.
                    if lazy, lazyShort != nil { lazyShort = nil }
                    // The content's height may already be known at the cap (a list that shrank): settle on it now.
                    settle()
                }
            }
            // No scroller: a legacy one ("Show scroll bars: Always") would take its width out of the rows and push
            // them off the bar's cells they line up with.
            .scrollIndicators(.never)
            .scrollDisabled(!cut)
            .frame(height: max(shown, 1))
            // Cut short: the last visible row fades out, so it reads as "more below" rather than clipped.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(cut ? 0.15 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
            .onChange(of: hub?.keyboardSelection) { _, request in
                if let id = request?.id { withAnimation(Theme.Motion.hover.resolved(reduce: reduce)) { proxy.scrollTo(id) } }
            }
        }
    }
}

extension CappedScroll {
    /// Lazy: trusts the content's height only when it was measured in a viewport as tall as the cap.
    fileprivate func settle() {
        guard lazy, height > 0 else { return }
        // A viewport snapped down to whole rows is as good as the cap when the content is shorter than it.
        let snapped = CappedScrollSpace.fitLazy(cap: cap, edges: edges)
        if viewport >= cap - 0.5 || (viewport >= snapped - 0.5 && height < snapped - 0.5) {
            let short: CGFloat? = height < cap - 0.5 ? height : nil
            if short != lazyShort { lazyShort = short }
        } else if let short = lazyShort {
            // Shrunk to its content: rows added make it overflow its viewport (measure again at the cap); rows removed
            // leave it short still.
            if height > short + 0.5 { lazyShort = nil } else if height < short - 0.5 { lazyShort = height }
        }
    }
}

/// A row's actions on hover, the same for inbox items and sessions: icon buttons in a capsule laid over the row's
/// right end (so showing them never changes the row's size).
struct RowActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(2)
            .background(Capsule().fill(Theme.Fill.group))
            .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}

extension AnyTransition {
    /// Content of the expanded view: fades in once the shape has started to grow, and out at once on close.
    static var hubReveal: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Theme.Motion.fade.delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.08)))
    }
}

/// A request to scroll the lists to a row; `seq` makes asking for the same row again a new request.
struct ScrollRequest: Equatable {
    let id: String
    let seq: Int
}

/// The last session search's result, valid for one query and one state of the agents.
struct SessionSearchMemo {
    var query = ""
    var revision = -1
    var result: [AgentRow] = []
}

/// The last search's lowercase keys and result, so the many reads of one render cost one search.
struct SearchMemo {
    var revision = -1
    /// One lowercase line per item, in `store.items` order.
    var keys: [String] = []
    var query = ""
    var queryRevision = -1
    var result: [InboxItem] = []
}

extension Store {
    /// The inbox as the hub shows it: the picked filter, or every item matching the search (memoized on the query and
    /// the items' revision).
    func hubItems(_ hub: HubState) -> [InboxItem] {
        let words = hub.query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return list(hub.filter) }
        var memo = hub.searchMemo
        if memo.queryRevision == itemsRevision, memo.query == hub.query { return memo.result }
        if memo.revision != itemsRevision {
            memo.keys = items.map { "\($0.title) \($0.repo) #\($0.number) @\($0.author) \($0.snippet)".lowercased() }
            memo.revision = itemsRevision
        }
        memo.result = zip(items, memo.keys)
            .filter { _, key in words.allSatisfy { key.contains($0) } }
            .map(\.0)
            .sorted { ($0.state.isOpen ? 0 : 1, $1.createdAt) < ($1.state.isOpen ? 0 : 1, $0.createdAt) }
        memo.query = hub.query
        memo.queryRevision = itemsRevision
        hub.searchMemo = memo
        return memo.result
    }

    /// A repo's latest CI run on GitHub (its Actions page until a run is known); the playground reports it instead.
    func openChecks(_ repo: RepoConfig) {
        let url = ci[repo.fullName]?.url ?? repo.url.appendingPathComponent("actions")
        if let interceptOpen { interceptOpen("Open checks · \(repo.fullName)") } else { NSWorkspace.shared.open(url) }
    }

    /// A scratch Claude session (no folder), through the same interception as every other open.
    func startScratchSession() {
        if let interceptOpen { interceptOpen("New Claude session in Scratch"); return }
        NewSessionRow.startScratch()
    }

    /// Sessions as the hub lists them: yours and the pending ones, or any session matching the search.
    func hubSessions(_ hub: HubState) -> [AgentRow] {
        guard agents.enabled else { return [] }
        if !hub.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let memo = hub.sessionMemo
            if memo.revision == agentsRevision, memo.query == hub.query { return memo.result }
            let result = searchSessions(hub.query)
            hub.sessionMemo = SessionSearchMemo(query: hub.query, revision: agentsRevision, result: result)
            return result
        }
        let rows = agentRows
        return rows.kept + rows.pending.prefix(LookoutHub.pendingTiles)
    }
}

/// A session's context menu (open, read state, label, keep/remove, colour, mute) and the popover its label editor
/// opens in. Attach with `.sessionMenu(row, store)`.
private struct SessionContextMenu: ViewModifier {
    let row: AgentRow
    let store: Store
    @State private var editing = false

    func body(content: Content) -> some View {
        content
            .contextMenu { SessionMenu(row: row, store: store, editLabel: { editing = true }) }
            .popover(isPresented: $editing, arrowEdge: .bottom) { LabelEditor(row: row, store: store) }
    }
}

extension View {
    func sessionMenu(_ row: AgentRow, _ store: Store) -> some View { modifier(SessionContextMenu(row: row, store: store)) }
}

/// The "+" tile: shaped and filled like a session's tile, so it reads as the next one in the column.
struct NewSessionTile: View {
    var size: CGFloat = Theme.Metrics.tile
    let action: () -> Void

    var body: some View {
        Button(action: action) { NewSessionTileLabel(size: size) }
            .buttonStyle(HoverFillButtonStyle(shape: Tile.shape(size), rest: Theme.Fill.tile, hover: Theme.Fill.selected))
            .accessibilityLabel("New session")
            .accessibilityHint("Scratch chat, or pick a project")
            .tip("New session", "Scratch chat, or pick a project")
    }
}

private struct NewSessionTileLabel: View {
    let size: CGFloat
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        Image(systemName: "plus")
            .font(Theme.Typography.glyph(size * 0.42, .bold))
            .foregroundStyle(hover ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
            .frame(width: size, height: size)
    }
}

/// What a session left running, on one line: each subagent and command with its icon.
struct RunningLine: View {
    let tasks: [ClaudeTask]

    var body: some View {
        tasks.enumerated().reduce(Text("")) { line, item in
            let (i, task) = item
            let icon = Text(Image(systemName: task.kind == .agent ? "asterisk" : "terminal")).foregroundStyle(Theme.secondary)
            return line + (i == 0 ? Text("") : Text("   ")) + icon + Text(" " + task.title).foregroundStyle(Theme.secondary)
        }
        .font(Theme.Typography.meta)
        .lineLimit(1)
        .truncationMode(.tail)
        // Cut short at the row's width: hovering has the whole list.
        .tip("Running", tasks.map(\.title).joined(separator: "\n"))
    }
}

/// A session's turn summary on one line: Markdown (**bold**, `code`) shown as such.
struct SummaryText: View {
    let row: AgentRow

    var body: some View {
        Text(row.summaryText).font(Theme.Typography.meta).foregroundStyle(Theme.secondary).lineLimit(1)
    }
}

/// A session in the full view: its line, then (short) what it did and what it left running. One block: it
/// highlights, opens and shows its actions as a whole, wherever the pointer is on it. Whether it's the picked one
/// is compared here, in its own body.
struct SessionBlock: View {
    let row: AgentRow
    let twoLines: Bool
    let store: Store
    @Bindable var ui: UIState
    let hub: HubState

    var body: some View {
        let selected = ui.drawerSelection == row.id
        VStack(alignment: .leading, spacing: 0) {
            DrawerRow(row: row, store: store, ui: ui, number: 0, twoLines: twoLines, highlight: hub.query,
                      showsKept: !hub.query.isEmpty, inHub: !twoLines, plain: true)
                // The card below is the one button; its inner row's own (a second, unnamed-or-duplicate button) is hidden.
                .accessibilityHidden(true)
            // Under the title: past the tile on two-line rows (10 + 24 + 9), else at the title's 8.
            Group { if twoLines { cardDetail } else { details } }
                .padding(.leading, twoLines ? 43 : 8)
                .padding(.trailing, 8)
                .padding(.top, twoLines ? -8 : -3)
                .padding(.bottom, twoLines ? 4 : 7)
        }
        .background(Theme.Radius.shape(Theme.Radius.row).fill(selected ? Theme.Fill.hover : Theme.Fill.rest))
        // The same actions as an inbox item's, over the title line's right end, centred on it.
        .overlay(alignment: .topTrailing) {
            if selected {
                AgentActions(row: row, store: store)
                    .padding(.top, twoLines ? 9 : 0)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
        .motion(Theme.Motion.hover, value: selected)
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(row.id) }
        // One button for the card (named, with its state); the hover actions stay reachable inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.session.title)
        .accessibilityValue(row.stateName)
        .accessibilityHint("Opens it in Claude")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openAgent(row.id) }
        .sessionMenu(row, store)
        .onHover { if $0 { ui.drawerSelection = row.id } }
    }

    private var summary: String? {
        guard !row.session.running, let detail = row.session.summary?.detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// A grid card's one line under its title, always there so every card is the same height: the turn's summary,
    /// else what's still running (the count is in the status above either way).
    @ViewBuilder private var cardDetail: some View {
        if summary != nil {
            SummaryText(row: row)
        } else if !row.tasks.isEmpty {
            RunningLine(tasks: row.tasks)
        } else {
            Text(" ").font(Theme.Typography.meta)
        }
    }

    /// At most two short lines: the turn's summary, and what's still running after it.
    @ViewBuilder private var details: some View {
        if summary != nil || !row.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if summary != nil { SummaryText(row: row) }
                if !row.tasks.isEmpty { RunningLine(tasks: row.tasks) }
            }
        }
    }
}

/// Keeps `ui.drawerSelection` (a session row hovered anywhere) and the hub's selection (what the keys act on) the
/// same, from a view of its own: only this body reads the drawer's selection, not the hub's.
struct SelectionSync: View {
    let ui: UIState
    let hub: HubState

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: ui.drawerSelection) { _, id in
                if let id, hub.selection != "a:" + id { hub.selection = "a:" + id }
            }
    }
}

/// Your sessions in the hub can be dragged onto one another to reorder them, when `enabled` (the bar's tiles at
/// rest are plain buttons).
struct ReorderIf: ViewModifier {
    let enabled: Bool
    let row: AgentRow
    let store: Store

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(AgentReorder(row: row, store: store)) } else { content }
    }
}
