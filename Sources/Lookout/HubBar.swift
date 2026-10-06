import AppKit
import SwiftUI

// The bar's own pieces: at rest, and beside a page, the same cells in the same order on every edge (`restBar`). Kept
// open, HubOpen.swift puts them beside the content they stand for.

extension LookoutHub {
    /// The bar column on the sides, and the strip along the top and bottom: the cells at rest (with a page beside it
    /// too: the cells are the same and never dimmed, the gear lit). Kept open, `openHub` draws them with their sections.
    var barColumn: some View { restBar }
    var strip: some View { restBar }

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
}

// MARK: - At rest

extension LookoutHub {
    /// The bar's own axis: vertical on the sides, horizontal along the top and bottom.
    var barAxis: Axis { edge.isHorizontal ? .horizontal : .vertical }
    /// Space at both ends of the bar along its axis, so a tile sits as far from the rounded end as from the sides.
    static let barEnd = (Theme.Metrics.bar - Theme.Metrics.pitch) / 2

    /// One order on every edge (DESIGN.md 5.1): Inbox, CI | sessions, + | Update, Gear. Side edges stack it on the
    /// rail; along the top and bottom it runs left to right.
    @ViewBuilder var restBar: some View {
        let axis = barAxis
        if axis == .vertical {
            VStack(spacing: 0) { restCells }
                .padding(.vertical, Self.barEnd)
                // Beside a page, the rail runs the page's height; the cells stay where they were.
                .frame(width: Self.cell)
                .frame(maxHeight: pageOpen ? .infinity : nil, alignment: .top)
                .background(Theme.rail)
        } else {
            HStack(spacing: 0) { restCells }
                .padding(.horizontal, Self.barEnd)
                .frame(height: Self.cell)
        }
    }

    @ViewBuilder var restCells: some View {
        let axis = barAxis
        InboxBarCell(axis: axis, needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots),
                     show: { show(.inbox) }, action: openInbox)
            .modifier(probe(.inbox))
            .section("Inbox")
        if !store.ciRepos.isEmpty {
            CIBarCell(axis: axis, store: store, show: { show(.ci) })
                .modifier(probe(.ci))
                .section("CI")
        }
        barDivider
        if store.agents.enabled {
            RestSessionCells(store: store, ui: ui, hub: hub, axis: axis, onRail: axis == .vertical, room: sessionRoom) {
                show(.agents, session: $0, listingAll: $1)
            }
                .modifier(probe(.agents))
                .section("Sessions")
            barDivider
        }
        if store.updater.showsInPill {
            UpdateBarCell(axis: axis, updater: store.updater) { hub.go(.settings) }
        }
        GearBarCell(axis: axis, store: store, hub: hub) { show(.controls) }
            .modifier(probe(.controls))
            .section("Controls")
    }

    /// One hairline grammar: 18pt long, 9pt of room each side, whichever way the bar runs.
    var barDivider: some View {
        Group {
            if barAxis == .vertical {
                Hairline().frame(width: 18).frame(width: Self.cell, height: Self.dividerSlot)
            } else {
                Hairline(axis: .vertical).frame(height: 18).frame(width: Self.dividerSlot, height: Self.cell)
            }
        }
        .accessibilityHidden(true)
    }
    static let dividerSlot: CGFloat = 19

    /// What the sessions' cells may take of the bar's length (the "+N" among them): the screen's room less the ends,
    /// the other cells, both dividers and the "+". The rest of the sessions are behind the "+N".
    var sessionRoom: CGFloat {
        let pitch = Theme.Metrics.pitch
        let others = 2 * Self.barEnd + 2 * Self.dividerSlot + 3 * pitch  // inbox, gear, "+"
            + (store.ciRepos.isEmpty ? 0 : pitch) + (store.updater.showsInPill ? pitch : 0)
        return barLength - others
    }

    /// The inbox cell's click: straight to what needs you, its newest item picked so the keys act on it at once.
    func openInbox() {
        withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) {
            hub.go(.main)
            hub.query = ""
            hub.inbox.endSearch()
            hub.filter = .needsYou
            // The pick is a row of the inbox: another section's focus would fold it away and leave nothing to pick.
            if hub.focus != .inbox { hub.focus = nil }
        }
        if let first = store.list(.needsYou).first {
            hub.selection = "i:" + first.id
            hub.requestScroll("i:" + first.id)
            ui.drawerSelection = nil
        }
    }

    /// A cell's `Show` (VoiceOver, and Return on a focused cell, or the "+N"): keeps the hub open on that cell's
    /// section with the selection there, and moves VoiceOver's cursor to the picked row (CI: its header).
    func show(_ section: HubSection, session: String? = nil, listingAll: Bool = false) {
        // The controls are a menu, not a section: the peek at rest, the footer kept open (neither pins the hub).
        if section == .controls { return hub.showControls() }
        withAnimation(Self.opening.resolved(reduce: reduce)) {
            hub.go(.main)
            hub.focus = nil
            hub.pinned = true
        }
        switch section {
        case .inbox:
            openInbox()
            hub.moveVoiceOver(to: hub.selection ?? "h:inbox")
        case .agents:
            hub.showSession(session, store: store, ui: ui, listingAll: listingAll)
            hub.moveVoiceOver(to: hub.selection ?? "h:agents")
        case .ci:
            hub.showCI(store, ui: ui)
        case .controls:
            break
        }
    }
}

extension HubState {
    /// The sessions' section as a bar cell shows it: `session` (else the first) picked and scrolled to, and every
    /// session listed when it is one the list would leave out (New activity's "+N more"), or when `listingAll` says so
    /// (the bar's "+N" opens them all, whichever of them it stands for). The keys walk through the same rows.
    func showSession(_ id: String?, store: Store, ui: UIState, listingAll: Bool = false) {
        query = ""
        inbox.endSearch()
        if listingAll || id.map({ id in !store.hubSessions(self).contains { $0.id == id } }) == true { sessionsExpanded = true }
        guard let id = id ?? store.hubSessions(self).first?.id else { return }
        selection = "a:" + id
        requestScroll("a:" + id)
        ui.drawerSelection = id
    }
}

/// The session cells of the bar at rest: their tiles by group, the "+N", the "+". The order and the groups they
/// show are frozen while the pointer is over the hub (a session's marks still update) and applied, with a fade,
/// once it leaves.
struct RestSessionCells: View {
    let store: Store
    let ui: UIState
    let hub: HubState
    let axis: Axis
    let onRail: Bool
    /// Points along the bar for the tiles and the "+N" (`LookoutHub.sessionRoom`).
    let room: CGFloat
    /// Show the sessions' section, picking this session (or the first), with every session listed or not.
    let show: (String?, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let slots = store.barSlots
        let (shown, hidden) = BarSessions.arrange(slots, frozen: hub.frozenSessions, room: room)
        let byID = Dictionary(uniqueKeysWithValues: store.sessionGroups.flatMap(\.rows).map { ($0.id, $0) })
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            if slots.isEmpty { SessionsAnchorCell(axis: axis) { show(nil, false) } }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, slot in
                if let row = byID[slot.id] {
                    BarTile(row: row, axis: axis, onRail: onRail, store: store, ui: ui, hub: hub) { show(row.id, false) }
                        .padding(axis == .vertical ? .top : .leading, BarSessions.gap(shown, before: index))
                        .transition(.opacity)
                }
            }
            if !hidden.isEmpty {
                MoreSessionsCell(axis: axis, count: hidden.count, waiting: hidden.filter(\.waiting).count) { show(hidden.first?.id, true) }
            }
            NewSessionBarCell(axis: axis, store: store) { show(nil, false) }
        }
        .animation(reduce ? nil : Theme.Motion.fade, value: shown.map { $0.id + $0.group })
    }
}

/// Holds the sessions' order and groups while the pointer is over the hub (`HubState.frozenSessions`): the bar's tiles,
/// the peek's rows and the kept-open list all follow it, and it is applied once the pointer leaves. It sits at the hub's
/// own boundary, not in the bar's cells, so opening the full view (which replaces them) doesn't let go of it. A view of its
/// own: only this body reads whether the pointer is over the hub.
struct SessionFreeze: View {
    let store: Store
    let hub: HubState

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { if hub.hovering { freeze() } }
            .onDisappear { hub.frozenSessions = nil }
            .onChange(of: hub.hovering) { _, over in
                if over { freeze() } else { hub.frozenSessions = nil }
            }
    }

    /// Keeps the order and the groups as they are now, whatever the sessions do until the pointer leaves.
    private func freeze() {
        hub.frozenSessions = store.barSlots
    }
}
