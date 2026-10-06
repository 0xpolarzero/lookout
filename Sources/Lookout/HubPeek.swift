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
    /// Opens the controls peek for the keyboard and VoiceOver: first row highlighted, the keys acting on it.
    func showControls() {
        quiet = false
        cancelDwell()
        section = .controls
        menuPick = .keepOpen
        menuKeys = true
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

    /// What the screen leaves a panel below (or above) the bar's end it hangs from.
    func peekRoom(_ section: HubSection) -> CGFloat {
        guard !edge.isHorizontal else { return maxLength - Self.cell }
        let start = section == .inbox ? 0 : max((sectionFrames[section]?.minY ?? 0) - HubGeometry.lead, 0)
        return max(maxLength + HubGeometry.inset - hubTop - start, 160)
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

    /// The inbox, rows as the full view has them, as many whole ones as fit.
    @ViewBuilder var peekInbox: some View {
        let cap = max(peekRoom(.inbox) - 2 * HubGeometry.lead - Theme.Metrics.pitch, 88)
        inboxHeader.frame(height: Theme.Metrics.pitch)
        if items.isEmpty {
            emptyInbox
        } else {
            WholeRows(total: items.count, cap: cap, noun: "item", onMore: keepOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items.prefix(WholeRows<EmptyView>.instantiated(cap))) { itemRow($0).id("i:" + $0.id) }
                }
                .motion(Theme.Motion.fade, value: listKey)
            }
        }
    }

    /// CI: its header, then its rows, as many whole ones as fit and "+N more" under them, like the inbox and the sessions.
    @ViewBuilder var peekCI: some View {
        if store.ciRepos.isEmpty {
            linkRow("No CI configured", action: "Choose repositories") { hub.go(.repos) }.frame(height: Theme.Metrics.pitch)
        } else {
            let cap = max(peekRoom(.ci) - 2 * HubGeometry.lead - Theme.Metrics.pitch, 88)
            ciHeader.frame(height: Theme.Metrics.pitch)
            let rows = ciPeekRows
            WholeRows(total: rows.count, cap: cap, noun: rows.noun, onMore: keepOpen) {
                rows.content(WholeRows<EmptyView>.instantiated(cap))
            }
        }
    }

    /// CI's rows as the peek lays them out: how many there are, what one is called, and (given how many may be
    /// instantiated) a view of them whose rows each mark their bottom edge, so the cap cuts between rows. The CI
    /// section is the only one that knows its rows: restyling them never touches the peek.
    var ciPeekRows: (count: Int, noun: String, content: (Int) -> AnyView) {
        let states = Self.ciLineOrder.filter { $0 != CIState.none || !ciRepos(listedIn: .none).isEmpty }
        return (states.count, "state", { limit in
            AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(states.prefix(limit)), id: \.self) { ciLine($0, compact: true).capEdge() }
            }
            .padding(.vertical, 6))
        })
    }

    /// The sessions as the full view lists them, as many whole rows as fit, then New session.
    @ViewBuilder var peekAgents: some View {
        let rows = agentRows
        let all = rows.kept + rows.pending
        let cap = max(peekRoom(.agents) - 2 * HubGeometry.lead - 2 * Theme.Metrics.pitch, 88)
        let starts = projectStarts(rows.kept)
        agentsHeader.frame(height: Theme.Metrics.pitch)
        ClaudeNotice(store: store).padding(.horizontal, Theme.Metrics.rowPadding)
        WholeRows(total: all.count, cap: cap, noun: "session", onMore: keepOpen) {
            VStack(alignment: .leading, spacing: 0) {
                let shown = WholeRows<EmptyView>.instantiated(cap)
                ForEach(rows.kept.prefix(shown)) { r in
                    if starts.contains(r.id) { groupDivider }
                    twoLineRow(r).modifier(AgentReorder(row: r, store: store))
                }
                if !rows.pending.isEmpty, rows.kept.count < shown {
                    if !rows.kept.isEmpty { groupDivider }
                    pendingLabel(twoLines: true).padding(.bottom, Theme.Space.xs)
                    ForEach(rows.pending.prefix(shown - rows.kept.count)) { twoLineRow($0) }
                }
            }
        }
        NewSessionRow(store: store, style: .twoLines).frame(height: Theme.Metrics.pitch)
    }

    /// "+N more" opens the full view, where every row is.
    func keepOpen() {
        withAnimation(Self.opening.resolved(reduce: reduce)) { hub.pinned = true }
    }

    // MARK: Controls

    /// The bar's last cell at rest: a gear. Hovering shows the controls; a click goes to Settings (or closes it).
    var controlsCell: some View {
        ControlsGear(active: hub.page != .main) { hub.page == .settings ? hub.back() : hub.go(.settings) }
            .accessibilityLabel(hub.page == .settings ? "Close Settings" : "Settings")
            .accessibilityAction(named: "Show controls") { hub.showControls() }
            .accessibilityAction(named: "Keep open") { keepOpen() }
            .accessibilityAction(named: "Repositories") { hub.go(.repos) }
            .accessibilityAction(named: "Check now") { store.refreshNow() }
    }

    /// The controls (DESIGN.md 5.7): what the footer holds, as menu rows, then how syncing is going.
    @ViewBuilder var peekControls: some View {
        let picked = hub.menuKeys ? hub.menuPick : nil
        MenuRow(symbol: "pin", title: "Keep open", key: store.shortcut(.togglePanel).display, picked: picked == .keepOpen) {
            hub.perform(.keepOpen, store: store)
        }
        MenuRow(symbol: "books.vertical", title: "Repositories…", key: nil, picked: picked == .repositories) {
            hub.perform(.repositories, store: store)
        }
        MenuRow(symbol: "gearshape", title: "Settings…", key: "⌘,", picked: picked == .settings) { hub.perform(.settings, store: store) }
        Hairline().padding(.vertical, Theme.Space.xs)
        Ticking(coarse: true) { now in
            let line = syncLine(now: now)
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
                    .focusRing(Theme.Radius.small)
                    .disabled(store.isSyncing)
                    .accessibilityLabel("Sync now")
                }
            }
            .padding(.horizontal, Theme.Metrics.rowPadding)
            .frame(height: Theme.Metrics.menuRow)
            // Picked by the keys: the whole line is the row, as the other rows are.
            .background(Theme.Radius.shape(Theme.Radius.field).fill(picked == .sync ? Theme.Fill.selected : Theme.Fill.rest))
            .focusRing(Theme.Radius.field, isFocused: picked == .sync)
            .help(line.help)
        }
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
            if !Task.isCancelled {
                hub.section = nil
                hub.quiet = false
            }
        }
    }
}

/// A list cut to the rows that fit whole, with "+N more" under it (never a fade, never a scroll). The rows mark
/// themselves with `.capEdge()`; pass no more than `instantiated(cap)` of them: that many always cover the room.
struct WholeRows<Content: View>: View {
    /// How many rows the data has.
    let total: Int
    let cap: CGFloat
    let noun: String
    let onMore: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var edges: [CGFloat] = []

    /// A row is never shorter than a one-line row.
    static func instantiated(_ cap: CGFloat) -> Int { Int(cap / Theme.Metrics.pitch) + 2 }

    var body: some View {
        // Nothing is cut before the rows are measured.
        let measured = !edges.isEmpty
        let fits = measured && edges.count >= total && (edges.last ?? 0) <= cap + 0.5
        let limit = fits ? nil : edges.filter { $0 <= cap - Theme.Metrics.pitch + 0.5 }.max() ?? (measured ? 0 : cap)
        let hidden = measured && !fits ? total - edges.filter { $0 <= (limit ?? cap) + 0.5 }.count : 0
        VStack(alignment: .leading, spacing: 0) {
            content()
                .coordinateSpace(.named(CappedScrollSpace.name))
                .frame(height: limit, alignment: .top)
                .clipped()
            if hidden > 0 {
                Button(action: onMore) {
                    Text("+\(hidden) more").font(Theme.Typography.control).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, Theme.Metrics.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.pitch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(Theme.Radius.row)
                .accessibilityLabel("\(plural(hidden, "more " + noun))")
                .accessibilityHint("Keeps Lookout open to show them")
            }
        }
        .onPreferenceChange(CapEdges.self) { new in
            let sorted = Array(Set(new.map { ($0 * 2).rounded() / 2 })).sorted()
            if sorted != edges { edges = sorted }
        }
    }
}

/// The gear at the end of the bar, without a tooltip: hovering it opens the controls.
struct ControlsGear: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { ControlsGearLabel(active: active) }
            .buttonStyle(HoverFillButtonStyle(shape: Circle(), hover: Theme.Fill.hover, active: Theme.Fill.selected, isActive: active))
            .accessibilityLabel("Controls")
            .accessibilityHint("Settings, repositories and keeping the hub open")
    }
}

private struct ControlsGearLabel: View {
    let active: Bool
    @Environment(\.hoverFillHovering) private var hover

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(Theme.Typography.glyph(13))
            .foregroundStyle(hover || active ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.tertiary))
            .frame(width: Theme.Metrics.iconHit, height: Theme.Metrics.iconHit)
    }
}
