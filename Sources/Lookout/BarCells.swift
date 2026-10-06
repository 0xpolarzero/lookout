import AppKit
import SwiftUI

// What the bar's cells show, and the cells themselves (DESIGN.md 5.1): inbox, CI, update, gear and the few that
// stand for sessions. Each is a `BarCell`, so on every edge they are the same buttons with the same VoiceOver.

// MARK: - Inbox

/// The inbox: an amber tile with the count of what needs you, else the quiet tray. The same footprint either way,
/// so nothing shifts when the first item arrives.
struct InboxBarCell: View {
    let axis: Axis
    let needsYou: Int
    let bots: Int
    let show: () -> Void
    let action: () -> Void

    var body: some View {
        // VoiceOver's press opens the hub on the inbox (a click, with the pointer on the bar, has its panel already).
        BarCell(axis: axis, name: "Inbox", value: Self.value(needsYou: needsYou, bots: bots), hint: "Shows the inbox",
                show: show, press: show, action: action) { hovering in
            Face(needsYou: needsYou, hovering: hovering)
        }
    }

    /// "5 need you, 2 bot items" / "Nothing needs you".
    static func value(needsYou: Int, bots: Int) -> String {
        [needsYou > 0 ? "\(needsYou) need you" : "Nothing needs you", bots > 0 ? plural(bots, "bot item") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private struct Face: View {
        let needsYou: Int
        let hovering: Bool
        @Environment(\.resolved) private var resolved

        var body: some View {
            let lit = needsYou > 0
            Group {
                if lit {
                    Text(needsYou > 99 ? "99+" : "\(needsYou)")
                        .font(.system(size: needsYou > 99 ? 11 : 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.onTint)
                        .contentTransition(.numericText(value: Double(needsYou)))
                } else {
                    Image(systemName: "tray").font(Theme.Typography.glyph(13, .regular)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
            .background(Tile.shape(Theme.Metrics.tile).fill(lit ? Theme.amber : resolved.fill(hovering ? Theme.Fill.selected : Theme.Fill.tile)))
            .brightness(lit && hovering ? 0.06 : 0)
            .motion(Theme.Motion.fade, value: needsYou)
        }
    }
}

// MARK: - CI

/// CI as one glyph, no tile: the worst state's own silhouette (`Store.ciWorst`, muted repositories left out), and the
/// failing count under it only when something fails. Always the 26pt footprint of the other cells, so the glyph stays
/// on the bar's axis and nothing shifts (or changes its hover fill) when the first failure arrives. A click opens the
/// checks of the repository it stands for. The bar leaves it out when no repository has CI on.
struct CIBarCell: View {
    let axis: Axis
    let store: Store
    let show: () -> Void

    /// What the cell shows of how many fail: the number, or "9+" so two digits never reach the screen's edge.
    static func count(_ failing: Int) -> String { failing > 9 ? "9+" : "\(failing)" }

    var body: some View {
        let worst = store.ciWorst
        let opens = store.ciOpensHelp
        BarCell(axis: axis, name: "CI", value: CISpeech.summary(store.ciList), hint: opens, help: BarHelp(title: "CI", detail: opens),
                show: show, action: { if store.ciWorstRepo != nil { store.openWorstChecks() } else { show() } }) { hovering in
            Face(worst: worst.state, failing: worst.failing, hovering: hovering)
        }
        .motion(Theme.Motion.fade, value: worst)
    }

    /// What the cell draws (not private: the tests measure it).
    struct Face: View {
        let worst: CIState
        let failing: Int
        let hovering: Bool
        @Environment(\.resolved) private var resolved

        var body: some View {
            VStack(spacing: -1) {
                Image(systemName: worst.symbol)
                    .font(Theme.Typography.glyph(14, worst == .failure ? .semibold : .regular))
                    // Palette, so every layer takes a colour: with one style the outline circles (passing, no runs) drew
                    // white in the bar. The failing octagon keeps its cross cut out.
                    .symbolRenderingMode(worst == .failure ? .monochrome : .palette)
                    .foregroundStyle(worst.color(resolved), worst.color(resolved))
                    .contentTransition(.symbolEffect(.replace))
                if worst == .failure {
                    Text(CIBarCell.count(failing)).font(Theme.Typography.numeral).foregroundStyle(Theme.red)
                }
            }
            .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
            .background(Tile.shape(Theme.Metrics.tile).fill(resolved.fill(hovering ? Theme.Fill.hover : Theme.Fill.rest)))
        }
    }
}

// MARK: - Update

/// A release waiting: a neutral tile with the arrow in accent (a ring round it while it downloads), green with the
/// restart arrow once ready. Never blue-filled.
struct UpdateBarCell: View {
    let axis: Axis
    let updater: Updater
    let show: () -> Void

    var body: some View {
        let version = updater.release?.version ?? ""
        BarCell(axis: axis, name: Self.name(updater.phase, version: version), value: value, hint: help.title, help: help,
                show: show, actions: menuActions(version), action: { updater.advance() }) { hovering in
            Face(updater: updater, hovering: hovering)
        }
        .contextMenu {
            if let page = updater.release?.page { Button("What's new in \(version)") { NSWorkspace.shared.open(page) } }
            Button("Skip \(version)") { updater.skip() }
        }
    }

    /// The context menu's items, for VoiceOver's actions.
    private func menuActions(_ version: String) -> [BarAction] {
        var actions: [BarAction] = []
        if let page = updater.release?.page { actions.append(BarAction(name: "What's new in \(version)") { NSWorkspace.shared.open(page) }) }
        return actions + [BarAction(name: "Skip \(version)") { updater.skip() }]
    }

    static func name(_ phase: Updater.Phase, version: String) -> String {
        switch phase {
        case .ready, .installing: "Restart to update"
        case .failed: "Retry update"
        default: "Update to \(version)"
        }
    }

    private var value: String {
        switch updater.phase {
        case .downloading: "Downloading, \(Int(updater.fraction * 100)) percent"
        case .installing: "Installing"
        case .failed(let error): "Failed: \(error)"
        case .ready: "Ready"
        default: "Available"
        }
    }

    private var help: BarHelp {
        let version = updater.release?.version ?? ""
        return switch updater.phase {
        case .downloading: BarHelp(title: "Downloading Lookout \(version)… \(Int(updater.fraction * 100))%")
        case .ready: BarHelp(title: "Lookout \(version) is ready", detail: "Click to restart into it")
        case .installing: BarHelp(title: "Installing Lookout \(version)…")
        case .failed(let error): BarHelp(title: "Update failed: \(error)", detail: "Click to try again")
        default: BarHelp(title: "Lookout \(version) is available", detail: "Click to download it · right-click for more")
        }
    }

    private struct Face: View {
        let updater: Updater
        let hovering: Bool
        @Environment(\.resolved) private var resolved
        private var phase: Updater.Phase { updater.phase }

        var body: some View {
            let ready = phase == .ready
            ZStack {
                if phase == .downloading {
                    Circle().stroke(Theme.downloadTrack, lineWidth: 1.5).frame(width: 22, height: 22)
                    Circle().trim(from: 0, to: max(0.03, updater.fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                }
                Image(systemName: symbol).font(Theme.Typography.glyph(12, .bold)).foregroundStyle(ready ? Theme.onTint : tint)
            }
            .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
            // design-lint: ignore (the update tile, where green lives)
            .background(Tile.shape(Theme.Metrics.tile).fill(ready ? Theme.green : resolved.fill(hovering ? Theme.Fill.selected : Theme.Fill.tile)))
            .brightness(ready && hovering ? 0.06 : 0)
        }

        private var symbol: String {
            switch phase {
            case .ready: "arrow.clockwise"
            case .failed: "exclamationmark"
            // Static: it is a moment, and the label says it.
            case .installing: "ellipsis"
            default: "arrow.down"
            }
        }

        private var tint: Color {
            if case .failed = phase { return Theme.red }
            return Theme.accent
        }
    }
}

// MARK: - Gear

/// What is wrong with syncing, worst first: the gear wears a badge for it. Healthy and snoozed are not faults.
enum SyncFault: Equatable {
    case signIn, partial, reviewRequests, reviewRequestsCut, rateLimited, stale, ciStale

    /// Red is broken; the rest need a look, not a fix.
    var tint: Color { self == .signIn ? Theme.red : Theme.amber }

    var phrase: String {
        switch self {
        case .signIn: "Can't sign in to GitHub"
        case .partial: "Some repositories didn't sync"
        case .reviewRequests: "Review requests didn't sync"
        case .reviewRequestsCut: "Some review requests weren't checked"
        case .rateLimited: "GitHub is rate limiting"
        case .stale: "Not syncing"
        case .ciStale: "CI isn't up to date"
        }
    }
}

extension Store {
    /// `stale`: the last sync is older than three poll intervals; `ciStale`: so is the oldest check CI's rows show (the
    /// caller owns the wait: see `staleDeadlines`).
    func syncFault(stale: Bool, ciStale: Bool = false) -> SyncFault? {
        if authError != nil { return .signIn }
        if !repoErrors.isEmpty { return .partial }
        if reviewRequestsFailing { return .reviewRequests }
        // The search worked but GitHub cut it short: what it found is real, the rest is not known (DESIGN.md 10.8).
        if reviewRequestsPartial { return .reviewRequestsCut }
        if let rateRemaining, rateRemaining <= 0 { return .rateLimited }
        if stale { return .stale }
        return ciStale ? .ciStale : nil
    }

    /// How old an answer may be before it is not called fresh: three poll intervals.
    var staleAfter: TimeInterval { settings.pollInterval * 3 }

    /// Whether the last sync is too old to be called fresh.
    func isStale(at now: Date) -> Bool { lastSync.map { now.timeIntervalSince($0) > staleAfter } ?? false }

    /// Whether the oldest check the CI rows show is too old (a sync that refreshed the inbox can leave CI behind).
    func isCIStale(at now: Date) -> Bool { ciFreshness.map { now.timeIntervalSince($0) > staleAfter } ?? false }

    /// When the last sync, and CI's oldest check, turn stale: none before the first answer.
    var staleDeadlines: [Date] { [lastSync, ciFreshness].compactMap { $0?.addingTimeInterval(staleAfter) } }
}

/// The gear: Settings by click, the controls by hover (the bar's peek) or by VoiceOver's actions.
struct GearBarCell: View {
    let axis: Axis
    let store: Store
    let hub: HubState
    let showControls: () -> Void
    /// Set once the last sync, or CI's oldest check, is older than three poll intervals.
    @State private var stale = false
    @State private var ciStale = false

    var body: some View {
        let fault = store.syncFault(stale: stale, ciStale: ciStale)
        let open = hub.page == .settings
        let title = open ? "Close Settings" : "Settings"
        BarCell(axis: axis, name: fault == nil ? title : "\(title), sync problem", value: fault?.phrase ?? "",
                hint: "Hover, or use the actions, for the controls", help: BarHelp(title: title, detail: open ? "Esc" : "⌘,"),
                actions: [BarAction(name: hub.pinned ? "Stop keeping open" : "Keep open") { hub.pinned.toggle() },
                          BarAction(name: "Repositories") { hub.go(.repos) },
                          BarAction(name: "Check now") { store.refreshNow() },
                          BarAction(name: "Show controls", run: showControls)],
                action: { hub.go(open ? .main : .settings) }) { hovering in
            Face(active: open, hovering: hovering, fault: fault)
        }
        .task(id: store.staleDeadlines) { await markStale() }
    }

    /// One wait for each moment an answer goes stale, again whenever those moments change (a poll, the interval): no clock
    /// ticks while everything is fresh.
    private func markStale() async {
        func update() {
            let now = Date()
            stale = store.isStale(at: now)
            ciStale = store.isCIStale(at: now)
        }
        update()
        for at in store.staleDeadlines.sorted() where at > Date() {
            try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow))
            if Task.isCancelled { return }
            update()
        }
    }

    private struct Face: View {
        let active: Bool
        let hovering: Bool
        let fault: SyncFault?
        @Environment(\.resolved) private var resolved

        var body: some View {
            Image(systemName: "gearshape")
                .font(Theme.Typography.glyph(14, .medium))
                .foregroundStyle(active || hovering ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
                .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
                .background(Circle().fill(resolved.fill(active ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Theme.Fill.rest)))
                .overlay(alignment: .topTrailing) {
                    if let fault {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(Theme.Typography.glyph(9, .bold))
                            .foregroundStyle(fault.tint)
                            .background(Circle().fill(Theme.bg).padding(1))
                            .offset(x: 3, y: -3)
                    }
                }
        }
    }
}

// MARK: - Sessions

/// "+3": the sessions the bar has no room for. Opens the sessions' panel. Solid amber, like a waiting tile, when
/// one of them waits for you: that never hides behind a neutral number.
struct MoreSessionsCell: View {
    let axis: Axis
    let count: Int
    var waiting = 0
    let show: () -> Void

    var body: some View {
        BarCell(axis: axis, name: plural(count, "more session"), value: waiting > 0 ? "\(waiting) waiting for you" : "",
                hint: "Shows the sessions", show: show, action: show) { hovering in
            OverflowTile(count: count, lit: waiting > 0, hovering: hovering)
        }
    }
}

/// The "+N" tile: on the bar, and in the rail beside the "+N more" row of a list that has one.
struct OverflowTile: View {
    let count: Int
    let lit: Bool
    let hovering: Bool
    @Environment(\.resolved) private var resolved

    var body: some View {
        let shape = Tile.shape(Theme.Metrics.tile)
        Text("+\(count)")
            .font(Theme.Typography.numeral)
            .foregroundStyle(lit ? Theme.onTint : Theme.text)
            .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
            .background(shape.fill(lit ? Theme.amber : resolved.fill(hovering ? Theme.Fill.selected : Theme.Fill.tile)))
            // As on the waiting tile: a dark outline for an eye that can't tell amber from grey.
            .overlay { if resolved.differentiate, lit { shape.inset(by: 1).strokeBorder(Theme.onTint, lineWidth: 1.5) } }
            .brightness(lit && hovering ? 0.06 : 0)
    }
}

/// With the extension on and no session yet: a quiet asterisk to hover for the sessions' panel (and its new session row).
struct SessionsAnchorCell: View {
    let axis: Axis
    let show: () -> Void

    var body: some View {
        BarCell(axis: axis, name: "Sessions", value: "None", hint: "Shows the sessions", show: show, action: show) { _ in
            Image(systemName: "asterisk")
                .font(Theme.Typography.glyph(14, .bold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
        }
    }
}

/// The "+": a neutral tile that opens the new session menu (a scratch chat, or a project by name).
struct NewSessionBarCell: View {
    let axis: Axis
    let store: Store
    let show: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    /// Beside the cell on a side edge, so the tip never covers the rail's neighbours.
    @Environment(\.tipBeside) private var beside

    var body: some View {
        Menu {
            ProjectsMenuItems(store: store)
        } label: {
            Image(systemName: "plus")
                .font(Theme.Typography.glyph(12, .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
                .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
                .background(Tile.shape(Theme.Metrics.tile).fill(hovering ? Theme.Fill.selected : Theme.Fill.tile))
                .focusRing(Theme.Radius.tile, isFocused: focused)
                .frame(width: axis == .vertical ? Theme.Metrics.bar : Theme.Metrics.pitch,
                       height: axis == .vertical ? Theme.Metrics.pitch : Theme.Metrics.bar)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($focused)
        .reportsControlFocus(focused)
        .onHover { hovering = $0 }
        .motion(Theme.Motion.hover, value: hovering)
        .tip("New session", "Scratch chat, or pick a project", focused: focused, beside: beside)
        .accessibilityLabel("New session")
        .accessibilityHint("Scratch chat, or pick a project")
        .accessibilityActions { Button("Show", action: show) }
    }
}

/// Which sessions the bar shows and in what order (DESIGN.md 5.1): the sessions list's, waiting first, then the
/// projects, then new activity; as many tiles as `SessionCap` allows and a "+N", the lists' own rule, so a session
/// waiting for you never goes into the "+N" for want of a slot. Only the edge's room can put one there, and then the "+N" says so. While the pointer is over the hub the
/// order and the project boundaries stay as they were, so nothing under it moves; the sessions' side panel lays its
/// rows out from the same `arrange`, so each stays level with its tile.
enum BarSessions {
    /// A session as the layout sees it.
    struct Slot: Equatable {
        let id: String
        /// What it shares a gap with: "waiting", a project's folder, or "new".
        let group: String
        let waiting: Bool
    }

    /// A project boundary: this much more than the cells' own pitch.
    static let groupGap: CGFloat = 8

    /// The sessions list's own order (`SessionGroup.build`): Waiting for you, the projects, Scratch, New activity.
    /// Each is in the group it is listed under, so a project boundary is a gap on the bar.
    static func slots(groups: [SessionGroup]) -> [Slot] {
        groups.flatMap { group in
            group.rows.map { Slot(id: $0.id, group: group.id, waiting: group.kind == .waiting) }
        }
    }

    /// `slots` in the frozen order, each in the group it had (those still there, then any new ones as they are),
    /// cut to `SessionCap`'s (whether a session waits is as it is now; when frozen, one that began to wait past the
    /// tiles shown takes the last other tile's place), then to `room` points along the bar,
    /// the "+N" cell included: what goes is the last of the others, and only when they are gone, the last waiting one.
    /// One session over would be a "+1" in the place of its own tile: it shows instead, room allowing.
    static func arrange(_ slots: [Slot], frozen: [Slot]?, room: CGFloat = .infinity) -> (shown: [Slot], hidden: [Slot]) {
        let ordered = inOrder(slots, frozen: frozen)
        let limit = SessionCap.shown(total: ordered.count, waiting: ordered.filter(\.waiting).count)
        var shown = ordered.enumerated().filter { $0.offset < limit || $0.element.waiting }.map(\.element)
        if let frozen {
            // A session that starts waiting past the tiles the pointer found takes the place of the last tile that
            // doesn't, in that tile's group: the run keeps its length, so the "+N" and what follows don't move.
            let waited = Set(frozen.filter(\.waiting).map(\.id))
            for (offset, late) in ordered.enumerated() where offset >= limit && late.waiting && !waited.contains(late.id) {
                guard let from = shown.firstIndex(where: { $0.id == late.id }),
                      let into = shown.lastIndex(where: { !$0.waiting }), into < from else { continue }
                shown[into] = Slot(id: late.id, group: shown[into].group, waiting: true)
                shown.remove(at: from)
            }
        }
        while length(shown, more: shown.count < ordered.count) > room,
              let cut = shown.lastIndex(where: { !$0.waiting }) ?? shown.indices.last {
            shown.remove(at: cut)
        }
        if ordered.count - shown.count == 1, length(ordered, more: false) <= room { shown = ordered }
        let ids = Set(shown.map(\.id))
        return (shown, ordered.filter { !ids.contains($0.id) })
    }

    /// `slots` in the frozen order, each in the group it had (those still there, then any new ones as they are); whether
    /// a session waits is as it is now. The whole sequence: what the focused lists show, and what `arrange` cuts.
    static func inOrder(_ slots: [Slot], frozen: [Slot]?) -> [Slot] {
        guard let frozen else { return slots }
        let now = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(frozen.map(\.id))
        return frozen.compactMap { old in now[old.id].map { Slot(id: old.id, group: old.group, waiting: $0.waiting) } }
            + slots.filter { !known.contains($0.id) }
    }

    /// What the tiles take along the bar, with their gaps, and the "+N" cell when there is one.
    static func length(_ run: [Slot], more: Bool) -> CGFloat {
        CGFloat(run.count + (more ? 1 : 0)) * Theme.Metrics.pitch + run.indices.reduce(0) { $0 + gap(run, before: $1) }
    }

    /// The room before the cell at `index` beyond the pitch: a project boundary.
    static func gap(_ shown: [Slot], before index: Int) -> CGFloat {
        index > 0 && shown[index - 1].group != shown[index].group ? groupGap : 0
    }
}

extension Store {
    /// The bar's session cells in the list's order.
    var barSlots: [BarSessions.Slot] { BarSessions.slots(groups: sessionGroups) }
}
