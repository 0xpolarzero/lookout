import SwiftUI

// Hovering a section of the bar opens just that section beside it, in a panel joined to the bar. The bar itself never
// moves, so what you're pointing at stays under the pointer. The whole view (every section at once) is the kept-open one.

enum HubSection: Hashable {
    case inbox, ci, agents, controls

    /// What the section is called in tooltips and for VoiceOver.
    var name: String {
        switch self {
        case .inbox: "Inbox"
        case .ci: "CI"
        case .agents: "Sessions"
        case .controls: "Controls"
        }
    }
}

/// The controls menu's rows, top to bottom (DESIGN.md 5.7): what its view draws and its keys walk.
enum ControlsRow: CaseIterable {
    case keepOpen, repositories, settings, sync

    /// The rows the menu lists: while sign-in is the fault its line opens Settings, so there is nothing to sync.
    @MainActor static func listed(_ store: Store) -> [ControlsRow] { allCases.filter { $0 != .sync || store.authError == nil } }
}

extension HubState {
    /// The controls for the keyboard and VoiceOver: at rest, the peek, first row highlighted, the keys acting on it; kept
    /// open, where the footer holds them, VoiceOver's cursor goes to the footer's first control. Either way it lands there.
    func showControls() {
        moveVoiceOver(to: "h:controls")
        if expanded { return }
        quiet = false
        cancelDwell()
        section = .controls
        menuPick = .keepOpen
        menuKeys = true
    }

    /// The pointer is gone: the panel closes. Not the controls menu the keyboard asked for, which has the keys and stays
    /// up wherever the pointer is until Esc or a row closes it. Returns whether it closed.
    @discardableResult
    func closePeek() -> Bool {
        guard !menuKeys else { return false }
        section = nil
        quiet = false
        return true
    }

    /// Does what a row of the controls menu says.
    func perform(_ row: ControlsRow, store: Store) {
        switch row {
        case .keepOpen: LookoutHub.animate(LookoutHub.opening) { pinned = true }
        case .repositories: go(.repos)
        case .settings: go(.settings)
        case .sync: if !store.isSyncing { store.refreshNow() }
        }
        // A page or the full view takes over; syncing leaves the menu as it is.
        if row != .sync { menuKeys = false }
    }
}

struct PeekMeasure: Equatable {
    let section: HubSection
    let size: CGSize
}

/// Reports a section's place in the bar and makes it the one shown when the pointer enters it.
struct SectionProbe: ViewModifier {
    let section: HubSection
    let hub: HubState
    @Binding var frames: [HubSection: CGRect]

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Only at rest, where the panels are: the full view's changes don't re-run anything.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LookoutHub.barSpace)) } action: { frame in
                if !hub.expanded, frames[section] != frame { frames[section] = frame }
            }
            .onHover { if $0 { hub.enter(section) } else { hub.cancelDwell() } }
    }
}

/// A panel as drawn: where it is (in the bar's coordinates, outside the bar), and its corners.
struct PanelGeometry: Equatable {
    var rect: CGRect
    var radii: RectangleCornerRadii
}

extension LookoutHub {
    static let barSpace = "hub-bar"
    /// Between the bar and a section's panel: none, so the pointer never falls between them.
    static let peekGap: CGFloat = 0

    func probe(_ section: HubSection) -> SectionProbe {
        SectionProbe(section: section, hub: hub, frames: $sectionFrames)
    }

    /// The hovered section, when the whole view isn't open (nor a page).
    var peeking: HubSection? { hub.expanded || hub.quiet ? nil : hub.section }

    /// Where a panel sits along the bar: from `start`, `length` long (both along the bar's edge), and which of the
    /// bar's ends it reaches.
    struct Placement: Equatable {
        var start: CGFloat
        var length: CGFloat
        /// Flush with the bar's start (top, or left), or reaching its end (bottom, or right): the bar's corner there
        /// goes square, so the two make one clean edge.
        var atStart: Bool
        var atEnd: Bool
        /// Runs on past the bar's end: its own corner there stays round.
        var pastEnd: Bool
    }

    /// Closer than this to an end of the bar, a panel snaps flush with it.
    static let peekSnap: CGFloat = 60

    /// Beside the bar, a panel's header lines up with its section's first cell (the inbox's starts at the bar's
    /// top, the controls' ends at its bottom); along the top and bottom it starts under its segment (ends under it,
    /// for the controls). Then it's kept within the bar, and snapped flush with an end it comes close to.
    func placement(_ section: HubSection, _ frame: CGRect) -> Placement? {
        let bar = edge.isHorizontal ? barSize.width : barSize.height
        // This section's own measured size: until it's known (or while another's is all there is), nothing to place.
        let natural = edge.isHorizontal ? panelWidth(section) : peekSizes[section]?.height ?? 0
        guard bar > 0, natural > 0, peekSizes[section] != nil else { return nil }
        var start: CGFloat
        var length = natural
        if edge.isHorizontal {
            start = section == .controls ? frame.maxX - length : frame.minX
            start = min(max(start, 0), max(bar - length, 0))
            if start < Self.peekSnap { start = 0 }
            if length <= bar, bar - (start + length) < Self.peekSnap { start = bar - length }
        } else {
            // Its header stays level with its first cell, so it only moves at the ends: it grows to meet the bar's
            // bottom if it ends close to it.
            start = section == .inbox ? 0 : section == .controls ? bar - length : max(frame.minY - HubGeometry.lead, 0)
            // A low cell leaves less room below it than a row and its "+N more" need with the header: the panel moves up
            // by what would hang past the screen's end.
            start = HubGeometry.peekStart(start, length: length, reach: maxLength + HubGeometry.inset - hubTop)
            let short = bar - (start + length)
            if short >= 0, short < Self.peekSnap { length = bar - start }
        }
        let end = start + length
        return Placement(start: start, length: length, atStart: start <= 0.5, atEnd: end >= bar - 0.5, pastEnd: end > bar + 0.5)
    }

    /// The current panel's place, for the bar's own outline.
    var currentPlacement: Placement? {
        guard let section = peeking, let frame = sectionFrames[section] else { return nil }
        return placement(section, frame)
    }

    /// The hovered section's panel as drawn, once it is measured and placed.
    var peekGeometry: PanelGeometry? {
        guard let section = peeking, let size = peekSizes[section], let place = currentPlacement else { return nil }
        let w = panelWidth(section)
        let h = edge.isHorizontal ? size.height : place.length
        let rect = switch edge {
        case .right: CGRect(x: -(w + Self.peekGap), y: place.start, width: w, height: h)
        case .left: CGRect(x: barSize.width + Self.peekGap, y: place.start, width: w, height: h)
        case .top: CGRect(x: place.start, y: barSize.height + Self.peekGap, width: w, height: h)
        case .bottom: CGRect(x: place.start, y: -(h + Self.peekGap), width: w, height: h)
        }
        return PanelGeometry(rect: rect, radii: panelRadii(place))
    }

    /// The bar's corners: square where a panel is flush with (or runs past) that end of the bar.
    func barRadii(_ place: Placement?) -> RectangleCornerRadii {
        let r = Theme.Radius.hub
        let start: CGFloat = place?.atStart == true ? 0 : r
        let end: CGFloat = place?.atEnd == true ? 0 : r
        return switch edge {
        case .right: RectangleCornerRadii(topLeading: start, bottomLeading: end)
        case .left: RectangleCornerRadii(bottomTrailing: end, topTrailing: start)
        case .top: RectangleCornerRadii(bottomLeading: start, bottomTrailing: end)
        case .bottom: RectangleCornerRadii(topLeading: start, topTrailing: end)
        }
    }

    /// A panel's corners: square where it meets the bar, rounded elsewhere, and rounded on the bar's side too where it
    /// runs on past the bar's end.
    func panelRadii(_ place: Placement) -> RectangleCornerRadii {
        let r = Theme.Radius.hub
        let past: CGFloat = place.pastEnd ? r : 0
        return switch edge {
        case .right: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: past)
        case .left: RectangleCornerRadii(bottomLeading: past, bottomTrailing: r, topTrailing: r)
        case .top: RectangleCornerRadii(bottomLeading: r, bottomTrailing: r, topTrailing: past)
        case .bottom: RectangleCornerRadii(topLeading: r, bottomTrailing: past, topTrailing: r)
        }
    }

    /// The bar's outline as a clip for what is drawn inside it.
    var barOutline: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: barRadii(currentPlacement), style: .continuous)
    }

    /// The panel for the hovered section, measured and placed beside (or under) its cells in the bar.
    @ViewBuilder var peekPanel: some View {
        if let section = peeking, sectionFrames[section] != nil {
            let geometry = peekGeometry
            let rect = geometry?.rect ?? .zero
            peekContent(section)
                // The section is part of what's observed: an equal size on switching must still fill that section's entry.
                .onGeometryChange(for: PeekMeasure.self) { PeekMeasure(section: section, size: $0.size) } action: {
                    if peekSizes[$0.section] != $0.size { peekSizes[$0.section] = $0.size }
                }
                .frame(height: edge.isHorizontal ? nil : currentPlacement?.length, alignment: .top)
                .fixedSize()
                .clipShape(UnevenRoundedRectangle(cornerRadii: geometry?.radii ?? RectangleCornerRadii(), style: .continuous))
                .onHover { overPanel = $0; hoverChanged() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rootSpace)) } action: { hub.panelFrame = $0 }
                .onDisappear { hub.panelFrame = .zero }
                // Hidden until it's been measured and placed, so it never shows up in the wrong spot first.
                .opacity(geometry == nil ? 0 : 1)
                .transition(peekTransition)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// Only the first open and the last close fade and slide; switching sections is instant (no Reduce Motion: no slide).
    var peekTransition: AnyTransition {
        let d: CGFloat = reduce ? 0 : Theme.Space.sm
        return .opacity.combined(with: .offset(x: edge == .right ? d : edge == .left ? -d : 0,
                                               y: edge == .top ? -d : edge == .bottom ? d : 0))
    }

    // MARK: Content

    /// Between rows and the panel's edge: the one outer inset, and along the bar the same lead as its first cell, so a
    /// header sits level with the cell it belongs to.
    static let peekPad: CGFloat = Theme.Metrics.inset

    /// A panel's width (DESIGN.md 3.4), on every edge.
    func panelWidth(_ section: HubSection) -> CGFloat {
        switch section {
        case .controls: 240
        case .ci: 360
        default: 400
        }
    }

    /// What the screen leaves a panel below (or above) the bar's end it hangs from: from where its header starts, which
    /// is level with its section's first cell.
    func peekRoom(_ section: HubSection) -> CGFloat {
        guard !edge.isHorizontal else { return maxLength - Self.cell }
        let start = section == .inbox ? 0 : max((sectionFrames[section]?.minY ?? 0) - HubGeometry.lead, 0)
        return maxLength + HubGeometry.inset - hubTop - start
    }

    /// What a peek's rows may take (their "+N more" included): the room left by its padding and `fixed`, its header and
    /// whatever else is always there. Never less than a whole row and the "+N more" under it: with less room than that
    /// below its first cell, the panel moves up (`placement`) rather than the rows being cut through.
    func peekCap(_ section: HubSection, fixed: CGFloat, least: CGFloat = Theme.Metrics.twoLineRow + Theme.Metrics.pitch) -> CGFloat {
        max(peekRoom(section) - 2 * HubGeometry.lead - fixed, least)
    }

    @ViewBuilder func peekContent(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            case .inbox: peekInbox
            case .ci: peekCI
            case .agents: peekAgents
            case .controls: peekControls
            }
        }
        .padding(.horizontal, Self.peekPad)
        .padding(.vertical, HubGeometry.lead)
        .frame(width: panelWidth(section), alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.name)
    }

    /// The inbox as the full view has it: its header, then its banner, rows (as many whole ones as fit, with "+N more") and
    /// undo line.
    @ViewBuilder var peekInbox: some View {
        inboxHeader.frame(height: Theme.Metrics.pitch)
        inboxBody(cap: peekCap(.inbox, fixed: Theme.Metrics.pitch), peek: true)
    }

    /// CI: its header, then its rows, as many whole ones as fit and "+N more" under them, like the inbox and the sessions.
    @ViewBuilder var peekCI: some View {
        ciHeader.frame(height: Theme.Metrics.pitch)
        ciRows(cap: peekCap(.ci, fixed: Theme.Metrics.pitch), peek: true)
    }

    /// The sessions' header and notice over their rows, which have no tile column: the bar's tiles are beside them.
    @ViewBuilder var sessionsPeekHeader: some View {
        agentsHeader.frame(height: Theme.Metrics.pitch)
        ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding)
    }

    /// The sessions as the full view lists them, without their tiles: as many whole rows as fit, then New session.
    @ViewBuilder var peekAgents: some View {
        // Its header and the New session row are always there, and the notice when Claude's files are not.
        // A group's header, a whole row and the "+N more" under them are the least it can show.
        let cap = peekCap(.agents, fixed: 2 * Theme.Metrics.pitch + ClaudeNotice.room(store),
                          least: SessionGroup.headerHeight + Theme.Metrics.twoLineRow + Theme.Metrics.pitch)
        sessionsPeekHeader
        if noSessionsMatch { noSessionsLine }
        sessionsPeek(cap: cap)
        newSessionRow(inset: 0, tile: false)
    }

    // MARK: Controls

    /// The Tab ring landed on a row of the controls menu that has the keys: the highlight is where the ring is.
    func follow(_ row: ControlsRow) {
        if hub.menuKeys { hub.menuPick = row }
    }

    /// The controls (DESIGN.md 5.7): what the footer holds, as menu rows, then how syncing is going.
    @ViewBuilder var peekControls: some View {
        let picked = hub.menuKeys ? hub.menuPick : nil
        MenuRow(symbol: "pin", title: "Keep open", key: store.shortcut(.togglePanel).display, picked: picked == .keepOpen,
                onFocus: { follow(.keepOpen) }) {
            hub.perform(.keepOpen, store: store)
        }
        .voiceOverTarget("h:controls", hub: hub)
        MenuRow(symbol: "books.vertical", title: "Repositories…", key: nil, picked: picked == .repositories,
                onFocus: { follow(.repositories) }) {
            hub.perform(.repositories, store: store)
        }
        MenuRow(symbol: "gearshape", title: "Settings…", key: "⌘,", picked: picked == .settings,
                onFocus: { follow(.settings) }) { hub.perform(.settings, store: store) }
        Hairline().padding(.vertical, Theme.Space.xs)
        ControlsSyncRow(store: store, picked: picked == .sync, onFocus: { follow(.sync) })
    }

    /// The pointer left the bar and its panel: close the panel (a moment later, so going from one to the other,
    /// side by side, doesn't count).
    func hoverChanged() {
        peekLeave?.cancel()
        guard !overBar, !overPanel else { return }
        let hub = hub
        hub.cancelDwell()
        peekLeave = Task { @MainActor in
            try? await Task.sleep(for: Theme.Timing.leaveGrace)
            if !Task.isCancelled { hub.closePeek() }
        }
    }
}

/// A peek never scrolls (DESIGN.md 10.3): it lists the whole rows that fit its cap and, under them, one "+N more" line,
/// as tall as a one-line row, that keeps the hub open on the section. Rows are as tall as their layout says they are, so
/// what a cap holds is arithmetic, not measurement.
enum PeekCut {
    /// How many of the rows of `heights`, laid out `spacing` apart, a peek of `cap` points lists: all of them when they
    /// fit, else as many as leave room for the "+N more" line, and never fewer than one.
    static func shown(_ heights: [CGFloat], spacing: CGFloat = 0, cap: CGFloat) -> Int {
        func length(_ n: Int) -> CGFloat { heights.prefix(n).reduce(0, +) + CGFloat(max(n - 1, 0)) * spacing }
        guard length(heights.count) > cap + 0.5 else { return heights.count }
        let fits = heights.indices.filter { length($0 + 1) + Theme.Metrics.pitch <= cap + 0.5 }.count
        return max(fits, 1)
    }

    /// `shown` for `count` rows of one height.
    static func shown(count: Int, height: CGFloat, spacing: CGFloat = 0, cap: CGFloat) -> Int {
        guard CGFloat(count) * (height + spacing) - spacing > cap + 0.5 else { return count }
        return min(count, max(Int(((cap - Theme.Metrics.pitch + spacing + 0.5) / (height + spacing)).rounded(.down)), 1))
    }
}

extension HubState {
    /// A peek's "+N more": keeps the hub open on that section, which then has all the room.
    func showAll(_ section: HubSection) {
        LookoutHub.animate(LookoutHub.refocus) { pinned = true; focus = section }
    }
}

/// The controls peek's last row: how syncing is going, and Sync now. Its own view, so a poll redraws only this.
struct ControlsSyncRow: View {
    let store: Store
    let picked: Bool
    var onFocus: () -> Void = {}
    @FocusState private var syncFocused: Bool

    var body: some View {
        SyncStatus(store: store) { line in
            HStack(spacing: Theme.Space.md) {
                Text(line.text).font(Theme.Typography.meta).foregroundStyle(line.color).lineLimit(1)
                Spacer(minLength: 0)
                if !line.opensSettings {
                    Button { store.refreshNow() } label: {
                        HStack(spacing: Theme.Space.sm) {
                            Text("Sync now").font(Theme.Typography.meta).foregroundStyle(Theme.secondary)
                            Text(store.shortcut(.refresh).display).font(Theme.Typography.keyhint).foregroundStyle(Theme.secondary)
                        }
                        .frame(minHeight: Theme.Metrics.iconButton)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($syncFocused)
                    .focusRing(Theme.Radius.small, isFocused: syncFocused)
                    .reportsControlFocus(syncFocused)
                    .onChange(of: syncFocused) { _, now in if now { onFocus() } }
                    .disabled(store.isSyncing)
                    .accessibilityLabel("Sync now")
                }
            }
            .padding(.horizontal, Theme.Metrics.rowPadding)
            .frame(height: Theme.Metrics.menuRow)
            // Picked by the keys: the whole line is the row, as the other rows are.
            .background(Theme.Radius.shape(Theme.Radius.field).fill(picked ? Theme.Fill.selected : Theme.Fill.rest))
            .focusRing(Theme.Radius.field, isFocused: picked)
            .help(line.help)
        }
    }
}
