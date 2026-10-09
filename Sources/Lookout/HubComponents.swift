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

/// A vertical stack that is lazy only for long lists: a list of up to 40 rows is laid out whole, so every row's edge is measured
/// (`CappedScroll` can then cut between rows, not through one). Past that, building every row at once stalls a switch of
/// filter (a Done list of 140 took most of a second); a lazy list cuts on its rows' pitch instead.
struct AdaptiveStack<Content: View>: View {
    let count: Int
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    /// Whether a list of `count` rows is laid out lazily.
    static func isLazy(_ count: Int) -> Bool { count > 40 }

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

/// An inbox item on two short lines; its actions show on hover or when picked with the keys. Done, Addressed and
/// Resolved items carry a small state tag and read in the quieter text tokens (never a dimmed row: contrast stays).
struct CompactItemRow: View {
    let item: InboxItem
    let store: Store
    let ui: UIState
    let hub: HubState
    @State private var hover = false

    /// Compared here, in this row's own body: hovering another row doesn't rebuild the whole hub.
    private var selected: Bool { hub.selection == "i:" + item.id }
    private var low: Bool { hub.filter == .bots }
    private var open: Bool { hover || selected }
    private var unread: Bool { item.state == .unread }

    var body: some View {
        Button { store.open(item) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(unread ? (low ? Theme.secondary : Theme.amber) : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 8)
                ZStack(alignment: .bottomTrailing) {
                    Avatar(url: item.avatar, size: 22, name: item.author)
                    Image(systemName: item.kind.symbol)
                        .font(Theme.Typography.glyph(6, .bold))
                        .foregroundStyle(Theme.onTint)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(item.kind.color))
                        .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(unread ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(unread || open ? Theme.text : Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // The actions take the timestamp's place; the title stops short of them.
                        Text(shortAgo(item.createdAt)).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                            .opacity(open ? 0 : 1)
                            .frame(width: open ? actionsWidth - 6 : nil, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number) · \(item.kind.label) · @\(item.author)")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                        if !item.state.isOpen { StateTag(state: item.state) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowHighlight(open)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.repo) #\(item.number)")
        .accessibilityValue(unread ? "Unread" : item.state.isOpen ? "" : StateTag.label(item.state))
        .accessibilityHint("Opens it on GitHub")
        .overlay(alignment: .topTrailing) {
            // Centred on the title line (6pt row padding + half its 15pt line = 13.5; the capsule is 26 tall).
            if open { actions.padding(.top, 1).padding(.trailing, 4).transition(.opacity) }
        }
        .contextMenu { InboxItemMenu(item: item, store: store, low: store.isLowPriority(item)) }
        .onHover {
            hover = $0
            if $0 {
                hub.selection = "i:" + item.id
                ui.drawerSelection = nil
            }
        }
        .motion(Theme.Motion.hover, value: open)
    }

    /// Room the action capsule takes over the title line: its buttons, its 2pt insets, and its 4pt from the edge.
    private var actionsWidth: CGFloat { CGFloat(item.state.isOpen ? 3 : 2) * IconButton.Size.row + 4 + 4 }

    private var actions: some View {
        let size = IconButton.Size.row
        return RowActions {
            if item.state.isOpen {
                IconButton(symbol: unread ? "checkmark" : "circle.fill", help: unread ? "Mark as read" : "Mark as unread",
                           detail: store.shortcut(.toggleRead).display, size: size) { unread ? store.markRead(item) : store.markUnread(item) }
                IconButton(symbol: "xmark", help: "Done", detail: "Moves it to Done · \(store.shortcut(.discard).display)",
                           size: size) { store.discard(item) }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Back to inbox", detail: store.shortcut(.discard).display,
                           size: size) { store.restore(item) }
            }
            IconButton(symbol: "arrow.up.right", help: "Open on GitHub", detail: store.shortcut(.openItem).display, size: size) {
                store.open(item)
            }
        }
    }
}

/// What became of an inbox item that's no longer open: Done, Addressed (you replied) or Resolved.
struct StateTag: View {
    let state: ItemState

    static func label(_ state: ItemState) -> String {
        switch state {
        case .addressed: "Addressed"
        case .resolved: "Resolved"
        default: "Done"
        }
    }

    var body: some View {
        let (symbol, color): (String, Color) = switch state {
        case .addressed: ("arrowshape.turn.up.left.fill", Theme.green)
        case .resolved: ("checkmark.circle.fill", Theme.purple)
        default: ("checkmark", Theme.secondary)
        }
        Label(Self.label(state), systemImage: symbol)
            .font(Theme.Typography.caption.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

/// A row's actions on hover, the same for inbox items and sessions: icon buttons in a capsule laid over the row's
/// right end (so showing them never changes the row's size).
struct RowActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(2)
            .background(Capsule().fill(Theme.raised))
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

    /// Every row the arrows walk through, top to bottom: inbox items, then sessions.
    func hubTargets(_ hub: HubState) -> [String] {
        hubItems(hub).map { "i:" + $0.id } + hubSessions(hub).map { "a:" + $0.id }
    }

    /// A repo's checks for its latest commit (its Actions page until a run is known).
    func checksURL(_ repo: RepoConfig) -> URL {
        ci[repo.fullName]?.url?.appendingPathComponent("checks") ?? repo.url.appendingPathComponent("actions")
    }

    /// A repo's latest checks on GitHub; the playground reports it instead.
    func openChecks(_ repo: RepoConfig) {
        if let interceptOpen { interceptOpen("Open checks · \(repo.fullName)") } else { Link.open(checksURL(repo)) }
    }

    /// A scratch Claude session (no folder), through the same interception as every other open.
    func startScratchSession() {
        if let interceptOpen { interceptOpen("New Claude session in Scratch"); return }
        NewSessionRow.startScratch()
    }

    /// Sessions as the hub lists them: yours and the pending ones, or any session matching the search.
    func hubSessions(_ hub: HubState) -> [AgentRow] {
        guard agents.enabled else { return [] }
        let searching = !hub.query.trimmingCharacters(in: .whitespaces).isEmpty
        // Router only: no session rows to walk, but a search finds them.
        if sessionsHidden && !searching { return [] }
        if !hub.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let memo = hub.sessionMemo
            if memo.revision == agentsRevision, memo.query == hub.query { return memo.result }
            let result = searchSessions(hub.query)
            hub.sessionMemo = SessionSearchMemo(query: hub.query, revision: agentsRevision, result: result)
            return result
        }
        return agentSections.flatMap(\.rows)
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

/// The inbox in the bar: the tray, and under it (beside it along the top and bottom) one count. Amber for what
/// needs you; the bots' count, grey, only when nothing does. Nothing sits on top of the icon.
struct InboxCell: View {
    let needsYou: Int
    let bots: Int
    let vertical: Bool
    /// Off while the filter chips beside it already show the counts.
    var showsCount = true
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: action) { InboxCellLabel(needsYou: needsYou, bots: bots, vertical: vertical, showsCount: showsCount) }
            .buttonStyle(.plain)
            .accessibilityLabel("Inbox")
            .accessibilityValue([needsYou > 0 ? "\(needsYou) need you" : nil, bots > 0 ? plural(bots, "bot item") : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Shows what needs you")
            .motion(.snappy, value: needsYou)
            .motion(.snappy, value: bots)
            .motion(Theme.Motion.spring, value: showsCount)
    }
}

private struct InboxCellLabel: View {
    let needsYou: Int
    let bots: Int
    let vertical: Bool
    let showsCount: Bool
    @State private var hover = false

    var body: some View {
        Group {
            if vertical {
                // At rest always as tall as icon + count, so the bar never shifts: with nothing to count the tray slides
                // to the middle, but not when the count is only hidden because the tabs beside it show it.
                ZStack(alignment: .top) {
                    icon.offset(y: badge == nil && showsCount ? 9 : 0)
                    if let badge { badge.offset(y: 32) }
                }
                // Beside the tabs, no count to leave room for: just the tray.
                .frame(height: showsCount ? 47 : 28, alignment: .top)
            } else {
                HStack(spacing: 6) {
                    icon
                    if let badge { badge }
                }
                // Never squeezed by the tabs beside it.
                .fixedSize()
            }
        }
        .padding(.vertical, vertical ? 7 : 5)
        .padding(.horizontal, vertical ? 4 : 7)
        .frame(minWidth: vertical ? Theme.Metrics.row : nil)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .motion(Theme.Motion.hover, value: hover)
    }

    /// The tray; on a solid amber tile (like a session's) when something needs you, so it shows from afar.
    private var icon: some View {
        let lit = needsYou > 0
        return Image(systemName: lit ? "tray.full.fill" : "tray.fill")
            .font(Theme.Typography.glyph(lit ? 13.5 : 15))
            .foregroundStyle(lit ? Theme.onTint : hover ? Theme.text : Theme.secondary)
            .frame(width: 28, height: 28)
            // Hover brightens the tile (or the tray), no box around it.
            .background(Tile.shape(28).fill(lit ? Theme.amber : hover ? Theme.Fill.hover : Theme.Fill.rest))
            .brightness(lit && hover ? 0.06 : 0)
            .motion(.snappy, value: lit)
    }

    private var badge: AnyView? {
        guard showsCount else { return nil }
        // The tile is already amber: the count beside it stays quiet.
        if needsYou > 0 { return AnyView(count(needsYou, fill: Theme.Fill.selected, text: Theme.text)) }
        if bots > 0 { return AnyView(count(bots, fill: Theme.Fill.hover, text: Theme.secondary)) }
        return nil
    }

    private func count(_ n: Int, fill: Color, text: Color) -> some View {
        Text(n > 99 ? "99+" : "\(n)")
            .font(Theme.Typography.glyph(10.5, .bold).monospacedDigit())
            .contentTransition(.numericText(value: Double(n)))
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 15)
            .background(Capsule().fill(fill))
            .transition(.scaleFade(0.6, reduce: reduce))
    }
    @Environment(\.accessibilityReduceMotion) private var reduce
}

/// A repo in CI's lines: its name (and which checks fail), opening its latest run.
struct RepoChip: View {
    let repo: RepoConfig
    let status: CIStatus?
    let state: CIState
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // The name keeps its room; the failing checks give way to it, and both stop at the chip's width.
                Text(repo.name).font(Theme.Typography.control).foregroundStyle(Theme.text)
                    .lineLimit(1).layoutPriority(1)
                if state == .failure, let failing = status?.failing, !failing.isEmpty {
                    Text(Self.failingSummary(failing)).font(Theme.Typography.caption).foregroundStyle(Theme.red)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), rest: Theme.Fill.hover, hover: Theme.Fill.selected))
        .accessibilityLabel("\(repo.name), \(state == .none ? "no runs" : state.label)"
                            + (state == .failure ? ((status?.failing).map { ": " + $0.joined(separator: ", ") } ?? "") : ""))
        .accessibilityHint("Opens its latest checks")
        .focused($focused)
        .tip(repo.fullName, detail, focused: focused)
    }

    /// The failing checks by name for the chip: the first two, cut short, and how many more ("build, lint +3").
    static func failingSummary(_ names: [String], shown: Int = 2, width: Int = 16) -> String {
        func cut(_ name: String) -> String { name.count > width ? name.prefix(width - 1).trimmingCharacters(in: .whitespaces) + "…" : name }
        let head = names.prefix(shown).map(cut).joined(separator: ", ")
        return names.count > shown ? "\(head) +\(names.count - shown)" : head
    }

    private var detail: String {
        var lines = [status?.branch ?? repo.defaultBranch ?? "default branch"]
        if let title = status?.title, !title.isEmpty { lines[0] += " · " + title }
        if state == .failure, let failing = status?.failing, !failing.isEmpty {
            lines.append("Failing: " + failing.joined(separator: ", "))
        }
        lines.append("Click to open its checks")
        return lines.joined(separator: "\n")
    }
}

/// The "+" tile: shaped and filled like a session's tile, so it reads as the next one in the column.
struct NewSessionTile: View {
    var size: CGFloat = Theme.Metrics.chip
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { NewSessionTileLabel(size: size) }
            .buttonStyle(HoverFillButtonStyle(shape: Tile.shape(size), rest: Theme.Fill.field, hover: Theme.Fill.tile))
            .accessibilityLabel("New session")
            .accessibilityHint("Scratch chat, or pick a project")
            .focused($focused)
            .tip("New session", "Scratch chat, or pick a project", focused: focused)
    }
}

private struct NewSessionTileLabel: View {
    let size: CGFloat
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        Image(systemName: "plus")
            .font(Theme.Typography.glyph(size * 0.42, .bold))
            .foregroundStyle(hover ? Theme.text : Theme.secondary)
            .frame(width: size, height: size)
    }
}

/// What a session left running, on one line: each subagent and command with its icon.
struct RunningLine: View {
    let tasks: [ClaudeTask]

    var body: some View {
        tasks.enumerated().reduce(Text("")) { line, item in
            let (i, task) = item
            let icon = Text(Image(systemName: task.kind == .agent ? "asterisk" : "terminal")).foregroundStyle(Theme.claude)
            return line + (i == 0 ? Text("") : Text("   ")) + icon + Text(" " + task.title).foregroundStyle(Theme.secondary)
        }
        .font(Theme.Typography.meta)
        .lineLimit(1)
        .truncationMode(.tail)
        // Cut short at the row's width: hovering has the whole list.
        .tip("Running", tasks.map(\.title).joined(separator: "\n"))
    }
}

/// A session's tile in the bar; opens it in Claude. Its highlight is compared here, in its own body, so hovering a
/// tile doesn't rebuild the whole hub. No tooltip: hovering opens the sessions' panel, a row beside each tile.
struct BarTile: View {
    let row: AgentRow
    let size: CGFloat
    let store: Store
    let ui: UIState
    let hub: HubState

    var body: some View {
        Button { store.openAgent(row.id) } label: {
            AgentTile(row: row, size: size, selected: hub.selection == "a:" + row.id)
        }
        .buttonStyle(.plain)
        .frame(height: Theme.Metrics.row)
        .accessibilityLabel(row.session.title)
        .spokenValue(of: row)
        .accessibilityHint(row.spokenHint)
        .sessionMenu(row, store)
        .onHover {
            if $0 {
                hub.selection = "a:" + row.id
                ui.drawerSelection = row.id
            }
        }
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
        .background(Theme.Radius.shape(Theme.Radius.md).fill(selected ? Theme.Fill.field : Theme.Fill.rest))
        // The same actions as an inbox item's, over the title line's right end, centred on it.
        .overlay(alignment: .topTrailing) {
            if selected {
                AgentActions(row: row, store: store, size: IconButton.Size.row)
                    .padding(.top, twoLines ? 9 : 0)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
        .motion(Theme.Motion.hover, value: selected)
        .contentShape(Rectangle())
        .onTapGesture { store.openAgent(row.id) }
        .opensOnFirstClick()
        // One button for the card (named, with its state); the hover actions stay reachable inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.session.title)
        .spokenValue(of: row)
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
    private var cardDetail: some View { DetailLine(row: row) }

    /// At most two short lines: the turn's summary, and what's still running after it.
    @ViewBuilder private var details: some View {
        if row.session.running || summary != nil || !row.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                DetailLine(row: row)
                if summary != nil && !row.tasks.isEmpty { RunningLine(tasks: row.tasks) }
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

/// Says a failed update check, download or restart to VoiceOver, wherever it was asked for (Settings' row is not always
/// on screen), from a view of its own: only this body reads the updater's failures.
struct UpdateAnnouncer: View {
    let updater: Updater

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: updater.failures) {
                guard let error = updater.shownError, NSWorkspace.shared.isVoiceOverEnabled else { return }
                AccessibilityNotification.Announcement(error).post()
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

/// The Router in the bar: its symbol, and on its corner how many cards are open, amber while one needs you (a question, a
/// plan, a stuck turn), blue when they are only finished turns, nothing at zero. A click opens the Router's window.
struct RouterCell: View {
    let needsYou: Int
    let done: Int
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { RouterCellLabel(needsYou: needsYou, done: done) }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel("Router")
            .accessibilityValue([needsYou > 0 ? "\(needsYou) need you" : nil, done > 0 ? "\(done) done" : nil]
                .compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "Nothing open")
            .accessibilityHint("Opens the Router window")
            .motion(.snappy, value: needsYou + done)
    }
}

private struct RouterCellLabel: View {
    let needsYou: Int
    let done: Int
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let open = needsYou + done
        Image(systemName: "arrow.triangle.branch")
            .font(Theme.Typography.glyph(14))
            .foregroundStyle(hover ? Theme.text : Theme.secondary)
            .frame(width: 28, height: 28)
            .background(Tile.shape(28).fill(hover ? Theme.Fill.hover : Theme.Fill.rest))
            .overlay(alignment: .topTrailing) {
                if open > 0 {
                    Text(open > 99 ? "99+" : "\(open)")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(Theme.onTint)
                        .contentTransition(reduce ? .opacity : .numericText(value: Double(open)))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(needsYou > 0 ? Theme.amber : Theme.accent))
                        .background(Capsule().fill(Theme.bg).padding(-1.5))
                        .offset(x: 6, y: -5)
                        .transition(.scaleFade(0.6, reduce: reduce))
                }
            }
            .frame(width: Theme.Metrics.line, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .motion(Theme.Motion.hover, value: hover)
    }
}

extension String {
    /// nil for an empty string, for `??` defaults.
    var nonEmpty: String? { isEmpty ? nil : self }
}
