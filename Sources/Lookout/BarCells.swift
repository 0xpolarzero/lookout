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
        BarCell(axis: axis, name: "Inbox", value: Self.value(needsYou: needsYou, bots: bots), hint: "Shows the inbox",
                show: show, action: action) { hovering in
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

/// What the bar says about CI: the worst state of the repositories that aren't muted, how many are in each, and the
/// repository a click opens (the worst state's, the most recently changed first).
struct CIBarSummary {
    var worst = CIState.none
    var failing = 0
    var running = 0
    var passing = 0
    var muted = 0
    /// Repositories with no run yet: counted for VoiceOver, never the glyph's.
    var noRuns = 0
    var open: RepoConfig?

    /// A repository is muted while its commit is the one it was muted at (`Store.mutedCI`).
    static func make(repos: [RepoConfig], status: [String: CIStatus], muted: [String: String]) -> CIBarSummary {
        var summary = CIBarSummary()
        var newest = Date.distantPast
        for repo in repos {
            let current = status[repo.fullName]
            if let sha = muted[repo.fullName], sha == current?.sha { summary.muted += 1; continue }
            let state = current?.state ?? .none
            switch state {
            case .failure: summary.failing += 1
            case .pending: summary.running += 1
            case .success: summary.passing += 1
            case .none: summary.noRuns += 1
            }
            let when = current?.updatedAt ?? current?.checkedAt ?? .distantPast
            if rank(state) > rank(summary.worst) || summary.open == nil {
                summary.worst = state
                summary.open = repo
                newest = when
            } else if state == summary.worst, when > newest {
                summary.open = repo
                newest = when
            }
        }
        return summary
    }

    private static func rank(_ state: CIState) -> Int {
        switch state {
        case .failure: 3
        case .pending: 2
        case .success: 1
        case .none: 0
        }
    }

    /// "1 failing, 1 running, 2 passing": what VoiceOver reads after "CI".
    var value: String {
        [failing > 0 ? "\(failing) failing" : nil, running > 0 ? "\(running) running" : nil,
         passing > 0 ? "\(passing) passing" : nil, noRuns > 0 ? "\(noRuns) without runs" : nil,
         muted > 0 ? "\(muted) muted" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// The tooltip's title.
    var title: String {
        switch worst {
        case .failure: "CI: \(failing) failing"
        case .pending: "CI: \(running) running"
        case .success: "CI: all passing"
        case .none: "CI: no runs"
        }
    }
}

/// CI as one glyph, no tile: the worst state's own silhouette, and the failing count under it only when something
/// fails. Always the 26pt footprint of the other cells, so the glyph stays on the bar's axis and nothing shifts
/// (or changes its hover fill) when the first failure arrives. The bar leaves it out when no repository has CI on.
struct CIBarCell: View {
    let axis: Axis
    let summary: CIBarSummary
    let show: () -> Void
    let action: () -> Void

    var body: some View {
        let name = summary.open?.name
        BarCell(axis: axis, name: "CI", value: summary.value, hint: name.map { "Opens the checks of \($0)" } ?? "Shows CI",
                help: BarHelp(title: summary.title, detail: name.map { "Click to open the checks of \($0)" }),
                show: show, action: action) { hovering in
            Face(worst: summary.worst, failing: summary.failing, hovering: hovering)
        }
    }

    /// What the cell draws (not private: the tests measure it).
    struct Face: View {
        let worst: CIState
        let failing: Int
        let hovering: Bool
        @Environment(\.resolved) private var resolved

        var body: some View {
            VStack(spacing: -1) {
                Image(systemName: worst.countSymbol)
                    .font(Theme.Typography.glyph(14, .regular))
                    // One colour in both layers: left to the default rendering, the two outline symbols (check,
                    // minus) ignore the style in the bar and draw white. (The filled octagon keeps its x cut out.)
                    .symbolRenderingMode(worst == .failure ? .monochrome : .palette)
                    .foregroundStyle(worst.color, worst.color)
                if worst == .failure {
                    Text(failing > 99 ? "99+" : "\(failing)").font(Theme.Typography.numeral).foregroundStyle(Theme.red)
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
                show: show, action: { updater.advance() }) { hovering in
            Face(phase: updater.phase, hovering: hovering)
        }
        .contextMenu {
            if let page = updater.release?.page { Button("What's new in \(version)") { NSWorkspace.shared.open(page) } }
            Button("Skip \(version)") { updater.skip() }
        }
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
        case .downloading(let fraction): "Downloading, \(Int(fraction * 100)) percent"
        case .installing: "Installing"
        case .failed(let error): "Failed: \(error)"
        case .ready: "Ready"
        default: "Available"
        }
    }

    private var help: BarHelp {
        let version = updater.release?.version ?? ""
        return switch updater.phase {
        case .downloading(let fraction): BarHelp(title: "Downloading Lookout \(version)… \(Int(fraction * 100))%")
        case .ready: BarHelp(title: "Lookout \(version) is ready", detail: "Click to restart into it")
        case .installing: BarHelp(title: "Installing Lookout \(version)…")
        case .failed(let error): BarHelp(title: "Update failed: \(error)", detail: "Click to try again")
        default: BarHelp(title: "Lookout \(version) is available", detail: "Click to download it · right-click for more")
        }
    }

    private struct Face: View {
        let phase: Updater.Phase
        let hovering: Bool
        @Environment(\.resolved) private var resolved

        var body: some View {
            let ready = phase == .ready
            ZStack {
                if case .downloading(let fraction) = phase {
                    Circle().stroke(resolved.fill(Theme.Fill.selected), lineWidth: 1.5).frame(width: 22, height: 22)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                }
                if phase == .installing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(Theme.Typography.glyph(12, .bold)).foregroundStyle(ready ? Theme.onTint : tint)
                }
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
    case signIn, partial, rateLimited, stale

    /// Red is broken; the rest need a look, not a fix.
    var tint: Color { self == .signIn ? Theme.red : Theme.amber }

    var phrase: String {
        switch self {
        case .signIn: "Can't sign in to GitHub"
        case .partial: "Some repositories didn't sync"
        case .rateLimited: "GitHub is rate limiting"
        case .stale: "Not syncing"
        }
    }
}

extension Store {
    /// `stale`: the last sync is older than three poll intervals (the caller owns the wait: see `staleAt`).
    func syncFault(stale: Bool) -> SyncFault? {
        if authError != nil { return .signIn }
        if !repoErrors.isEmpty { return .partial }
        if let rateRemaining, rateRemaining <= 0 { return .rateLimited }
        return stale ? .stale : nil
    }

    /// When the last sync turns stale (nil before the first one).
    var staleAt: Date? { lastSync?.addingTimeInterval(settings.pollInterval * 3) }
}

/// The gear: Settings by click, the controls by hover (the bar's peek) or by VoiceOver's actions.
struct GearBarCell: View {
    let axis: Axis
    let store: Store
    let hub: HubState
    let showControls: () -> Void
    /// Set once the last sync is older than three poll intervals.
    @State private var stale = false

    var body: some View {
        let fault = store.syncFault(stale: stale)
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
        .task(id: store.lastSync) { await markStale() }
    }

    /// A one-shot wait for the moment the sync goes stale: no clock ticks while it is healthy.
    private func markStale() async {
        stale = false
        guard let at = store.staleAt else { return }
        let wait = at.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        if !Task.isCancelled { stale = true }
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
            Face(count: count, lit: waiting > 0, hovering: hovering)
        }
    }

    private struct Face: View {
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

    var body: some View {
        let folders = store.agentFolders
        Menu {
            Button("Scratch (no folder)") { store.startScratchSession() }
            if !folders.isEmpty { Divider() }
            ForEach(folders, id: \.self) { folder in
                Button(URL(fileURLWithPath: folder).lastPathComponent) { store.startAgent(in: folder) }
            }
        } label: {
            Image(systemName: "plus")
                .font(Theme.Typography.glyph(12, .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.secondary))
                .frame(width: Theme.Metrics.tile, height: Theme.Metrics.tile)
                .background(Tile.shape(Theme.Metrics.tile).fill(hovering ? Theme.Fill.selected : Theme.Fill.tile))
                .frame(width: axis == .vertical ? Theme.Metrics.bar : Theme.Metrics.pitch,
                       height: axis == .vertical ? Theme.Metrics.pitch : Theme.Metrics.bar)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .motion(Theme.Motion.hover, value: hovering)
        .tip("New session", "Scratch chat, or pick a project")
        .accessibilityLabel("New session")
        .accessibilityHint("Scratch chat, or pick a project")
        .accessibilityActions { Button("Show", action: show) }
    }
}

/// Which sessions the bar shows and in what order (DESIGN.md 5.1): waiting first, then the projects, then new
/// activity; eight tiles and a "+N", except that a session waiting for you never goes into the "+N" for want of a
/// slot. Only the edge's room can put one there, and then the "+N" says so. While the pointer is over the hub the
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

    static let visible = 8
    /// A project boundary: this much more than the cells' own pitch.
    static let groupGap: CGFloat = 8

    /// Waiting sessions, then the kept ones by project in their order, then the new activity.
    static func slots(kept: [AgentRow], pending: [AgentRow]) -> [Slot] {
        func slot(_ row: AgentRow, _ group: String) -> Slot {
            let waiting = row.tileMarks.waiting
            return Slot(id: row.id, group: waiting ? "waiting" : group, waiting: waiting)
        }
        let all = kept.map { slot($0, "p:" + $0.session.folderKey) } + pending.map { slot($0, "new") }
        return all.filter(\.waiting) + all.filter { !$0.waiting }
    }

    /// `slots` in the frozen order, each in the group it had (those still there, then any new ones as they are),
    /// cut to `visible` plus every waiting one (whether it waits is as it is now), then to `room` points along the bar,
    /// the "+N" cell included: what goes is the last of the others, and only when they are gone, the last waiting one.
    /// One session over would be a "+1" in the place of its own tile: it shows instead, room allowing.
    static func arrange(_ slots: [Slot], frozen: [Slot]?, visible: Int = visible,
                        room: CGFloat = .infinity) -> (shown: [Slot], hidden: [Slot]) {
        var ordered = slots
        if let frozen {
            let now = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let known = Set(frozen.map(\.id))
            ordered = frozen.compactMap { old in now[old.id].map { Slot(id: old.id, group: old.group, waiting: $0.waiting) } }
                + slots.filter { !known.contains($0.id) }
        }
        var shown = ordered.enumerated().filter { $0.offset < visible || $0.element.waiting }.map(\.element)
        while length(shown, more: shown.count < ordered.count) > room,
              let cut = shown.lastIndex(where: { !$0.waiting }) ?? shown.indices.last {
            shown.remove(at: cut)
        }
        if ordered.count - shown.count == 1, length(ordered, more: false) <= room { shown = ordered }
        let ids = Set(shown.map(\.id))
        return (shown, ordered.filter { !ids.contains($0.id) })
    }

    /// What the tiles take along the bar, with their gaps, and the "+N" cell when there is one.
    private static func length(_ run: [Slot], more: Bool) -> CGFloat {
        CGFloat(run.count + (more ? 1 : 0)) * Theme.Metrics.pitch + run.indices.reduce(0) { $0 + gap(run, before: $1) }
    }

    /// The room before the cell at `index` beyond the pitch: a project boundary.
    static func gap(_ shown: [Slot], before index: Int) -> CGFloat {
        index > 0 && shown[index - 1].group != shown[index].group ? groupGap : 0
    }
}
