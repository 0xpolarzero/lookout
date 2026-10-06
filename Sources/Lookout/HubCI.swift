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
        // The age and what VoiceOver says of it come from the same minute, so they never part.
        Ticking(coarse: true) { now in row(now) }
    }

    private func row(_ now: Date) -> some View {
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
                        if let changed = entry.changedAt { CIAge(date: changed, now: now) }
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
        .accessibilityValue(CISpeech.value(entry, now: now))
        .accessibilityHint("Opens its checks. More actions available.")
        .help(tooltip)
        .ciActions(entry, store: store)
        .onHover { hover = $0; hub.pointer($0, over: "c:" + entry.id, ui: ui) }
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

/// How long ago a repo's runs changed, as of the minute clock's `now`.
private struct CIAge: View {
    let date: Date
    let now: Date

    var body: some View {
        Text(shortAgo(date, now: now)).font(Theme.Typography.numeral).foregroundStyle(Theme.secondary)
            .frame(minWidth: Theme.Metrics.ageColumn, alignment: .trailing)
            .accessibilityHidden(true)
    }
}

/// Everything quiet as one 36pt row: "Passing · 11, 1 muted", or "All passing · 11 repositories" once nothing else is
/// there. Click, or → / ←, opens it in place.
private struct CIQuietRow: View {
    let list: CIList
    let open: Bool
    let ui: UIState
    let hub: HubState
    let toggle: () -> Void
    @State private var hover = false

    private var selected: Bool { hub.selection == "c:passing" }

    /// The glyph of what the row mostly holds: a check only when something really passes.
    private var symbol: String {
        let (passing, muted, _) = list.quietCounts
        return passing > 0 || list.allPassing ? CIState.success.symbol : muted > 0 ? "bell.slash" : CIState.none.symbol
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: symbol)
                    .font(Theme.Typography.glyph(12, .regular))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: Theme.Metrics.dotSlot)
                    .accessibilityHidden(true)
                Text(list.quietTitle).font(Theme.Typography.body).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                // Its trailing edge is the ages' above it.
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(Theme.Typography.glyph(11)).foregroundStyle(Theme.tertiary)
                    .frame(width: Theme.Metrics.ageColumn, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.pitch - 12, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .accessibilityLabel(list.quietName)
        .accessibilityValue("\(list.quietSpeech), \(open ? "expanded" : "collapsed")")
        .accessibilityHint(open ? "Hides the repositories" : "Lists the repositories")
        .onHover { hover = $0; hub.pointer($0, over: "c:passing", ui: ui) }
    }
}

/// A quiet repo in the opened Passing group: its name, and why it is there when that isn't "passing". A muted repo
/// keeps its real state's glyph and word, in `tertiary`: it is quieted, not fixed.
private struct CINameRow: View {
    let entry: CIEntry
    let title: String
    let store: Store
    let ui: UIState
    let hub: HubState
    @State private var hover = false

    private var selected: Bool { hub.selection == "c:" + entry.id }
    private var note: String? { entry.muted ? "\(entry.state.label), muted" : entry.state == .none ? "no runs" : nil }

    var body: some View {
        Ticking(coarse: true) { now in row(now) }
    }

    private func row(_ now: Date) -> some View {
        Button { store.openChecks(entry.repo) } label: {
            HStack(spacing: Theme.Space.md) {
                Group {
                    if entry.muted {
                        Image(systemName: entry.state.symbol).font(Theme.Typography.glyph(12)).foregroundStyle(Theme.tertiary)
                            .accessibilityHidden(true)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: Theme.Metrics.dotSlot)
                Text(title).font(Theme.Typography.body).foregroundStyle(entry.muted ? Theme.tertiary : Theme.secondary).lineLimit(1)
                if let note { Text(note).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuRow - 12, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusRing(Theme.Radius.row, inset: true)
        .accessibilityLabel(title)
        .accessibilityValue(CISpeech.value(entry, now: now))
        .accessibilityHint("Opens its checks. More actions available.")
        .ciActions(entry, store: store)
        .onHover { hover = $0; hub.pointer($0, over: "c:" + entry.id, ui: ui) }
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

    /// The rows under the header: one per failing or running repo, then the Passing row (open in place on request),
    /// all in one list that scrolls within `ciCap`. Without any CI, one calm line with the way to turn it on.
    var ciRows: some View {
        let list = store.ciList
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                noCI
            } else {
                staleLine
                CappedScroll(cap: ciCap, hub: hub, fades: false, indicators: true) { ciListRows(list) }
            }
            if let undo = store.undoStack.visible(in: .ci) {
                UndoLine(message: undo.message) { store.undoLast() }.padding(.top, Theme.Space.xs)
            }
        }
        .motion(Theme.Motion.fade, value: list.entries.map { "\($0.id) \($0.state.rawValue) \($0.muted)" })
        .motion(Theme.Motion.fade, value: store.undoStack.visibleID)
        // A pick on a row that left the list (it passed, was muted, lost its CI) moves on instead of lingering.
        .onChange(of: hub.ciTargets(store)) { old, new in hub.rehomeCI(from: old, to: new) }
    }

    private func ciListRows(_ list: CIList) -> some View {
        let open = hub.ciPassingOpen || hub.focus == .ci
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(list.attention) { entry in
                CIRow(entry: entry, title: list.title(entry.repo), store: store, ui: ui, hub: hub).id("c:" + entry.id)
            }
            if !list.quiet.isEmpty {
                CIQuietRow(list: list, open: open, ui: ui, hub: hub) { hub.setCIPassingOpen(!open) }.id("c:passing")
                if open {
                    ForEach(list.quiet) { entry in
                        CINameRow(entry: entry, title: list.title(entry.repo), store: store, ui: ui, hub: hub)
                            .id("c:" + entry.id)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// The most height CI's rows take before they scroll, so every repository and key target stays reachable on a
    /// small screen. A panel has the room beside the bar. In the full view CI shares the height with the inbox and the
    /// sessions, and takes all that the other headers leave once it is the focused section.
    var ciCap: CGFloat {
        let row = Theme.Metrics.twoLineRow
        if !showsDetail { return max(4 * row, maxLength - Self.cell - 120) }
        if hub.focus == .ci { return max(160, maxLength - (edge.isHorizontal ? Self.cell + 60 : 260)) }
        return max(4 * row, (maxLength - 210) * 0.45)
    }

    /// Nothing watched has CI on: one line aligned with the glyph column, and where to turn it on.
    private var noCI: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("No CI configured").font(Theme.Typography.body).foregroundStyle(Theme.secondary).lineLimit(1)
            Text("·").foregroundStyle(Theme.tertiary).accessibilityHidden(true)
            Button { hub.go(.repos) } label: {
                Text("Choose repositories").font(Theme.Typography.control).foregroundStyle(Theme.accentText).lineLimit(1)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: Theme.Metrics.pitch, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// "Last checked 12:03", only when the answers the rows show are no longer fresh: the oldest successful check of a
    /// repository with CI on, so failed polls don't make old rows look new. (The footer's "Not syncing" rule.)
    private var staleLine: some View {
        Ticking(coarse: true) { now in
            VStack(spacing: 0) {
                if let checked = store.ciFreshness, now.timeIntervalSince(checked) > store.settings.pollInterval * 3 {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Metrics.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                }
            }
        }
    }

    /// Along the top and bottom, and focused: its header, then the rows, in their own column (the strip's cell stays
    /// above). While another section is focused the header is in the strip instead (`stripShowsCIHeader`).
    var ciColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsCI {
                ciHeader
                ciRows
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if ciHeight != $0 { ciHeight = $0 } }
    }

    /// The strip's CI segment names its section only when the column under it doesn't.
    var stripShowsCIHeader: Bool { hub.focus != nil && hub.focus != .ci }
}

/// CI in the bar: one glyph, the worst state that isn't muted, centred on the bar's axis. The number of failing repos
/// sits under it, only when some fail, and over two digits reads "9+": the glyph never moves with the count.
struct CICell: View {
    let store: Store

    /// What the cell shows of how many fail: the number, or "9+" so two digits never reach the screen's edge.
    static func count(_ failing: Int) -> String { failing > 9 ? "9+" : "\(failing)" }

    var body: some View {
        if !store.ciRepos.isEmpty {
            let worst = store.ciWorst
            Button { store.openWorstChecks() } label: {
                Image(systemName: worst.state.symbol)
                    .font(Theme.Typography.glyph(16, worst.state == .failure ? .semibold : .regular))
                    .foregroundStyle(worst.state.color)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Theme.Metrics.pitch, height: Theme.Metrics.pitch)
                    .overlay(alignment: .bottom) {
                        if worst.failing > 0 {
                            Text(Self.count(worst.failing)).font(Theme.Typography.numeral).foregroundStyle(Theme.red)
                                .contentTransition(.numericText(value: Double(worst.failing)))
                                .offset(y: 2)
                        }
                    }
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

    /// The pointer entering or leaving a row: while it is over it the row is what the keys act on; leaving gives that
    /// up, unless the keyboard is the one that picked it (DESIGN.md 3.5).
    func pointer(_ inside: Bool, over target: String, ui: UIState) {
        if inside {
            selection = target
            ui.drawerSelection = nil
        } else if selection == target, keyboardSelection?.id != target {
            selection = nil
        }
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

    /// The pick was a CI row that is no longer a target: a pick made with the keyboard moves to the row now in its
    /// place (the one before it, at the end), a pointer's goes with the pointer.
    func rehomeCI(from old: [String], to new: [String]) {
        guard let gone = selection, gone.hasPrefix("c:"), !new.contains(gone) else { return }
        guard keyboardSelection?.id == gone, !new.isEmpty else {
            selection = nil
            if keyboardSelection?.id == gone { keyboardSelection = nil }
            return
        }
        let next = new[min(old.firstIndex(of: gone) ?? 0, new.count - 1)]
        selection = next
        requestScroll(next)
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
