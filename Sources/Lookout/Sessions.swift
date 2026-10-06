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
/// in a peek and kept open, on every edge: only the side the tile is on changes. The row's height is its own, so the
/// fill, the pick bar and the focus ring span all of it.
struct RailRow<Tile: View, Content: View>: View {
    /// The screen's side on the left and right edges, the leading edge along the top and bottom.
    let rail: HorizontalEdge
    let height: CGFloat
    var fill = Color.clear
    var picked = false
    @ViewBuilder let tile: Tile
    @ViewBuilder let content: Content
    @Environment(\.resolved) private var resolved

    /// The fill starts this far in from the rail's side, so the tile sits inside it.
    private static var fillInset: CGFloat { 4 }

    /// How far the text's end is from the row's end on the side `rail` puts the tile: a trailing action lines up here.
    static func textEnd(_ rail: HorizontalEdge) -> CGFloat {
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
                .padding(rail == .leading ? .leading : .trailing, Self.fillInset)
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
    let rail: HorizontalEdge
    /// The hub's own inset on the side away from the tile; peeks pad themselves, and pass 0.
    var inset: CGFloat = Theme.Metrics.inset
    var peekCap: CGFloat?

    var body: some View {
        let searching = !hub.query.trimmingCharacters(in: .whitespaces).isEmpty
        let listed = peekCap.map { SessionGroup.peek(store.sessionGroups, cap: $0) } ?? store.listedGroups(expanded: hub.sessionsExpanded)
        AdaptiveStack(count: store.hubSessions(hub).count, alignment: .leading, spacing: 0) {
            if searching {
                ForEach(store.hubSessions(hub)) { row($0, .search) }
            } else if listed.groups.isEmpty {
                EmptyBlock("No Claude sessions")
            } else {
                ForEach(Array(listed.groups.enumerated()), id: \.element.id) { i, group in
                    SessionGroupHeader(group: group, store: store, rail: rail).padding(.top, i == 0 ? 0 : SessionGroup.gap)
                    ForEach(group.rows) { row($0, group.placement) }
                }
                if listed.hidden > 0 {
                    MoreSessionsRow(hidden: listed.hidden, hub: hub, rail: rail, action: moreAction).capEdge().id("s:more")
                }
            }
        }
        .padding(rail == .leading ? .trailing : .leading, inset)
        .motion(Theme.Motion.fade, value: store.agentsRevision)
    }

    /// Kept open, "+N more" shows the rest of New activity; a peek has no room for them, so it keeps the hub open on
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

/// The groups in a scroll view that stops on a whole row, lazy once the list is long. Cut short while Sessions isn't
/// focused, it ends with "Show all 12" (the system's scrollers are overlay-style, so nothing else says there is more),
/// which gives Sessions the room.
struct SessionsScroll: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let rail: HorizontalEdge
    let cap: CGFloat
    var inset: CGFloat = Theme.Metrics.inset

    var body: some View {
        // Read here, not in the hub's body: the list changing length doesn't redraw the hub.
        let listed = store.listedGroups(expanded: hub.sessionsExpanded)
        let count = listed.groups.reduce(0) { $0 + $1.rows.count } + listed.hidden
        let cut = hub.focus != .agents && hub.query.trimmingCharacters(in: .whitespaces).isEmpty
            && SessionGroup.height(listed.groups) + (listed.hidden > 0 ? Theme.Metrics.pitch : 0) > cap + 0.5
        VStack(spacing: 0) {
            CappedScroll(cap: cut ? cap - Theme.Metrics.pitch : cap, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(store.hubSessions(hub).count),
                         fades: false, indicators: true) {
                SessionsList(store: store, ui: ui, hub: hub, rail: rail, inset: inset)
            }
            if cut {
                MoreSessionsRow(label: "Show all \(count)", spoken: "All " + plural(count, "session"), hub: hub, rail: rail,
                                pickable: false, action: showAll)
                    .padding(rail == .leading ? .trailing : .leading, inset)
            }
        }
    }

    private func showAll() {
        LookoutHub.animate(LookoutHub.refocus) { hub.focus = .agents }
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

    /// The least the list shows kept open: three sessions under two headers, with the gap between, and the "Show all"
    /// row that ends a list cut short (a list with fewer sessions is only as tall as it is).
    static let leastHeight = 3 * Theme.Metrics.twoLineRow + 2 * headerHeight + gap + Theme.Metrics.pitch

    /// What a peek of `cap` points lists: the groups in order, whole rows only (a header never stands alone), and
    /// how many sessions are left out. With any left out the last line is the "+N more" row, which is in the cap.
    static func peek(_ groups: [SessionGroup], cap: CGFloat) -> (groups: [SessionGroup], hidden: Int) {
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
        var count = shown.reduce(0) { $0 + $1.rows.count }
        // Room for "+N more": give up whole rows until it fits.
        while count < total, height(shown) + Theme.Metrics.pitch > cap, count > 0 {
            shown[shown.count - 1].rows.removeLast()
            shown.removeAll { $0.rows.isEmpty }
            count -= 1
        }
        return (shown, total - count)
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
    let rail: HorizontalEdge

    var body: some View {
        let folder = project
        RailRow(rail: rail, height: SessionGroup.headerHeight, tile: { Color.clear }) {
            HStack(spacing: Theme.Space.sm) {
                if let folder { dot(folder) }
                Text(group.title)
                    .font(Theme.Typography.label)
                    .foregroundStyle(group.kind == .waiting ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Theme.secondary))
                    .lineLimit(1)
                if folder != nil { Text("\(group.total)").font(Theme.Typography.numeral).foregroundStyle(Theme.tertiary) }
                Spacer(minLength: 0)
                if group.kind == .newActivity { keepAll }
            }
        }
        .contentShape(Rectangle())
        .contextMenu { if let folder { ProjectMenu(folder: folder, name: group.title, store: store) } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
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

/// "+3 more" at the end of the list: shows the rest. Also the list's own "Show all" when it is cut short, which no key
/// picks (⌘3 gives Sessions the room too).
struct MoreSessionsRow: View {
    let label: String
    let spoken: String
    let hub: HubState
    let rail: HorizontalEdge
    var pickable = true
    let action: () -> Void
    @State private var hovering = false

    init(hidden: Int, hub: HubState, rail: HorizontalEdge, action: @escaping () -> Void) {
        self.init(label: "+\(hidden) more", spoken: plural(hidden, "more session"), hub: hub, rail: rail, action: action)
    }

    init(label: String, spoken: String, hub: HubState, rail: HorizontalEdge, pickable: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.spoken = spoken
        self.hub = hub
        self.rail = rail
        self.pickable = pickable
        self.action = action
    }

    var body: some View {
        let picked = pickable && hub.selection == "s:more"
        Button(action: action) {
            RailRow(rail: rail, height: Theme.Metrics.pitch, fill: picked ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Theme.Fill.rest,
                    picked: picked, tile: { Color.clear }) {
                Text(label).font(Theme.Typography.body).foregroundStyle(Theme.secondary)
            }
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .onHover { hovering = $0 }
        .accessibilityLabel(spoken)
        .accessibilityHint("Shows them")
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
    let rail: HorizontalEdge
    let placement: SessionPlacement
    @State private var dropTarget = false
    @AccessibilityFocusState private var voiceOverFocused: Bool
    @Environment(\.resolved) private var resolved

    /// Keep for a session that isn't yours yet, Hide for the others (see `Store.dismissAgent`).
    private var keeps: Bool { row.pending && (placement == .newActivity || placement == .search) }
    /// Line 2's centre, where the action sits.
    private static let actionTop: CGFloat = 31

    var body: some View {
        let id = "a:" + row.id
        let picked = hub.selection == id && hub.keyboardSelection?.id == id
        let hot = ui.drawerSelection == row.id
        let showsAction = hot || picked || voiceOverFocused
        Button { store.openAgent(row.id) } label: {
            RailRow(rail: rail, height: SessionGroup.height(of: row), fill: picked ? Theme.Fill.selected : hot ? Theme.Fill.hover : Theme.Fill.rest,
                    picked: picked, tile: { AgentTile(row: row) }, content: { lines })
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
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
        .sessionMenu(row, store)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.session.title)
        .accessibilityValue(row.spokenValue())
        .accessibilityHint(row.spokenHint.isEmpty ? "Opens it in Claude" : row.spokenHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityFocused($voiceOverFocused)
        .accessibilityAction { store.openAgent(row.id) }
        .accessibilityActions {
            Button(row.unread ? "Mark as read" : "Mark as unread") { store.toggleAgentRead(row.id) }
            if row.pending { Button("Keep") { store.keepAgent(row.id) } }
            Button("Hide") { store.dismissAgent(row.id) }
            if store.canMoveAgent(row.id, by: -1) { Button("Move up") { store.moveAgent(row.id, by: -1) } }
            if store.canMoveAgent(row.id, by: 1) { Button("Move down") { store.moveAgent(row.id, by: 1) } }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            HStack(spacing: Theme.Space.md) {
                Text(row.session.title)
                    .font(row.unread || row.isWaiting ? Theme.Typography.title : Theme.Typography.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                status.fixedSize()
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

    /// "Waiting" in amber, "Working 2m", "Finished 4m". The ages follow the 30-second clock; only a working session
    /// under a minute old counts seconds, and only while it is on screen.
    @ViewBuilder private var status: some View {
        if row.isWaiting {
            Text("Waiting").font(Theme.Typography.numeral).foregroundStyle(Theme.amber)
        } else if row.session.running {
            Ticking(since: row.workingSince) { now in
                Text(row.statusLabel(now: now)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
            }
        } else {
            Ticking(coarse: true) { now in
                Text(row.statusLabel(now: now)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// The question or summary, led by the project's name where the group doesn't say it.
    private var headline: Text {
        let text = Text(row.headline).foregroundStyle(Theme.secondary)
        guard placement.namesProject else { return text }
        let project = Text(row.session.folderName).foregroundStyle(Theme.tertiary)
        return plainHeadline.isEmpty ? project : project + Text("  ") + text
    }

    private var plainHeadline: String { String(row.headline.characters) }

    /// The first thing it left running, in full, and how many more there are; the whole list on hover.
    private func taskLine(_ first: ClaudeTask) -> some View {
        HStack(spacing: 5) {
            Image(systemName: first.kind == .agent ? "asterisk" : "terminal")
                .font(Theme.Typography.glyph(10))
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(first.title).lineLimit(1)
            if row.tasks.count > 1 { Text("+\(row.tasks.count - 1) more").fixedSize() }
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.secondary)
        .help(row.tasks.map(\.title).joined(separator: "\n"))
    }

    @ViewBuilder private var action: some View {
        if keeps {
            IconButton(symbol: "bookmark", help: "Keep", detail: "Keeps it in your list · \(store.shortcut(.keepSession).display)") {
                LookoutHub.animate { store.keepAgent(row.id) }
            }
        } else {
            IconButton(symbol: "eye.slash", help: "Hide", detail: "Comes back on new activity · \(store.shortcut(.removeSession).display)") {
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

/// The list's last row: a neutral "+" tile in the rail, "New session" (a scratch chat), and a menu of the projects to
/// start one in.
struct NewSessionRow: View {
    let store: Store
    let hub: HubState
    let rail: HorizontalEdge
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
        .focusRing(Theme.Radius.row, inset: true)
        .overlay(alignment: .trailing) { projects.padding(.trailing, RailRow<EmptyView, EmptyView>.textEnd(rail) - 6) }
        .onHover { hovering = $0 }
        .padding(rail == .leading ? .trailing : .leading, inset)
        .onChange(of: hub.projectsMenuRequest) { _, _ in presentProjects() }
        .accessibilityLabel("New session")
        .accessibilityHint("Starts a chat with no folder. The menu picks a project.")
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

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// New session's menu of projects: Scratch, then every project by name, the most recent first.
enum ProjectsMenu {
    @MainActor static func make(_ store: Store) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Scratch (no folder)") { store.startScratchSession() })
        menu.addItem(.separator())
        for folder in store.recentFolders {
            let item = ActionItem(URL(fileURLWithPath: folder).lastPathComponent) { store.startAgent(in: folder) }
            item.image = store.projectColor(folder).map(Swatch.image)
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
        let revealed = store.firstHiddenSession
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
        return listedGroups(expanded: hub.sessionsExpanded).groups.flatMap(\.rows)
    }

    /// The first New activity session "+N more" is hiding.
    var firstHiddenSession: String? {
        sessionGroups.first { $0.kind == .newActivity }?.rows.dropFirst(SessionGroup.newActivityCap).first?.id
    }

    /// What the keys can pick after the session rows: "+N more" while New activity is cut, then New session.
    func sessionExtraTargets(_ hub: HubState) -> [String] {
        guard agents.enabled, hub.query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (listedGroups(expanded: hub.sessionsExpanded).hidden > 0 ? ["s:more"] : []) + ["s:new"]
    }
}

extension LookoutHub {
    /// The tile column's side for this edge.
    var railSide: HorizontalEdge { edge == .right ? .trailing : .leading }

    /// "Sessions" and, when something needs you, "1 waiting" (a button: it picks the first one).
    var agentsHeader: some View {
        let waiting = store.agentCounts.blocked
        return SectionHeader(title: "Sessions", status: waiting > 0 ? ("\(waiting) waiting", AnyShapeStyle(Theme.amber)) : nil,
                             statusAction: pickFirstWaiting, focused: hub.focus == .agents,
                             expandHelp: hub.focus == .agents ? "Back to all sections" : "Expand Sessions",
                             onFocus: showsDetail ? {
                                 withAnimation(Self.refocus.resolved(reduce: reduce)) { hub.focus = hub.focus == .agents ? nil : .agents }
                             } : nil) {}
    }

    /// The first row of Waiting for you, picked as the keys would, and scrolled to.
    func pickFirstWaiting() {
        hub.pickFirstWaiting(in: store, ui: ui)
    }

    /// The groups, scrolling once past `cap`, always on a whole row.
    func sessionsScroll(cap: CGFloat) -> some View {
        SessionsScroll(store: store, ui: ui, hub: hub, rail: railSide, cap: cap)
    }

    /// A peek's groups: whole rows up to `cap`, then "+N more" (never a scroll view or a fade).
    func sessionsPeek(cap: CGFloat) -> some View {
        SessionsList(store: store, ui: ui, hub: hub, rail: railSide, inset: 0, peekCap: cap)
    }

    /// New session, under the list (not while searching).
    @ViewBuilder func newSessionRow(inset: CGFloat = Theme.Metrics.inset) -> some View {
        if !searching { NewSessionRow(store: store, hub: hub, rail: railSide, inset: inset) }
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
                entry(prompt: row.label, help: "Two letters; empty goes back to the title's")
            case .emoji:
                HStack(spacing: Theme.Space.sm) {
                    entry(prompt: "🙂", help: "One emoji")
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

    private func entry(prompt: String, help: String) -> some View {
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

    /// Empty goes back to letters from the title, or to the icon that was picked.
    private func save() {
        if text.isEmpty {
            store.setAgentLabel(row.id, row.entry.icon == nil ? nil : row.label)
        } else if let label = AgentLabel.sanitize(text) {
            guard AgentLabel.isEmoji(label) == (mode == .emoji) else { return }
            store.setAgentLabel(row.id, label)
        }
        dismiss()
    }
}

// MARK: - Update, inbox menu, status lines

/// A new release, fetched in the background: an icon that says what it is on hover; click to restart into it
/// (or to download it, with a ring for progress, if that didn't happen on its own). Right-click for the release
/// notes or to skip that version.
struct UpdateButton: View {
    let updater: Updater
    let horizontal: Bool

    var body: some View {
        let version = updater.release?.version ?? ""
        Button { updater.advance() } label: { UpdateLabel(updater: updater, horizontal: horizontal, version: version) }
        .buttonStyle(HoverFillButtonStyle(shape: Capsule(), hover: Theme.Fill.hover))
        .accessibilityLabel(Self.label(updater.phase, version: version))
        .accessibilityHint(tooltip(version).0)
        .tip(tooltip(version).0, tooltip(version).1)
        .contextMenu {
            if let page = updater.release?.page {
                Button("What's new in \(version)") { NSWorkspace.shared.open(page) }
            }
            Button("Skip \(version)") { updater.skip() }
        }
    }

    /// The tooltip: what it is, and what a click does.
    private func tooltip(_ version: String) -> (String, String?) {
        switch updater.phase {
        case .available: ("Lookout \(version) is available", "Click to download it · right-click for more")
        case .downloading(let fraction): ("Downloading Lookout \(version)… \(Int(fraction * 100))%", nil)
        case .ready: ("Lookout \(version) is ready", "Click to restart into it")
        case .installing: ("Installing Lookout \(version)…", nil)
        case .failed(let message): ("Update failed: \(message)", "Click to try again")
        case .idle: ("", nil)
        }
    }

    fileprivate static func label(_ phase: Updater.Phase, version: String) -> String {
        switch phase {
        case .downloading(let fraction): "\(Int(fraction * 100))%"
        case .ready, .installing: "Restart to update"
        case .failed: "Retry update"
        default: "Update to \(version)"
        }
    }
}

/// The update button's face: its icon (a progress ring while downloading), and its name beside it on hover.
private struct UpdateLabel: View {
    let updater: Updater
    let horizontal: Bool
    let version: String
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if case .downloading(let fraction) = updater.phase {
                    Circle().stroke(Theme.Fill.selected, lineWidth: 2).padding(3)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                }
                if updater.phase == .installing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(Theme.Typography.glyph(12, .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            if horizontal && hover {
                Text(UpdateButton.label(updater.phase, version: version))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.text)
                    .padding(.trailing, 8)
            }
        }
        .motion(Theme.Motion.hover, value: hover)
    }

    private var symbol: String {
        switch updater.phase {
        case .ready: "arrow.clockwise"
        case .failed: "exclamationmark"
        default: "arrow.down"
        }
    }

    private var tint: AnyShapeStyle {
        switch updater.phase {
        case .ready: AnyShapeStyle(Theme.green)
        case .failed: AnyShapeStyle(Theme.red)
        case .downloading: AnyShapeStyle(Theme.secondary)
        default: AnyShapeStyle(Theme.accent)
        }
    }
}

/// An inbox item's context menu: open, copy link, read state, done, treat as a bot.
struct InboxItemMenu: View {
    let item: InboxItem
    let store: Store
    /// Items already in the low-priority list offer "Stop treating as a bot" instead.
    let low: Bool

    var body: some View {
        Button("Open on GitHub") { store.open(item) }
        Button("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        Divider()
        if item.state.isOpen {
            Button(item.state == .unread ? "Mark as read" : "Mark as unread") {
                item.state == .unread ? store.markRead(item) : store.markUnread(item)
            }
            Button("Done") { store.discard(item) }
        } else {
            Button("Back to inbox") { store.restore(item) }
        }
        Divider()
        if !low {
            Button("Treat @\(item.author) as a bot") { store.addBot(item.author) }
        } else if store.settings.botHandles.contains(where: { $0.caseInsensitiveCompare(item.author) == .orderedSame }) {
            Button("Stop treating @\(item.author) as a bot") {
                store.settings.botHandles.removeAll { $0.caseInsensitiveCompare(item.author) == .orderedSame }
            }
        }
    }
}

/// The Claude link's state as a dot and a line ("Synced with Claude", "Claude's sessions not found"…).
struct ClaudeLinkStatus: View {
    let store: Store

    var body: some View {
        let (color, text, detail): (AnyShapeStyle, String, String) = switch store.claudeLink {
        case .ok where Claude.isRunning: (AnyShapeStyle(Theme.tertiary), "Synced with Claude", "Updates as the Claude app writes its session files")
        case .ok, .off: (AnyShapeStyle(Theme.tertiary), "Claude isn't running", "Sessions update again when the app is open")
        case .missing: (AnyShapeStyle(Theme.red), "Claude's sessions not found", "Open the Claude desktop app once")
        case .unreadable: (AnyShapeStyle(Theme.red), "Can't read Claude's sessions", "The app's session format changed")
        }
        Circle().fill(color).frame(width: 6, height: 6)
        Text(text).tip(text, detail)
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
