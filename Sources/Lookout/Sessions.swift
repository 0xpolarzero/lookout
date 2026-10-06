import AppKit
import SwiftUI

// Sessions in the hub: the list (groups, rows, "+N more", the New session row), a session's menus and label
// editor; then the update button, the inbox item menu and the status lines the hub also uses.

// MARK: - The list

/// What a row is listed under: it decides the row's action, and whether the row names its project (under a project's
/// own header it would say the same thing twice).
enum SessionPlacement {
    case waiting, project, newActivity, search

    var namesProject: Bool { self != .project }
}

/// A line of the sessions list and the bar's tile column beside it: a bar-wide slot for the tile (the rail itself on a
/// side edge, so tile and text read as one row) and the text next to it. The fill spans both. Rows lay out the same
/// kept open, on every edge: only the side the tile is on changes. A peek has no tile column (`rail` nil): the bar's
/// tiles are beside it. The row's height is its own, so the fill, the pick bar and the focus ring span all of it.
struct RailRow<Tile: View, Content: View>: View {
    /// The screen's side on the left and right edges, the leading edge along the top and bottom; nil in a peek.
    let rail: HorizontalEdge?
    let height: CGFloat
    var fill = Color.clear
    var picked = false
    @ViewBuilder let tile: Tile
    @ViewBuilder let content: Content
    @Environment(\.resolved) private var resolved

    /// The fill starts this far in from the rail's side, so the tile sits inside it.
    private static var fillInset: CGFloat { 4 }

    /// How far the text's end is from the row's end on the side `rail` puts the tile: a trailing action lines up here.
    static func textEnd(_ rail: HorizontalEdge?) -> CGFloat {
        Theme.Metrics.rowPadding + (rail == .trailing ? Theme.Metrics.bar : 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            if rail == .leading { slot }
            content
                .padding(.horizontal, Theme.Metrics.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            if rail == .trailing { slot }
        }
        .frame(height: height)
        .background {
            Theme.Radius.shape(Theme.Radius.row).fill(resolved.fill(fill))
                .padding(.leading, rail == .leading ? Self.fillInset : 0)
                .padding(.trailing, rail == .trailing ? Self.fillInset : 0)
        }
        .overlay(alignment: .leading) {
            if picked {
                Capsule().fill(Theme.accent).frame(width: 2, height: 24)
                    .padding(.leading, 2 + (rail == .leading ? Self.fillInset : 0))
            }
        }
        .contentShape(Rectangle())
        .motion(Theme.Motion.hover, value: fill)
        .motion(Theme.Motion.hover, value: picked)
    }

    private var slot: some View {
        tile.frame(width: Theme.Metrics.bar)
    }
}

/// The groups of the sessions list under one another, or (searching) the sessions that match, flat. Rows mark their
/// bottom edge for `CappedScroll` and their id for scrolling to them. A peek (`peekCap`) lists whole groups and rows
/// up to that height, then "+N more", and never scrolls.
struct SessionsList: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let rail: HorizontalEdge?
    /// The hub's own inset on the side away from the tile; peeks pad themselves, and pass 0.
    var inset: CGFloat = Theme.Metrics.inset
    var peekCap: CGFloat?

    var body: some View {
        let searching = !hub.query.trimmingCharacters(in: .whitespaces).isEmpty
        let capped = store.listedGroups(hub)
        let peeked = peekCap.map { SessionGroup.peek(capped.groups, hidden: capped.hidden, cap: $0) }
        let listed = (groups: peeked?.groups ?? capped.groups, hidden: peeked?.hidden ?? capped.hidden)
        AdaptiveStack(count: store.hubSessions(hub).count, alignment: .leading, spacing: 0) {
            if searching {
                ForEach(store.hubSessions(hub)) { row($0, .search) }
            } else if listed.groups.isEmpty && listed.hidden == 0 {
                // Nothing: the kept-open lists say "No Claude sessions" in a line of their own (`noClaudeSessionsLine`), and a
                // peek is its header and New session (DESIGN.md 5.6).
                EmptyView()
            } else {
                ForEach(Array(listed.groups.enumerated()), id: \.element.id) { i, group in
                    SessionGroupHeader(group: group, store: store, rail: rail).padding(.top, i == 0 ? 0 : SessionGroup.gap)
                        .id(i == 0 ? "s:top" : group.id)
                    ForEach(group.rows) { row($0, group.placement) }
                }
                if listed.hidden > 0 {
                    MoreSessionsRow(hidden: listed.hidden, waiting: peeked?.waiting ?? 0, hub: hub, rail: rail, action: moreAction)
                        .capEdge().id("s:more")
                }
            }
        }
        .padding(rail == .leading ? .trailing : .leading, inset)
        .motion(Theme.Motion.fade, value: store.agentsRevision)
    }

    /// Kept open, "+N more" shows the rest of the sessions; a peek has no room for them, so it keeps the hub open on
    /// Sessions, which gets all the room.
    private func moreAction() {
        if peekCap == nil { hub.expandSessions(in: store, ui: ui) } else { LookoutHub.animate(LookoutHub.refocus) { hub.pinned = true; hub.focus = .agents } }
    }

    private func row(_ row: AgentRow, _ placement: SessionPlacement) -> some View {
        SessionRow(row: row, store: store, ui: ui, hub: hub, rail: rail, placement: placement)
            .transition(.opacity)
            .capEdge()
            .id("a:" + row.id)
    }
}

/// The groups in a scroll view that stops on a whole row, lazy once the list is long. Cut short, it ends with a line
/// saying so (the system's scrollers are overlay-style, so nothing else does): "+4 more" while Sessions isn't
/// focused, which gives it the room; focused, "+4 below", which scrolls to the end, and "Back to top" once there.
struct SessionsScroll: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let rail: HorizontalEdge
    let cap: CGFloat
    var inset: CGFloat = Theme.Metrics.inset
    @State private var reach = ScrollReach()

    var body: some View {
        // Read here, not in the hub's body: the list changing length doesn't redraw the hub.
        let listed = store.listedGroups(hub)
        let searching = !hub.query.trimmingCharacters(in: .whitespaces).isEmpty
        let matches = searching ? store.hubSessions(hub) : []
        // Searching, the matches are listed flat: cut by the room alone, and scrolled like a focused list.
        let content = searching ? matches.reduce(0) { $0 + SessionGroup.height(of: $1) }
            : SessionGroup.height(listed.groups) + (listed.hidden > 0 ? Theme.Metrics.pitch : 0)
        let cut = content > cap + 0.5
        let scrolls = hub.focus == .agents || searching
        let viewport = cap - Theme.Metrics.pitch
        VStack(spacing: 0) {
            CappedScroll(cap: cut ? viewport : cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(store.hubSessions(hub).count),
                         onReach: scrolls ? { reach.bottom = $0 } : nil) {
                SessionsList(store: store, ui: ui, hub: hub, rail: rail, inset: inset)
            }
            if cut && scrolls {
                SessionsCue(below: { searching ? SessionGroup.below(matches, reach: $0).count : SessionGroup.below(listed.groups, hidden: listed.hidden, reach: $0) },
                            waiting: { searching ? SessionGroup.below(matches, reach: $0).filter(\.isWaiting).count : SessionGroup.waitingBelow(listed.groups, reach: $0) },
                            end: searching ? matches.last.map { "a:" + $0.id } : listed.hidden > 0 ? "s:more" : listed.groups.last?.rows.last.map { "a:" + $0.id },
                            top: searching ? matches.first.map { "a:" + $0.id } : "s:top",
                            viewport: viewport, reach: reach, hub: hub, rail: rail)
                    .padding(rail == .leading ? .trailing : .leading, inset)
            } else if cut {
                let more = SessionGroup.below(listed.groups, hidden: listed.hidden, reach: viewport)
                MoreSessionsRow(hidden: more, waiting: SessionGroup.waitingBelow(listed.groups, reach: viewport), hub: hub, rail: rail,
                                pickable: false, action: showAll)
                    .padding(rail == .leading ? .trailing : .leading, inset)
            }
        }
    }

    private func showAll() {
        LookoutHub.animate(LookoutHub.refocus) { hub.focus = .agents }
    }
}

/// Where a focused list is scrolled to, read by its cue alone: the list moving doesn't redraw anything else.
@Observable @MainActor final class ScrollReach {
    /// The content's y at the viewport's bottom edge; nil before the list has reported (it is at the top).
    var bottom: CGFloat?
}

/// The last line of a list that scrolls and doesn't fit (focused, or a search's matches): how many sessions are below, a
/// click scrolling to them; at the end, the way back up.
private struct SessionsCue: View {
    /// How many sessions are not whole yet in a viewport scrolled to `reach`, and how many of them wait for you.
    let below: (CGFloat) -> Int
    let waiting: (CGFloat) -> Int
    let end: String?
    let top: String?
    let viewport: CGFloat
    let reach: ScrollReach
    let hub: HubState
    let rail: HorizontalEdge

    var body: some View {
        let at = reach.bottom ?? viewport
        let below = below(at)
        if below > 0 {
            MoreSessionsRow(label: "+\(below) below", spoken: plural(below, "session") + " below", hint: "Scrolls to the end", hub: hub, rail: rail,
                            pickable: false, waiting: waiting(at)) {
                if let end { hub.requestScroll(end) }
            }
        } else {
            MoreSessionsRow(label: "Back to top", spoken: "Back to the top", hint: "Scrolls to the first session", hub: hub, rail: rail,
                            pickable: false) {
                if let top { hub.requestScroll(top) }
            }
        }
    }
}

extension SessionGroup {
    /// The gap above every group but the first, and a group header's height.
    static let gap = Theme.Space.md
    static let headerHeight: CGFloat = 28

    /// A row's height: a third line for what it left running.
    static func height(of row: AgentRow) -> CGFloat { row.tasks.isEmpty ? Theme.Metrics.twoLineRow : Theme.Metrics.taskRow }

    /// The height of `groups` laid out: headers, the gaps between groups and every row.
    static func height(_ groups: [SessionGroup]) -> CGFloat {
        groups.enumerated().reduce(0) { sum, entry in
            sum + (entry.offset == 0 ? 0 : gap) + headerHeight + entry.element.rows.reduce(0) { $0 + height(of: $1) }
        }
    }

    /// The least a cut list shows: its first group's header, one whole row and the "+N more" under them. With less room the
    /// list would say there are sessions and show none (a waiting one among them).
    static let leastShown = headerHeight + Theme.Metrics.twoLineRow + Theme.Metrics.pitch

    /// The least the list shows kept open: three sessions under two headers, with the gap between, and the "+N more"
    /// row that ends a list cut short (a list with fewer sessions is only as tall as it is).
    static let leastHeight = 3 * Theme.Metrics.twoLineRow + 2 * headerHeight + gap + Theme.Metrics.pitch

    /// What the inbox keeps of the room the two lists share, whatever Sessions would like: one row (and the gap under it).
    static let inboxLeast: CGFloat = 48

    /// How much of `free` Sessions gets: the room for three sessions when there is that much to spare, else
    /// 45% of it, and never so much that the inbox is left under one row.
    static func share(of free: CGFloat) -> CGFloat {
        min(max(leastHeight, free * 0.45), max(free - inboxLeast, 0))
    }

    /// What a peek of `cap` points lists of `groups` (which `hidden` sessions were already left out of, by
    /// `SessionCap`): in order, whole rows only (a header never stands alone), and how many sessions are left out. With
    /// any left out the last line is the "+N more" row, which is in the cap.
    static func peek(_ groups: [SessionGroup], hidden: Int = 0, cap: CGFloat) -> (groups: [SessionGroup], hidden: Int, waiting: Int) {
        let total = groups.reduce(0) { $0 + $1.rows.count }
        var shown: [SessionGroup] = []
        outer: for group in groups {
            var next = group
            next.rows = []
            shown.append(next)
            for row in group.rows {
                shown[shown.count - 1].rows.append(row)
                if height(shown) > cap {
                    shown[shown.count - 1].rows.removeLast()
                    break outer
                }
            }
        }
        shown.removeAll { $0.rows.isEmpty }
        if shown.isEmpty, var first = groups.first, let row = first.rows.first {
            first.rows = [row]
            shown = [first]
        }
        var count = shown.reduce(0) { $0 + $1.rows.count }
        // Room for "+N more": give up whole rows until it fits, but never the last one (as `PeekCut`: a peek with no room
        // for a row and its line still shows the row, never a list that says it has no sessions).
        while count < total + hidden, height(shown) + Theme.Metrics.pitch > cap, count > 1 {
            shown[shown.count - 1].rows.removeLast()
            shown.removeAll { $0.rows.isEmpty }
            count -= 1
        }
        return (shown, total + hidden - count, Self.waiting(groups) - Self.waiting(shown))
    }

    /// How many sessions a list scrolled to `reach` (the content's y at the viewport's bottom edge) has not shown whole
    /// yet, counting those "+N more" is hiding once its row is not whole either.
    static func below(_ groups: [SessionGroup], hidden: Int, reach: CGFloat) -> Int {
        unseen(groups, reach: reach).count + (hidden > 0 && cutShows(groups, reach: reach) ? hidden : 0)
    }

    /// How many of the sessions `below` counts wait for you: the rows among them (what `hidden` holds never does: the cap
    /// keeps the waiting ones).
    static func waitingBelow(_ groups: [SessionGroup], reach: CGFloat) -> Int {
        unseen(groups, reach: reach).filter(\.isWaiting).count
    }

    /// The rows not whole in a viewport scrolled to `reach`.
    private static func unseen(_ groups: [SessionGroup], reach: CGFloat) -> [AgentRow] {
        var y: CGFloat = 0
        var rows: [AgentRow] = []
        for (i, group) in groups.enumerated() {
            y += (i == 0 ? 0 : gap) + headerHeight
            for row in group.rows {
                y += height(of: row)
                if y > reach + 0.5 { rows.append(row) }
            }
        }
        return rows
    }

    /// Whether the "+N more" row after `groups` is not whole in a viewport scrolled to `reach`.
    private static func cutShows(_ groups: [SessionGroup], reach: CGFloat) -> Bool {
        height(groups) + Theme.Metrics.pitch > reach + 0.5
    }

    /// How many of `groups`' rows are waiting for you, whichever group lists them (a frozen one stays under its project).
    static func waiting(_ groups: [SessionGroup]) -> Int {
        groups.reduce(0) { $0 + $1.rows.filter(\.isWaiting).count }
    }

    /// The matches of a search, which are listed flat, that are not whole in a viewport scrolled to `reach`.
    static func below(_ rows: [AgentRow], reach: CGFloat) -> [AgentRow] {
        var y: CGFloat = 0
        return rows.filter { row in
            y += height(of: row)
            return y > reach + 0.5
        }
    }

    var placement: SessionPlacement {
        switch kind {
        case .waiting: .waiting
        case .project: .project
        case .newActivity: .newActivity
        }
    }
}

/// A group's header: a project's palette dot (hollow for scratch chats), name and count; Waiting for you in amber;
/// New activity with its Keep all. A project's header is where its colour and mute live (right-click).
struct SessionGroupHeader: View {
    let group: SessionGroup
    let store: Store
    let rail: HorizontalEdge?
    @State private var dropTarget = false

    var body: some View {
        let folder = project
        RailRow(rail: rail, height: SessionGroup.headerHeight, tile: { Color.clear }) {
            HStack(spacing: Theme.Space.sm) {
                if let folder { dot(folder) }
                Text(group.title)
                    .font(Theme.Typography.label)
                    .foregroundStyle(group.kind == .waiting ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.secondary))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if folder != nil { Text("\(group.total)").font(Theme.Typography.numeral).foregroundStyle(Theme.tertiary) }
                Spacer(minLength: 0)
                if group.kind == .newActivity { keepAll }
            }
        }
        .contentShape(Rectangle())
        .modifier(ReorderableProject(folder: folder.flatMap { $0.isEmpty ? nil : $0 }, store: store, dropTarget: $dropTarget))
        .overlay(Theme.Radius.shape(Theme.Radius.row).strokeBorder(dropTarget ? Theme.accent : .clear, lineWidth: 1.5))
        .contextMenu { if let folder { ProjectMenu(folder: folder, name: group.title, store: store) } }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if let folder {
                Button("Mute \(group.title)") { store.muteFolder(folder) }
                if store.canMoveProject(folder, by: -1) { Button("Move project up") { LookoutHub.animate { store.moveProject(folder, by: -1) } } }
                if store.canMoveProject(folder, by: 1) { Button("Move project down") { LookoutHub.animate { store.moveProject(folder, by: 1) } } }
            }
        }
    }

    private var project: String? {
        if case .project(let folder) = group.kind { folder } else { nil }
    }

    /// 6pt in the project's colour; scratch chats have none, so theirs is an outline (the names still line up).
    @ViewBuilder private func dot(_ folder: String) -> some View {
        if let color = store.projectColor(folder) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
        } else {
            Circle().strokeBorder(Theme.tertiary, lineWidth: 1).frame(width: 6, height: 6).accessibilityHidden(true)
        }
    }

    private var keepAll: some View {
        Button { LookoutHub.animate { store.keepAllAgents() } } label: {
            Text("Keep all").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                .frame(minHeight: Theme.Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.small)
        .help("Keeps every session under New activity")
    }
}

/// "+3 more" at the end of the list: shows the rest. Also the line a list cut short ends with (see `SessionsScroll`),
/// which no key picks: ⌘3 gives Sessions the room, and the arrows scroll.
struct MoreSessionsRow: View {
    let label: String
    let spoken: String
    let hint: String
    let hub: HubState
    let rail: HorizontalEdge?
    var pickable = true
    /// How many of the sessions it stands for wait for you: said in amber, so a count never hides blocked work.
    var waiting = 0
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(hidden: Int, waiting: Int = 0, hub: HubState, rail: HorizontalEdge?, pickable: Bool = true, action: @escaping () -> Void) {
        self.init(label: "+\(hidden) more", spoken: plural(hidden, "more session"), hint: "Shows them", hub: hub, rail: rail,
                  pickable: pickable, waiting: waiting, action: action)
    }

    init(label: String, spoken: String, hint: String, hub: HubState, rail: HorizontalEdge?, pickable: Bool = true, waiting: Int = 0,
         action: @escaping () -> Void) {
        self.label = label
        self.spoken = spoken
        self.hint = hint
        self.hub = hub
        self.rail = rail
        self.pickable = pickable
        self.waiting = waiting
        self.action = action
    }

    var body: some View {
        let picked = pickable && hub.selection == "s:more"
        Button(action: action) {
            RailRow(rail: rail, height: Theme.Metrics.pitch, fill: picked ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Theme.Fill.rest,
                    picked: picked, tile: { Color.clear }) {
                HStack(spacing: Theme.Space.md) {
                    Text(label).font(Theme.Typography.control).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                    if waiting > 0 { Text("\(waiting) waiting").font(Theme.Typography.numeral).foregroundStyle(Theme.amber) }
                }
            }
        }
        .buttonStyle(.plain)
        .modifier(CueFocus(pickable: pickable, focused: $focused))
        .onHover { hovering = $0 }
        .accessibilityLabel(waiting > 0 ? "\(spoken), \(waiting) waiting for you" : spoken)
        .accessibilityHint(hint)
    }
}

/// A "+N more" that is a keyboard target (↑↓ pick it) is not on the Tab ring; one that no key picks (the cue under a
/// list that scrolls) is chrome, with the shared ring.
private struct CueFocus: ViewModifier {
    let pickable: Bool
    var focused: FocusState<Bool>.Binding

    @ViewBuilder func body(content: Content) -> some View {
        if pickable {
            content.focusable(false)
        } else {
            content.focused(focused).focusRing(Theme.Radius.row, inset: true, isFocused: focused.wrappedValue).reportsControlFocus(focused.wrappedValue)
        }
    }
}

/// A session: its tile in the rail; its title and status; the question or summary; a line for what it left running.
/// 44pt tall, 60 with that line. One action, shown on hover, keyboard pick and VoiceOver focus; the rest are in the
/// context menu and VoiceOver's actions.
struct SessionRow: View {
    let row: AgentRow
    let store: Store
    let ui: UIState
    let hub: HubState
    let rail: HorizontalEdge?
    let placement: SessionPlacement
    @State private var dropTarget = false
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @Environment(\.resolved) private var resolved

    /// Keep for a session that isn't yours yet, Hide for the others (see `Store.dismissAgent`).
    private var keeps: Bool { row.pending && (placement == .newActivity || placement == .search) }
    /// Line 2's centre, where the action sits.
    private static let actionTop: CGFloat = 31

    /// The row's ages (the status it shows, and the one it speaks) come from one clock: a working session under a minute old
    /// counts seconds, everything else the minute clock, and only while the row is on screen.
    var body: some View {
        Ticking(since: row.session.running && !row.isWaiting ? row.workingSince : nil) { now in content(now: now) }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let id = "a:" + row.id
        let picked = hub.selection == id && hub.keyboardSelection?.id == id
        let hot = ui.drawerSelection == row.id
        let showsAction = hot || picked || voiceOverFocused
        Button { store.openAgent(row.id) } label: {
            RailRow(rail: rail, height: SessionGroup.height(of: row), fill: picked ? Theme.Fill.selected : hot ? Theme.Fill.hover : Theme.Fill.rest,
                    picked: picked, tile: { AgentTile(row: row) }, content: { lines(now: now) })
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay(alignment: .topTrailing) {
            if showsAction { action.padding(.top, Self.actionTop - Theme.Metrics.iconButton / 2).padding(.trailing, RailRow<EmptyView, EmptyView>.textEnd(rail)) }
        }
        .motion(Theme.Motion.hover, value: showsAction)
        .modifier(Reorderable(enabled: placement == .project, row: row, store: store, dropTarget: $dropTarget))
        .overlay(Theme.Radius.shape(Theme.Radius.row).strokeBorder(dropTarget ? Theme.accent : .clear, lineWidth: 1.5))
        .onHover { inside in
            if inside {
                ui.drawerSelection = row.id
            } else if !picked {
                // The pointer left: keys don't act on this row any more (unless the keyboard is what picked it).
                if ui.drawerSelection == row.id { ui.drawerSelection = nil }
                if hub.selection == id { hub.selection = nil }
            }
        }
        .help(help)
        .tip(row.session.title, plainHeadline.isEmpty ? nil : plainHeadline, focused: picked, hover: false)
        .sessionMenu(row, store)
        .rowMenuTarget(id, hub: hub)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.session.title)
        .accessibilityValue(row.spokenValue(now: now))
        .accessibilityHint(row.spokenHint.isEmpty ? "Opens it in Claude" : row.spokenHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityFocused($voiceOverFocused)
        .voiceOverTarget(id, hub: hub, focus: $voiceOverFocused)
        .accessibilityAction { store.openAgent(row.id) }
        .accessibilityActions {
            Button(row.unread ? "Mark as read" : "Mark as unread") { store.toggleAgentRead(row.id) }
            if row.pending { Button("Keep") { store.keepAgent(row.id) } }
            Button("Hide") { store.dismissAgent(row.id) }
            if store.canMoveAgent(row.id, by: -1) { Button("Move up") { store.moveAgent(row.id, by: -1) } }
            if store.canMoveAgent(row.id, by: 1) { Button("Move down") { store.moveAgent(row.id, by: 1) } }
        }
    }

    private func lines(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            HStack(spacing: Theme.Space.md) {
                Text(row.session.title)
                    .font(row.unread || row.isWaiting ? Theme.Typography.title : Theme.Typography.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                status(now: now).fixedSize()
            }
            HStack(spacing: Theme.Space.md) {
                headline.font(Theme.Typography.meta).lineLimit(1)
                Spacer(minLength: 0)
                // Room for the action, always: nothing re-flows when it shows.
                Color.clear.frame(width: Theme.Metrics.iconButton, height: 1)
            }
            if let first = row.tasks.first { taskLine(first) }
        }
    }

    /// "Waiting" in amber, "Working 2m", "Finished 4m".
    @ViewBuilder private func status(now: Date) -> some View {
        if row.isWaiting {
            Text("Waiting").font(Theme.Typography.numeral).foregroundStyle(Theme.amber)
        } else {
            Text(row.statusLabel(now: now)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
        }
    }

    /// The question or summary, led by the project's name where the group doesn't say it.
    private var headline: Text {
        let text = Text(row.headline).foregroundStyle(Theme.secondary)
        guard placement.namesProject else { return text }
        let project = Text(row.session.folderName).foregroundStyle(Theme.tertiary)
        return plainHeadline.isEmpty ? project : project + Text(" · ").foregroundStyle(Theme.tertiary) + text
    }

    private var plainHeadline: String { String(row.headline.characters) }

    /// The first thing it left running, in full, and how many more there are; the whole list on hover.
    private func taskLine(_ first: ClaudeTask) -> some View {
        HStack(spacing: 5) {
            Image(systemName: first.kind == .agent ? "asterisk" : "terminal")
                .font(Theme.Typography.glyph(10))
                .frame(width: 12)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                Text(first.title).lineLimit(1)
                if row.tasks.count > 1 { Text(" · +\(row.tasks.count - 1) more").fixedSize() }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.secondary)
        .help(row.tasks.map(\.title).joined(separator: "\n"))
    }

    @ViewBuilder private var action: some View {
        if keeps {
            IconButton(symbol: "bookmark", help: "Keep", detail: "Keeps it in your list · \(store.shortcut(.keepSession).display)", tabStop: false) {
                LookoutHub.animate { store.keepAgent(row.id) }
            }
        } else {
            IconButton(symbol: "eye.slash", help: "Hide", detail: "Comes back on new activity · \(store.shortcut(.removeSession).display)", tabStop: false) {
                LookoutHub.animate { store.dismissAgent(row.id) }
            }
        }
    }

    /// The title, then what it says: also for the row the keyboard picked.
    private var help: String { plainHeadline.isEmpty ? row.session.title : row.session.title + "\n" + plainHeadline }
}

/// Your sessions in a project can be dragged onto one another to reorder them; everything else stays put.
struct Reorderable: ViewModifier {
    let enabled: Bool
    let row: AgentRow
    let store: Store
    @Binding var dropTarget: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        if !enabled || row.pending {
            content
        } else {
            content
                .draggable("agent:" + row.id) {
                    Text(row.session.title)
                        .font(Theme.Typography.title)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.Metrics.tile)
                        .background(Capsule().fill(Theme.bg))
                        .foregroundStyle(Theme.text)
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id.hasPrefix("agent:") else { return false }
                    withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { store.moveAgent(String(id.dropFirst(6)), onto: row.id) }
                    return true
                } isTargeted: { dropTarget = $0 }
        }
    }
}

/// A project's header can be dragged onto another's to put it there (its sessions go with it); the same is in its menu and
/// VoiceOver's actions. Scratch has no place to move to.
struct ReorderableProject: ViewModifier {
    let folder: String?
    let store: Store
    @Binding var dropTarget: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    @ViewBuilder func body(content: Content) -> some View {
        if let folder {
            content
                .draggable("project:" + folder) {
                    Text(URL(fileURLWithPath: folder).lastPathComponent)
                        .font(Theme.Typography.title)
                        .padding(.horizontal, 10)
                        .frame(height: Theme.Metrics.tile)
                        .background(Capsule().fill(Theme.bg))
                        .foregroundStyle(Theme.text)
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id.hasPrefix("project:") else { return false }
                    withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { store.moveProject(String(id.dropFirst(8)), onto: folder) }
                    return true
                } isTargeted: { dropTarget = $0 }
        } else {
            content
        }
    }
}

/// The list's last row: a neutral "+" tile in the rail, "New session" (a scratch chat), and a menu of the projects to
/// start one in.
struct NewSessionRow: View {
    let store: Store
    let hub: HubState
    let rail: HorizontalEdge?
    var inset: CGFloat = Theme.Metrics.inset
    @State private var hovering = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        let picked = hub.selection == "s:new"
        let lit = hovering || picked
        Button { store.startScratchSession() } label: {
            RailRow(rail: rail, height: Theme.Metrics.pitch, fill: picked ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Theme.Fill.rest,
                    picked: picked, tile: {
                        Image(systemName: "plus")
                            .font(Theme.Typography.glyph(12, .bold))
                            .foregroundStyle(lit ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
                            .tile(Theme.Metrics.tile, fill: lit ? Theme.Fill.selected : Theme.Fill.tile)
                    }) {
                Text("New session").font(Theme.Typography.body).foregroundStyle(lit ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        // Named before the chevron goes over it: a label put on the whole would replace the chevron's own.
        .accessibilityLabel("New session")
        .accessibilityHint("Starts a chat with no folder. The menu picks a project.")
        .overlay(alignment: .trailing) { projects.padding(.trailing, RailRow<EmptyView, EmptyView>.textEnd(rail) - 6) }
        .onHover { hovering = $0 }
        .padding(rail == .leading ? .trailing : .leading, inset)
        .onChange(of: hub.projectsMenuRequest) { _, _ in presentProjects() }
    }

    /// The chevron opens the menu of projects: an AppKit menu, so → on the row can open it too.
    private var projects: some View {
        Button(action: presentProjects) {
            Image(systemName: "chevron.down")
                .font(Theme.Typography.glyph(11, .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: Theme.Metrics.iconButton, height: Theme.Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.small)
        .background(MenuAnchorView(anchor: anchor))
        .help("Start a session in a project")
        .accessibilityLabel("New session in a project")
        .accessibilityHint("Shows the projects")
    }

    /// Under the chevron, a moment later: not from inside the update or the key handler that asked.
    private func presentProjects() {
        Task { @MainActor in
            guard let view = anchor.view else { return }
            ProjectsMenu.make(store).popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY : 0), in: view)
        }
    }

    /// The app's new-session link with no folder opens its composer with none picked: a scratch session.
    static func startScratch() {
        guard let url = URL(string: "claude://code/new") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A project's colour as a menu item's image (a menu draws an image, not a view): a 10pt dot, or nothing.
private struct Swatch: View {
    let color: Color?

    var body: some View {
        if let color { Image(nsImage: Self.image(color)) }
    }

    static func image(_ color: Color) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}

/// Where a menu pops up from: the view behind the control that opens it.
@MainActor final class MenuAnchor {
    weak var view: NSView?
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// New session's menu of projects: Scratch, then every project by name, the most recent first. The row's chevron and the
/// bar's "+" show the same one (DESIGN.md 5.6): this is what they are both made from.
enum ProjectsMenu {
    struct Entry {
        let folder: String
        let name: String
        let color: Color?
    }

    /// Every project a session has been seen in, most recent first, with its palette colour.
    @MainActor static func entries(_ store: Store) -> [Entry] {
        store.recentFolders.map { Entry(folder: $0, name: URL(fileURLWithPath: $0).lastPathComponent, color: store.projectColor($0)) }
    }

    @MainActor static func make(_ store: Store) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Scratch (no folder)") { store.startScratchSession() })
        menu.addItem(.separator())
        for entry in entries(store) {
            let item = ActionItem(entry.name) { store.startAgent(in: entry.folder) }
            item.image = entry.color.map(Swatch.image)
            menu.addItem(item)
        }
        return menu
    }

    /// A menu item that runs a closure.
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func run() { handler() }
    }
}

/// `ProjectsMenu` as SwiftUI menu items, for the bar's "+".
struct ProjectsMenuItems: View {
    let store: Store

    var body: some View {
        let entries = ProjectsMenu.entries(store)
        Button("Scratch (no folder)") { store.startScratchSession() }
        if !entries.isEmpty { Divider() }
        ForEach(entries, id: \.folder) { entry in
            Button { store.startAgent(in: entry.folder) } label: {
                Label { Text(entry.name) } icon: { Swatch(color: entry.color) }
            }
        }
    }
}

extension HubState {
    /// Picks the first session waiting on you and scrolls to it. A search that left it out, or another section
    /// focused, would hide the row: both go first, so there is a row to scroll to.
    func pickFirstWaiting(in store: Store, ui: UIState) {
        guard let id = store.sessionGroups.first(where: { $0.kind == .waiting })?.rows.first?.id else { return }
        if !query.isEmpty || (focus != nil && focus != .agents) {
            LookoutHub.animate(LookoutHub.refocus) {
                query = ""
                if focus != .agents { focus = nil }
            }
        }
        selection = "a:" + id
        requestScroll("a:" + id)
        ui.drawerSelection = id
    }

    /// "+N more" opens the rest of New activity and scrolls to its first row. A keyboard pick moves there with it (the
    /// "+N more" row is gone), so the arrows go on from the rows just revealed.
    func expandSessions(in store: Store, ui: UIState) {
        let revealed = store.firstHiddenSession(self)
        let picked = selection == "s:more"
        LookoutHub.animate {
            sessionsExpanded = true
            guard let revealed else { return }
            if picked {
                selection = "a:" + revealed
                ui.drawerSelection = revealed
            }
            requestScroll("a:" + revealed)
        }
    }

    /// Return on a row of the list that isn't a session: "+N more", New session.
    func activateSessionTarget(_ target: String, store: Store, ui: UIState) {
        if target == "s:more" { expandSessions(in: store, ui: ui) } else { store.startScratchSession() }
    }
}

extension Store {
    /// Sessions as the hub lists them, in the order they show (and the keys walk): your groups, or any session
    /// matching the search.
    func hubSessions(_ hub: HubState) -> [AgentRow] {
        guard agents.enabled else { return [] }
        if !hub.query.trimmingCharacters(in: .whitespaces).isEmpty {
            let memo = hub.sessionMemo
            if memo.revision == agentsRevision, memo.query == hub.query { return memo.result }
            let result = searchSessions(hub.query)
            hub.sessionMemo = SessionSearchMemo(query: hub.query, revision: agentsRevision, result: result)
            return result
        }
        return listedGroups(hub).groups.flatMap(\.rows)
    }

    /// The first session "+N more" is hiding.
    func firstHiddenSession(_ hub: HubState) -> String? { listedGroups(expanded: false, frozen: hub.frozenSessions).hiddenIDs.first }

    /// What the keys can pick after the session rows: "+N more" while the list is cut, then New session.
    func sessionExtraTargets(_ hub: HubState) -> [String] {
        guard agents.enabled, hub.query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (listedGroups(hub).hidden > 0 ? ["s:more"] : []) + ["s:new"]
    }
}

extension LookoutHub {
    /// The tile column's side for this edge.
    var railSide: HorizontalEdge { edge == .right ? .trailing : .leading }

    /// What the Sessions header says beside its title: while searching, how many were found (as the Inbox group's label
    /// counts), and nothing when neither group found any; else, once the section is only its header (another is focused)
    /// while something needs you, "1 waiting" (a button: it picks the first one). Open, the Waiting for you group says it
    /// (DESIGN.md 10.5).
    var agentsStatus: (text: String, color: AnyShapeStyle)? {
        if searching { return searchFoundNothing ? nil : ("\(store.hubSessions(hub).count)", AnyShapeStyle(Theme.secondary)) }
        let waiting = store.agentCounts.blocked
        return waiting > 0 && shrunk(.agents) ? ("\(waiting) waiting", AnyShapeStyle(Theme.amber)) : nil
    }

    /// "Sessions" and its status.
    var agentsHeader: some View {
        SectionHeader(title: "Sessions", status: agentsStatus,
                      statusAction: searching ? nil : pickFirstWaiting, focused: hub.focus == .agents,
                      expandHelp: hub.focus == .agents ? "Back to all sections" : "Expand Sessions",
                      onFocus: showsDetail ? {
                          withAnimation(Self.refocus.resolved(reduce: reduce)) { hub.focus = hub.focus == .agents ? nil : .agents }
                      } : nil) {}
            .voiceOverTarget("h:agents", hub: hub)
    }

    /// The first row of Waiting for you, picked as the keys would, and scrolled to.
    func pickFirstWaiting() {
        hub.pickFirstWaiting(in: store, ui: ui)
    }

    /// The groups, scrolling once past `cap`, always on a whole row.
    func sessionsScroll(cap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionsScroll(store: store, ui: ui, hub: hub, rail: railSide, cap: cap)
            if let undo = store.undoStack.visible(in: .agents) {
                UndoLine(message: undo.message) { store.undoLast() }
                    .padding(.horizontal, Theme.Metrics.inset).padding(.top, Theme.Space.xs)
            }
        }
        .motion(Theme.Motion.fade, value: store.undoStack.visibleID)
    }

    /// A peek's groups: whole rows up to `cap`, then "+N more" (never a scroll view or a fade).
    func sessionsPeek(cap: CGFloat) -> some View {
        SessionsList(store: store, ui: ui, hub: hub, rail: nil, inset: 0, peekCap: cap)
    }

    /// New session, under the list (not while searching).
    @ViewBuilder func newSessionRow(inset: CGFloat = Theme.Metrics.inset, tile: Bool = true) -> some View {
        if !searching { NewSessionRow(store: store, hub: hub, rail: tile ? railSide : nil, inset: inset) }
    }
}

// MARK: - Menus

/// A session's context menu: open, read state, keep, hide, move, its project's colour, mute, label.
struct SessionMenu: View {
    let row: AgentRow
    let store: Store
    /// Opens the label editor (`LabelEditor`) wherever the caller hosts it.
    var editLabel: () -> Void = {}

    var body: some View {
        Button("Open in Claude") { store.openAgent(row.id) }
        Button(row.unread ? "Mark as read" : "Mark as unread") { store.toggleAgentRead(row.id) }
        Divider()
        if row.pending { Button("Keep") { store.keepAgent(row.id) } }
        Button("Hide") { store.dismissAgent(row.id) }
        if store.canMoveAgent(row.id, by: -1) { Button("Move up") { store.moveAgent(row.id, by: -1) } }
        if store.canMoveAgent(row.id, by: 1) { Button("Move down") { store.moveAgent(row.id, by: 1) } }
        Divider()
        ProjectMenu(folder: row.session.folderKey, name: row.session.folderName, store: store)
        Divider()
        Button("Change label…") { editLabel() }
    }
}

/// What a project's header and its sessions' menus share: its colour (not for scratch chats), and muting it.
struct ProjectMenu: View {
    let folder: String
    let name: String
    let store: Store

    var body: some View {
        if !folder.isEmpty {
            Menu("Colour") {
                Picker("Colour", selection: Binding(get: { store.agents.folderColors[folder] ?? 0 },
                                                    set: { store.setProjectColor(folder, $0) })) {
                    ForEach(Theme.projectColors.indices, id: \.self) { i in
                        Label { Text(Theme.projectColorNames[i]) } icon: { Swatch(color: Theme.projectColors[i]) }.tag(i)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        if store.canMoveProject(folder, by: -1) { Button("Move project up") { LookoutHub.animate { store.moveProject(folder, by: -1) } } }
        if store.canMoveProject(folder, by: 1) { Button("Move project down") { LookoutHub.animate { store.moveProject(folder, by: 1) } } }
        Button("Mute \u{201C}\(name)\u{201D}") { store.muteFolder(folder) }
    }
}

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
    /// A session's context menu, and the popover its label editor opens in.
    func sessionMenu(_ row: AgentRow, _ store: Store) -> some View { modifier(SessionContextMenu(row: row, store: store)) }
}

/// A session's label: letters (two, or the title's own), an emoji, or the icon picked for it.
struct LabelEditor: View {
    enum Mode: Hashable { case letters, emoji, icon }

    let row: AgentRow
    let store: Store
    @State private var mode = Mode.letters
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Label for \(row.session.title)").font(Theme.Typography.title).lineLimit(1)
            Tabs(label: "Label style", tabs: modes, selection: mode) { mode = $0; text = ""; focused = true }
            switch mode {
            case .letters:
                entry(prompt: row.label, name: "Session letters", help: "Two letters; empty goes back to the title's")
            case .emoji:
                HStack(spacing: Theme.Space.sm) {
                    entry(prompt: "🙂", name: "Session emoji", help: "One emoji; empty removes it")
                    IconButton(symbol: "face.smiling", help: "Emoji") {
                        focused = true
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                }
            case .icon:
                Text(iconNote).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                HStack(spacing: Theme.Space.sm) {
                    if store.canPickIcons {
                        BorderedButton(row.entry.icon == nil ? "Pick an icon" : "Pick another icon") {
                            store.setAgentLabel(row.id, nil)
                            if row.entry.icon != nil { store.repickIcon(row.id) } else { store.pickIcons() }
                            dismiss()
                        }
                    }
                    if row.entry.label != nil, row.entry.icon != nil {
                        BorderedButton("Use it") { store.setAgentLabel(row.id, nil); dismiss() }
                    }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 260)
        .onAppear {
            mode = row.entry.label.map { AgentLabel.isEmoji($0) ? .emoji : .letters } ?? (row.icon != nil ? .icon : .letters)
            // What you set is what the field starts with: saving it again keeps it.
            text = row.entry.label ?? ""
            focused = mode != .icon
        }
    }

    /// An icon already picked stays available while picking is off: it just can't be replaced.
    private var modes: [Tabs<Mode>.Tab] {
        [.init(id: .letters, title: "Letters"), .init(id: .emoji, title: "Emoji")]
            + (store.canPickIcons || row.entry.icon != nil ? [.init(id: .icon, title: "Icon")] : [])
    }

    private var iconNote: String {
        if row.entry.icon == nil { return "Jev picks an icon from the title and the first message." }
        return store.canPickIcons ? "Jev picked this icon for it." : "Jev picked this icon for it. To pick another, turn on Icons picked for you, and add its key, in Settings."
    }

    private func entry(prompt: String, name: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                TextField(prompt, text: $text)
                    .focused($focused)
                    .fieldStyle(focused: focused)
                    .frame(width: 90)
                    .onSubmit(save)
                BorderedButton("Save", action: save)
            }
            Text(help).font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
        }
    }

    /// The label an emptied field saves: nil clears it, letters from the title replace an icon.
    static func reset(_ mode: Mode, title: String, folder: String, hasIcon: Bool) -> String? {
        mode == .letters && hasIcon ? AgentLabel.candidates(title, folder: folder).first : nil
    }

    /// Empty resets what the mode in front of you holds: Letters go back to the title's (and over an icon that was picked,
    /// since the icon is what clearing the label alone would bring back), an emoji is removed.
    private func save() {
        if text.isEmpty {
            store.setAgentLabel(row.id, Self.reset(mode, title: row.session.title, folder: row.session.folderName, hasIcon: row.entry.icon != nil))
        } else if let label = AgentLabel.sanitize(text) {
            guard AgentLabel.isEmoji(label) == (mode == .emoji) else { return }
            store.setAgentLabel(row.id, label)
        }
        dismiss()
    }
}

// MARK: - Status lines

/// The Claude link's state as a dot and a line ("Synced with Claude", "Claude's sessions not found"…).
struct ClaudeLinkStatus: View {
    let store: Store

    /// The line and what it leaves out (what to do, or why): the tooltip, VoiceOver's hint and the Details popover say it.
    @MainActor static func describe(_ link: ClaudeLink) -> (color: AnyShapeStyle, text: String, detail: String) {
        switch link {
        case .ok where Claude.isRunning: (AnyShapeStyle(Theme.tertiary), "Synced with Claude", "Updates as the Claude app writes its session files")
        case .ok, .off: (AnyShapeStyle(Theme.tertiary), "Claude isn't running", "Sessions update again when the app is open")
        case .missing: (AnyShapeStyle(Theme.red), "Claude's sessions not found", "Open the Claude desktop app once")
        case .unreadable: (AnyShapeStyle(Theme.red), "Can't read Claude's sessions", "The app's session format changed")
        }
    }

    var body: some View {
        let (color, text, detail) = Self.describe(store.claudeLink)
        Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
        Text(text).tip(text, detail).accessibilityHint(detail)
    }
}

/// "N API calls left this hour", only when the shared GitHub rate limit is running low.
struct RateLimitWarning: View {
    let store: Store

    var body: some View {
        if let rate = store.rateRemaining, rate < 500 {
            Label("\(rate.formatted()) API calls left this hour", systemImage: "exclamationmark.triangle.fill")
                .monospacedDigit()
                .foregroundStyle(Theme.amber)
                .tip("GitHub rate limit low",
                     "Shared with gh and other tools using your account. Syncing pauses at 0 until the hour resets.")
        }
    }
}

extension EnvironmentValues {
    /// Playground only: force a tooltip to show.
    @Entry var previewTip: String? = nil
}
