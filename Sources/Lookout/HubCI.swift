import AppKit
import SwiftUI

// CI: its cell in the bar, its header, and the rows under it: failing then running repos get a row each, everything
// else is one Passing row that opens in place (DESIGN.md 5.5). The worst state the bar shows is `Store.ciWorst`.

/// What can be done with a repo's CI, as context menu items and as VoiceOver actions.
private struct CIAction {
    let title: String
    let symbol: String
    var destructive = false
    let perform: () -> Void
}

extension Store {
    /// The context menu's groups, and the same actions for VoiceOver (plus the link, which ⌘C copies).
    fileprivate func ciActions(for entry: CIEntry) -> [[CIAction]] {
        let repo = entry.repo
        var opens = [CIAction(title: "Open checks", symbol: "checklist") { self.openChecks(repo) }]
        if entry.status?.sha != nil { opens.append(CIAction(title: "Open commit", symbol: "arrow.triangle.branch") { self.openCommit(repo) }) }
        opens.append(CIAction(title: "Open repository", symbol: "book.closed") { self.openRepository(repo) })
        var groups = [opens]
        if entry.status?.sha != nil { groups.append([CIAction(title: "Copy commit SHA", symbol: "doc.on.doc") { self.copyCommitSHA(repo) }]) }
        var changes = [CIAction(title: "Check now", symbol: "arrow.clockwise") { self.checkCINow(repo) }]
        if entry.muted {
            changes.append(CIAction(title: "Unmute", symbol: "bell") { self.unmuteCI(repo) })
        } else if entry.state == .failure || entry.state == .pending {
            changes.append(CIAction(title: "Mute until it changes", symbol: "bell.slash") { self.muteCI(repo) })
        }
        groups.append(changes)
        groups.append([CIAction(title: "Stop showing CI", symbol: "eye.slash", destructive: true) { self.stopShowingCI(repo) }])
        return groups
    }

    /// Checks one repo's CI now, not everything.
    func checkCINow(_ repo: RepoConfig) {
        let name = repo.fullName
        Task { try? await syncCI(name) }
    }
}

private extension View {
    /// A repo's actions: the context menu, and the same as VoiceOver actions.
    func ciActions(_ entry: CIEntry, store: Store) -> some View {
        let groups = store.ciActions(for: entry)
        return contextMenu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.title) { action in
                    Button(role: action.destructive ? .destructive : nil, action: action.perform) {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
        }
        .accessibilityActions {
            ForEach(groups.flatMap { $0 }, id: \.title) { action in
                Button(action.title, action: action.perform)
            }
            Button("Copy link") { store.copyChecksURL(entry.repo) }
        }
    }
}

/// What VoiceOver says about CI: ages in words, names in a list.
enum CISpeech {
    /// "just now", "45 minutes ago", "2 hours ago", "on Sep 28".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(plural(s / 60, "minute")) ago" }
        if s < 86400 { return "\(plural(s / 3600, "hour")) ago" }
        if s < 7 * 86400 { return "\(plural(s / 86400, "day")) ago" }
        return "on " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "a", "a and b", "a, b and c". A check's "Linux / build" is read as "Linux build".
    static func list(_ names: [String]) -> String {
        let spoken = names.map { $0.replacingOccurrences(of: " / ", with: " ") }
        guard let last = spoken.last, spoken.count > 1 else { return spoken.first ?? "" }
        return spoken.dropLast().joined(separator: ", ") + " and " + last
    }

    /// A row's value, after its name: "failing, Linux build and Windows test, 45 minutes ago".
    static func value(_ entry: CIEntry, now: Date = Date()) -> String {
        var parts = [entry.state.voice]
        if entry.muted { parts.append("muted") }
        if entry.state == .failure, let failing = entry.status?.failing, !failing.isEmpty { parts.append(list(failing)) }
        if let changed = entry.changedAt { parts.append(age(changed, now: now)) }
        return parts.joined(separator: ", ")
    }

    /// The bar cell's value: "1 failing, 1 running, 2 passing".
    static func summary(_ list: CIList) -> String {
        let counts: [(Int, String)] = [
            (list.attention.filter { $0.state == .failure }.count, CIState.failure.label),
            (list.attention.filter { $0.state == .pending }.count, CIState.pending.label),
            (list.quiet.filter { $0.state == .success && !$0.muted }.count, CIState.success.label),
            (list.quiet.filter(\.muted).count, "muted"),
            (list.quiet.filter { $0.state == .none && !$0.muted }.count, CIState.none.label),
        ]
        return counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
}

// MARK: - Rows

/// A failing or running repo: its state, name and age, then what failed or the commit's headline.
struct CIRow: View {
    let entry: CIEntry
    let title: String
    let store: Store
    let ui: UIState
    let hub: HubState
    @State private var hover = false
    @Environment(\.resolved) private var resolved

    /// Compared here, in this row's own body: hovering another row doesn't rebuild the whole hub.
    private var selected: Bool { hub.selection == "c:" + entry.id }
    private var failing: [String] { entry.state == .failure ? entry.status?.failing ?? [] : [] }

    var body: some View {
        Button { store.openChecks(entry.repo) } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: entry.state.symbol)
                    .font(Theme.Typography.glyph(12))
                    .foregroundStyle(entry.state == .failure ? AnyShapeStyle(resolved.red) : entry.state.color)
                    .frame(width: Theme.Metrics.dotSlot, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text(title).font(Theme.Typography.body).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if let changed = entry.changedAt { CIAge(date: changed) }
                    }
                    detail
                }
            }
            // Two lines (16 + 2 + 14) inside the row's own 6pt padding: 44.
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.twoLineRow - 12, alignment: .topLeading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .accessibilityLabel(title)
        .accessibilityValue(CISpeech.value(entry))
        .accessibilityHint("Opens its checks. More actions available.")
        .help(tooltip)
        .ciActions(entry, store: store)
        .onHover {
            hover = $0
            if $0 {
                hub.selection = "c:" + entry.id
                ui.drawerSelection = nil
            }
        }
    }

    /// Line 2: the checks that failed, in red, or the commit's headline.
    @ViewBuilder private var detail: some View {
        if !failing.isEmpty {
            Text(failing.joined(separator: ", ")).font(Theme.Typography.meta).foregroundStyle(resolved.red).lineLimit(1)
        } else {
            Text(entry.status?.title ?? entry.status?.branch ?? "").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
    }

    private var tooltip: String {
        var lines = ["\(entry.repo.fullName) · \(entry.status?.branch ?? entry.repo.defaultBranch ?? "default branch")"]
        if let headline = entry.status?.title, !headline.isEmpty { lines.append(headline) }
        if !failing.isEmpty { lines.append("Failing: " + failing.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}

/// How long ago a repo's runs changed, on the shared clock.
private struct CIAge: View {
    let date: Date

    var body: some View {
        Ticking(coarse: true) { now in
            Text(shortAgo(date, now: now)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
        }
        .frame(minWidth: Theme.Metrics.ageColumn, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// Everything quiet as one 36pt row: "Passing · 11", or "All passing · 11 repositories" once nothing else is there.
/// Click, or → / ←, opens it in place.
private struct CIQuietRow: View {
    let list: CIList
    let open: Bool
    let hub: HubState
    let toggle: () -> Void
    @State private var hover = false

    private var selected: Bool { hub.selection == "c:passing" }
    private var count: Int { list.quiet.count }
    private var passing: Bool { list.quiet.contains { $0.state == .success || $0.muted } }

    private var title: String {
        if list.allPassing { return "All passing · \(plural(count, "repository", "repositories"))" }
        // Only repos with no run yet: not "passing".
        return "\(passing ? CIState.success.title : CIState.none.title) · \(count)"
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: passing ? CIState.success.symbol : CIState.none.symbol)
                    .font(Theme.Typography.glyph(12, .regular))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: Theme.Metrics.dotSlot)
                    .accessibilityHidden(true)
                Text(title).font(Theme.Typography.body).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(Theme.Typography.glyph(11)).foregroundStyle(Theme.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.pitch - 12, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityHint(open ? "Hides the repositories" : "Lists the repositories")
        .onHover { hover = $0; if $0 { hub.selection = "c:passing" } }
    }
}

/// A quiet repo in the opened Passing group: its name, and why it is there when that isn't "passing".
private struct CINameRow: View {
    let entry: CIEntry
    let title: String
    let store: Store
    let ui: UIState
    let hub: HubState
    @State private var hover = false

    private var selected: Bool { hub.selection == "c:" + entry.id }
    private var note: String? { entry.muted ? "muted" : entry.state == .none ? "no runs" : nil }

    var body: some View {
        Button { store.openChecks(entry.repo) } label: {
            HStack(spacing: Theme.Space.md) {
                Color.clear.frame(width: Theme.Metrics.dotSlot, height: 1)
                Text(title).font(Theme.Typography.body).foregroundStyle(Theme.secondary).lineLimit(1)
                if let note { Text(note).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuRow - 12, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .accessibilityLabel(title)
        .accessibilityValue(CISpeech.value(entry))
        .accessibilityHint("Opens its checks. More actions available.")
        .ciActions(entry, store: store)
        .onHover {
            hover = $0
            if $0 {
                hub.selection = "c:" + entry.id
                ui.drawerSelection = nil
            }
        }
    }
}

// MARK: - The section

extension LookoutHub {
    /// While searching, the results are the inbox and the sessions: CI leaves the layout (it isn't dimmed).
    var showsCI: Bool { !searching }

    /// The bar's CI cell: the worst state that isn't muted, and how many repos fail. Click opens that repo's checks.
    var ciCell: some View { CICell(store: store) }

    /// CI's section header: "CI", and one phrase only when something is not green.
    var ciHeader: some View {
        let focused = hub.focus == .ci
        let toggle: (() -> Void)? = showsDetail && !store.ciRepos.isEmpty ? {
            withAnimation(Self.refocus.resolved(reduce: reduce)) { hub.focus = focused ? nil : .ci }
        } : nil
        return SectionHeader(title: "CI", status: ciPhrase, focused: focused, expandHelp: focused ? "Back to all sections" : "Expand CI",
                             onFocus: toggle) {}
    }

    /// "2 failing" in red; "1 running" while nothing fails; nothing once everything has passed.
    var ciPhrase: (text: String, color: AnyShapeStyle)? {
        let worst = store.ciWorst
        switch worst.state {
        case .failure: return ("\(worst.failing) failing", AnyShapeStyle(Theme.red))
        case .pending: return ("\(store.ciList.attention.count) running", AnyShapeStyle(Theme.secondary))
        default: return nil
        }
    }

    /// The rows under the header: one per failing or running repo, then the Passing row (open in place on request).
    /// Without any CI, a calm empty state with the way to turn it on.
    var ciRows: some View {
        let list = store.ciList
        let open = hub.ciPassingOpen || hub.focus == .ci
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                EmptyBlock(title: "No CI configured") {
                    Button { hub.go(.repos) } label: {
                        Text("Choose repositories").font(Theme.Typography.control).foregroundStyle(Theme.accentText)
                            .frame(minHeight: Theme.Metrics.iconButton).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusRing(Theme.Radius.small)
                }
            } else {
                staleLine
                ForEach(list.attention) { entry in
                    CIRow(entry: entry, title: list.title(entry.repo), store: store, ui: ui, hub: hub).id("c:" + entry.id)
                }
                if !list.quiet.isEmpty {
                    CIQuietRow(list: list, open: open, hub: hub) { hub.setCIPassingOpen(!open) }.id("c:passing")
                    if open { quietNames(list) }
                }
            }
        }
        .motion(Theme.Motion.fade, value: list.entries.map { "\($0.id) \($0.state.rawValue) \($0.muted)" })
    }

    /// The opened Passing group: names, a few at a time.
    private func quietNames(_ list: CIList) -> some View {
        CappedScroll(cap: Theme.Metrics.menuRow * 8, hub: hub) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list.quiet) { entry in
                    CINameRow(entry: entry, title: list.title(entry.repo), store: store, ui: ui, hub: hub)
                        .capEdge()
                        .id("c:" + entry.id)
                }
            }
        }
        .transition(.opacity)
    }

    /// "Last checked 12:03", only when what the rows show is no longer fresh (the footer's "Not syncing" rule).
    @ViewBuilder private var staleLine: some View {
        if let last = store.lastSync {
            Ticking(coarse: true) { now in
                if now.timeIntervalSince(last) > store.settings.pollInterval * 3 {
                    Text("Last checked \(last.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Metrics.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                }
            }
        }
    }

    /// Along the top and bottom, and focused: the rows in their own column. (Its header is in the strip.)
    var ciColumn: some View {
        Group { if showsCI { ciRows } }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
    }
}

/// CI in the bar: one glyph, the worst state that isn't muted, with the number of failing repos beside it only
/// when some fail. Absent when no repo has CI on.
struct CICell: View {
    let store: Store

    var body: some View {
        if !store.ciRepos.isEmpty {
            let worst = store.ciWorst
            Button { store.openWorstChecks() } label: {
                HStack(spacing: 3) {
                    Image(systemName: worst.state.symbol)
                        .font(Theme.Typography.glyph(16, worst.state == .failure ? .semibold : .regular))
                        .foregroundStyle(worst.state.color)
                        .contentTransition(.symbolEffect(.replace))
                    if worst.failing > 0 {
                        Text("\(worst.failing)").font(Theme.Typography.numeral).foregroundStyle(Theme.red)
                            .contentTransition(.numericText(value: Double(worst.failing)))
                    }
                }
                .frame(minWidth: Theme.Metrics.pitch, minHeight: Theme.Metrics.pitch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.tile)
            .accessibilityLabel("CI")
            .accessibilityValue(CISpeech.summary(store.ciList))
            .accessibilityHint("Opens the checks of the repository that needs you most")
            .motion(Theme.Motion.fade, value: worst)
        }
    }
}

// MARK: - Keys

extension HubState {
    /// Opens or closes the Passing group in place.
    func setCIPassingOpen(_ open: Bool) {
        LookoutHub.animate(open ? Theme.Motion.move : Theme.Motion.close) { ciPassingOpen = open }
    }

    /// CI's rows as keyboard targets, in the order they are listed ("c:<repo>"; "c:passing" is the Passing row).
    func ciTargets(_ store: Store) -> [String] {
        guard query.isEmpty, focus == nil || focus == .ci else { return [] }
        let list = store.ciList
        var targets = list.attention.map { "c:" + $0.id }
        if !list.quiet.isEmpty {
            targets.append("c:passing")
            if ciPassingOpen || focus == .ci { targets += list.quiet.map { "c:" + $0.id } }
        }
        return targets
    }
}

extension HubKeys {
    /// The keys on a picked CI row (`id` is the target without its "c:"): Return opens its checks (on the Passing row,
    /// opens or closes it), ⌘C copies the checks' URL, → and ← open and close Passing. Returns whether it was handled.
    func ciKey(_ event: NSEvent, id: String, flags: NSEvent.ModifierFlags, shortcut: Shortcut) -> Bool {
        let open = hub.ciPassingOpen || hub.focus == .ci
        let repo = store.repos.first { $0.fullName == id }
        if flags.isEmpty, event.keyCode == 124 || event.keyCode == 123 {
            // → opens it from its row; ← closes it from there or from a name under it, back on its row.
            if event.keyCode == 124, id == "passing", !open { hub.setCIPassingOpen(true); return true }
            if event.keyCode == 123, open, hub.focus != .ci { hub.setCIPassingOpen(false); select("c:passing"); return true }
            return false
        }
        if shortcut == store.shortcut(.openItem) {
            if id == "passing" { hub.setCIPassingOpen(!open) } else if let repo { store.openChecks(repo) }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c", let repo {
            store.copyChecksURL(repo)
            return true
        }
        return false
    }
}
