import SwiftUI

// Hovering a section of the bar opens just that section beside it, in a panel lined up with its cells. The bar
// itself never moves, so what you're pointing at stays under the pointer. The whole view (every section at once)
// is the pinned one.

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

extension LookoutHub {
    static let barSpace = "hub-bar"
    /// Between the bar and a section's panel: none, so the pointer never falls between them.
    static let peekGap: CGFloat = 0

    func probe(_ section: HubSection) -> SectionProbe {
        SectionProbe(section: section, hub: hub, frames: $sectionFrames)
    }

    /// The hovered section, when the whole view isn't open.
    var peeking: HubSection? { expanded || hub.quiet ? nil : hub.section }

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
            // Its lines stay level with their cells, so it only moves at the ends: it grows to meet the bar's
            // bottom if it ends close to it.
            start = section == .inbox ? 0 : section == .controls ? bar - length : max(frame.minY - Self.peekPad, 0)
            let short = bar - (start + length)
            if short >= 0, short < Self.peekSnap { length = bar - start }
        }
        let end = start + length
        return Placement(start: start, length: length, atStart: start <= 0.5, atEnd: end >= bar - 0.5, pastEnd: end > bar + 0.5)
    }

    /// The panel for the hovered section, placed beside (or under) its cells in the bar.
    @ViewBuilder var peekPanel: some View {
        if let section = peeking, let frame = sectionFrames[section] {
            let place = placement(section, frame)
            let shape = panelShape(place)
            let panel = peekContent(section)
                // The section is part of what's observed: an equal size on switching must still fill that section's entry.
                .onGeometryChange(for: PeekMeasure.self) { PeekMeasure(section: section, size: $0.size) } action: {
                    if peekSizes[$0.section] != $0.size { peekSizes[$0.section] = $0.size }
                }
                .frame(height: edge.isHorizontal ? nil : place?.length, alignment: .top)
                .background(shape.fill(Theme.bg))
                .overlay(shape.strokeBorder(Theme.stroke))
                .clipShape(shape)
                // No seam where it meets the bar: the two outlines there are painted over, so bar and panel read
                // as one shape.
                .overlay(alignment: seamAlignment) { seam(place) }
                .fixedSize()
                .onHover { overPanel = $0; hoverChanged() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.rootSpace)) } action: { hub.panelFrame = $0 }
                .onDisappear { hub.panelFrame = .zero }
                // Hidden until it's been measured and placed, so it never shows up in the wrong spot first.
                .opacity(place == nil ? 0 : 1)
                .transition(peekTransition)
            let o = peekOffset(section, place)
            panel.offset(x: o.width, y: o.height)
        }
    }

    /// Only the first open and the last close fade and slide; switching sections is instant (no Reduce Motion: no slide).
    var peekTransition: AnyTransition {
        let d: CGFloat = reduce ? 0 : Theme.Space.sm
        return .opacity.combined(with: .offset(x: edge == .right ? d : edge == .left ? -d : 0,
                                               y: edge == .top ? -d : edge == .bottom ? d : 0))
    }

    /// Laid over the bar from its top-left (bottom-left on the bottom edge), then moved out beside it.
    func peekOffset(_ section: HubSection, _ place: Placement?) -> CGSize {
        let along = place?.start ?? 0
        return switch edge {
        case .right: CGSize(width: -(panelWidth(section) + Self.peekGap), height: along)
        case .left: CGSize(width: Self.cell + Self.peekGap, height: along)
        case .top: CGSize(width: along, height: Self.cell + Self.peekGap)
        case .bottom: CGSize(width: along, height: -(Self.cell + Self.peekGap))
        }
    }

    /// The open panel's outline with its shadow, in the layer behind the bar and panel.
    @ViewBuilder var peekShadow: some View {
        if let section = peeking, let frame = sectionFrames[section], let place = placement(section, frame),
           let size = peekSizes[section] {
            let o = peekOffset(section, place)
            Color.clear
                .frame(width: panelWidth(section), height: edge.isHorizontal ? size.height : place.length)
                .background { panelShape(place).fill(Theme.bg).shadow(color: .black.opacity(0.42), radius: 20, y: 7) }
                .offset(x: o.width, y: o.height)
                .transition(peekTransition)
        }
    }

    /// Where the panel hangs from: the bar's top-left, or its bottom-left on the bottom edge.
    var peekAlignment: Alignment { edge == .bottom ? .bottomLeading : .topLeading }

    /// The current panel's place, for the bar's own outline.
    var currentPlacement: Placement? {
        guard let section = peeking, let frame = sectionFrames[section] else { return nil }
        return placement(section, frame)
    }

    var seamAlignment: Alignment {
        switch edge {
        case .right: .topTrailing
        case .left: .topLeading
        case .top: .topLeading
        case .bottom: .bottomLeading
        }
    }

    /// Paint over both outlines along what the panel shares with the bar (1pt into each), short of its ends so
    /// the panel's own outline still meets the bar there; not past the bar's end, where the panel's edge is its own.
    func seam(_ place: Placement?) -> some View {
        let bar = edge.isHorizontal ? barSize.width : barSize.height
        let shared = place.map { max(0, min($0.start + $0.length, bar) - $0.start - 2) } ?? 0
        return Rectangle().fill(Theme.bg)
            .frame(width: edge.isHorizontal ? shared : 2, height: edge.isHorizontal ? 2 : shared)
            .offset(x: edge == .right ? 1 : edge == .left ? -1 : 1, y: edge == .top ? -1 : edge == .bottom ? 1 : 1)
    }

    /// The bar's outline: a corner goes square where a panel is flush with (or runs past) that end of the bar.
    var barOutline: UnevenRoundedRectangle {
        let r = Theme.Radius.hub
        let place = currentPlacement
        let start: CGFloat = place?.atStart == true ? 0 : r
        let end: CGFloat = place?.atEnd == true ? 0 : r
        return switch edge {
        case .right: UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: end, style: .continuous)
        case .left: UnevenRoundedRectangle(bottomTrailingRadius: end, topTrailingRadius: start, style: .continuous)
        case .top: UnevenRoundedRectangle(bottomLeadingRadius: start, bottomTrailingRadius: end, style: .continuous)
        case .bottom: UnevenRoundedRectangle(topLeadingRadius: start, topTrailingRadius: end, style: .continuous)
        }
    }

    /// A panel against the bar: square where it meets the bar, rounded elsewhere, and rounded on the bar's side too
    /// where it runs on past the bar's end.
    func panelShape(_ place: Placement?) -> UnevenRoundedRectangle {
        let r = Theme.Radius.hub
        let past: CGFloat = place?.pastEnd == true ? r : 0
        return switch edge {
        case .right: UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: past, style: .continuous)
        case .left: UnevenRoundedRectangle(bottomLeadingRadius: past, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .top: UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: past, style: .continuous)
        case .bottom: UnevenRoundedRectangle(topLeadingRadius: r, bottomTrailingRadius: past, topTrailingRadius: r, style: .continuous)
        }
    }

    /// A panel's padding, all round; rows pad their own 8 inside it, so text starts 16pt from the panel's edge.
    static let peekPad: CGFloat = Theme.Space.md
    /// A section header's height, the same as a CI or agents cell in the bar, so the lines under it line up.
    static let peekLine: CGFloat = Theme.Metrics.line

    /// A panel's width: the controls' is a small menu; along the top and bottom, CI's is its column's.
    func panelWidth(_ section: HubSection) -> CGFloat {
        switch section {
        case .controls: 250
        case .ci: edge.isHorizontal ? Self.ciWidth : Self.detail
        default: Self.detail
        }
    }

    @ViewBuilder func peekContent(_ section: HubSection) -> some View {
        Group {
            if section == .controls { peekControls }
            else if edge.isHorizontal { peekColumn(section) } else { peekRows(section) }
        }
        .padding(Self.peekPad)
        .frame(width: panelWidth(section))
    }

    /// Beside the bar: the header level with the section's first cell, then one line per cell, as tall as the
    /// cell (CI's states, the sessions); then whatever only the panel has (the inbox list, a new session).
    @ViewBuilder func peekRows(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch section {
            case .inbox:
                inboxHeader.frame(height: Self.peekLine)
                peekInbox.padding(.top, 4)
            case .ci:
                peekCI
            case .agents:
                let rows = agentRows
                agentsHeader.frame(height: Self.peekLine)
                ClaudeNotice(store: store).padding(.horizontal, 8)
                // By project and draggable, like the full view's.
                let starts = projectStarts(rows.kept)
                ForEach(rows.kept) { r in
                    DrawerRow(row: r, store: store, ui: ui, number: 0, inHub: true).frame(height: Theme.Metrics.pitch)
                        .sessionMenu(r, store)
                        .modifier(GroupRule(on: starts.contains(r.id)))
                        .modifier(AgentReorder(row: r, store: store))
                }
                if !rows.pending.isEmpty {
                    pendingLabel(twoLines: false).frame(height: 14)
                    ForEach(rows.pending) { r in
                        DrawerRow(row: r, store: store, ui: ui, number: 0, inHub: true).frame(height: Theme.Metrics.pitch)
                            .sessionMenu(r, store)
                    }
                }
                NewSessionRow(store: store, style: .detail).frame(height: Theme.Metrics.pitch)
            default:
                // (The controls have their own panel.)
                EmptyView()
            }
        }
        .frame(width: Self.detail - 2 * Self.peekPad, alignment: .leading)
    }

    /// Under (or over) a strip segment: that section's header, then its content.
    @ViewBuilder func peekColumn(_ section: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch section {
            case .inbox:
                inboxHeader.frame(height: Self.peekLine)
                peekInbox
            case .ci:
                peekCI
            case .agents:
                agentsHeader.frame(height: Self.peekLine)
                ClaudeNotice(store: store).padding(.horizontal, 8)
                let rows = agentRows
                CappedScroll(cap: maxLength - Self.cell - 120, hub: hub) {
                    VStack(alignment: .leading, spacing: 2) {
                        let starts = projectStarts(rows.kept)
                        ForEach(rows.kept) { r in
                            if starts.contains(r.id) { groupDivider }
                            twoLineRow(r).modifier(AgentReorder(row: r, store: store))
                        }
                        if !rows.pending.isEmpty {
                            pendingLabel(twoLines: true).padding(.top, 6).padding(.bottom, 2)
                            ForEach(rows.pending) { twoLineRow($0) }
                        }
                    }
                }
                NewSessionRow(store: store, style: .twoLines)
            default:
                EmptyView()
            }
        }
        .frame(width: (section == .ci ? Self.ciWidth : Self.detail) - 2 * Self.peekPad, alignment: .leading)
    }

    /// The bar's last cell at rest: a gear. Hovering shows the controls; a click goes to Settings.
    var controlsCell: some View {
        ControlsGear(active: hub.page != .main) { hub.go(.settings) }
    }

    /// The controls: how syncing is going, then keep open, repositories and settings, each with its key.
    var peekControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            syncStatus.padding(.horizontal, 8).frame(height: Self.peekLine, alignment: .leading)
            MenuRow(symbol: "pin", title: "Keep open", key: store.shortcut(.togglePanel).display) { hub.pinned = true }
            MenuRow(symbol: "square.stack.3d.up", title: "Repositories", key: nil) { hub.go(.repos) }
            MenuRow(symbol: "gearshape", title: "Settings", key: "⌘,") { hub.go(.settings) }
        }
    }

    /// The inbox list in a panel: scrolls once it's long.
    @ViewBuilder var peekInbox: some View {
        if items.isEmpty {
            emptyInbox
        } else {
            CappedScroll(cap: 330, hub: hub, lazy: AdaptiveStack<EmptyView>.isLazy(items.count)) {
                AdaptiveStack(count: items.count, spacing: 1) { ForEach(items) { itemRow($0).id("i:" + $0.id) } }
                    .motion(Theme.Motion.fade, value: listKey)
            }
        }
    }

    /// CI in a panel: its header, then a line per state, each as tall as its count in the bar.
    @ViewBuilder var peekCI: some View {
        if store.ciRepos.isEmpty {
            linkRow("No CI configured", action: "Choose repositories") { hub.go(.repos) }.frame(height: Self.peekLine)
        } else {
            ciHeader.frame(height: Self.peekLine)
            ForEach(Self.ciLineOrder, id: \.self) { state in
                // Repos without a run only get their line when there are some.
                if state != CIState.none || !ciRepos(listedIn: .none).isEmpty { ciLine(state).frame(minHeight: Self.peekLine) }
            }
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
            .foregroundStyle(hover || active ? Theme.text : Theme.tertiary)
            .frame(width: Theme.Metrics.iconHit, height: Theme.Metrics.iconHit)
    }
}
