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
        // A repository nobody has answered for isn't "no runs": that is for a successful answer that found none.
        var parts = [entry.checked ? entry.state.voice : "not checked"]
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
            (list.quietCounts.noRuns, CIState.none.label),
            (list.quietCounts.unchecked, "not checked"),
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
                    .foregroundStyle(entry.state == .failure ? resolved.red : entry.state.color(resolved))
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
        .focusable(false)
        .accessibilityLabel(title)
        .accessibilityValue(CISpeech.value(entry, now: now))
        .accessibilityHint([headline, "Opens its checks. More actions available."].filter { !$0.isEmpty }.joined(separator: ". "))
        .help(tooltip)
        // The keyboard's pick shows what a tooltip would (the failing checks and the headline are cut to one line).
        .tip(title, tipDetail, focused: selected && hub.keyboardSelection?.id == "c:" + entry.id, hover: false)
        .ciActions(entry, store: store)
        .rowMenuTarget("c:" + entry.id, hub: hub)
        .voiceOverTarget("c:" + entry.id, hub: hub)
        .onHover { hover = $0; hub.pointer($0, over: "c:" + entry.id, ui: ui) }
    }

    /// The commit's headline, for VoiceOver: the row shows it cut to a line, or not at all when the failed checks take it.
    private var headline: String { entry.status?.title ?? "" }

    /// What the tooltip says under the repository.
    private var tipDetail: String? {
        let lines = tooltip.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map(String.init)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        let (passing, muted, noRuns, _) = list.quietCounts
        return passing > 0 || list.allPassing ? CIState.success.symbol : muted > 0 ? "bell.slash" : noRuns > 0 ? CIState.none.symbol : "questionmark.circle"
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
        .focusable(false)
        .accessibilityLabel(list.quietName)
        .accessibilityValue("\(list.quietSpeech), \(open ? "expanded" : "collapsed")")
        .accessibilityHint(open ? "Hides the repositories" : "Lists the repositories")
        .voiceOverTarget("c:passing", hub: hub)
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
    private var note: String? { entry.muted ? "\(entry.state.label), muted" : !entry.checked ? "not checked" : entry.state == .none ? "no runs" : nil }

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
                HStack(spacing: 0) {
                    Text(title).font(Theme.Typography.body).foregroundStyle(entry.muted ? Theme.tertiary : Theme.secondary).lineLimit(1)
                    if let note { Text(" · " + note).font(Theme.Typography.meta).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize() }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Metrics.menuRow - 12, alignment: .leading)
            .rowHighlight(hover: hover, picked: selected && !hover)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(title)
        .accessibilityValue(CISpeech.value(entry, now: now))
        .accessibilityHint("Opens its checks. More actions available.")
        .ciActions(entry, store: store)
        .rowMenuTarget("c:" + entry.id, hub: hub)
        .voiceOverTarget("c:" + entry.id, hub: hub)
        .onHover { hover = $0; hub.pointer($0, over: "c:" + entry.id, ui: ui) }
    }
}

// MARK: - The section

extension LookoutHub {
    /// While searching, the results are the inbox and the sessions: CI leaves the layout (it isn't dimmed).
    var showsCI: Bool { !searching }

    /// CI's section header: "CI", and one phrase only when something is not green.
    var ciHeader: some View {
        let focused = hub.focus == .ci
        let toggle: (() -> Void)? = showsDetail && !store.ciRepos.isEmpty ? {
            withAnimation(Self.refocus.resolved(reduce: reduce)) { hub.focus = focused ? nil : .ci }
        } : nil
        return SectionHeader(title: "CI", status: ciPhrase, focused: focused, expandHelp: focused ? "Back to all sections" : "Expand CI",
                             onFocus: toggle) {}
            .voiceOverTarget("h:ci", hub: hub)
    }

    /// "2 failing" in red; "1 running" while nothing fails; nothing once everything has passed. Only while CI is just its
    /// header (`ciIsHeaderOnly`): with its rows showing, the failing ones say it (DESIGN.md 10.5).
    var ciPhrase: (text: String, color: AnyShapeStyle)? {
        guard ciIsHeaderOnly else { return nil }
        let worst = store.ciWorst
        switch worst.state {
        case .failure: return ("\(worst.failing) failing", AnyShapeStyle(Theme.red))
        case .pending: return ("\(store.ciList.attention.count) running", AnyShapeStyle(Theme.secondary))
        default: return nil
        }
    }

    /// The rows under the header: one per failing or running repo, then the Passing row (open in place on request),
    /// all in one list that scrolls within `cap` (`ciCap` unless a panel says), ending between rows (each marks its
    /// edge). A peek (`peek`) never scrolls: it lists the whole rows within `cap`, and "+N more" keeps the hub open on
    /// CI. Without any CI, one calm line with the way to turn it on.
    func ciRows(cap: CGFloat? = nil, peek: Bool = false) -> some View {
        let list = store.ciList
        let undo = store.undoStack.visible(in: .ci)
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                noCI
            } else {
                staleLine
                if peek {
                    // The stale line and the undo line are in the peek's room too.
                    let room = (cap ?? ciCap) - (staleChecked(Date()) == nil ? 0 : Self.staleHeight)
                        - (undo == nil ? 0 : Theme.Metrics.undoLine + Theme.Space.xs)
                    ciPeekRows(list, cap: room)
                } else {
                    CappedScroll(cap: cap ?? ciCap, hub: hub, cue: MoreCue(noun: "repository")) { ciListRows(list) }
                }
            }
            if let undo {
                UndoLine(message: undo.message) { store.undoLast() }.padding(.top, Theme.Space.xs)
            }
        }
        .motion(Theme.Motion.fade, value: list.entries.map { "\($0.id) \($0.state.rawValue) \($0.muted)" })
        .motion(Theme.Motion.fade, value: store.undoStack.visibleID)
        // A pick on a row that left the list (it passed, was muted, lost its CI) moves on instead of lingering.
        .onChange(of: hub.ciTargets(store)) { old, new in hub.rehomeCI(from: old, to: new) }
    }

    /// A line of the list: a failing or running repo, the Passing row, or (Passing open) a quiet repo.
    private struct CIListLine: Identifiable {
        enum Kind { case attention, passing, quiet }
        let kind: Kind
        let entry: CIEntry?
        var id: String { "c:" + (entry?.id ?? "passing") }

        var height: CGFloat {
            switch kind {
            case .attention: Theme.Metrics.twoLineRow
            case .passing: Theme.Metrics.pitch
            case .quiet: Theme.Metrics.menuRow
            }
        }
    }

    /// The lines in the order they are listed.
    private func ciLines(_ list: CIList, open: Bool) -> [CIListLine] {
        list.attention.map { CIListLine(kind: .attention, entry: $0) }
            + (list.quiet.isEmpty ? [] : [CIListLine(kind: .passing, entry: nil)])
            + (open ? list.quiet.map { CIListLine(kind: .quiet, entry: $0) } : [])
    }

    private func ciListRows(_ list: CIList, lines: ArraySlice<CIListLine>? = nil, marked: Bool = true) -> some View {
        let open = hub.ciPassingOpen || hub.focus == .ci
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines ?? ciLines(list, open: open)[...]) { line in
                Group {
                    switch line.kind {
                    case .attention:
                        CIRow(entry: line.entry!, title: list.title(line.entry!.repo), store: store, ui: ui, hub: hub)
                    case .passing:
                        CIQuietRow(list: list, open: open, ui: ui, hub: hub) { hub.setCIPassingOpen(!open) }
                    case .quiet:
                        CINameRow(entry: line.entry!, title: list.title(line.entry!.repo), store: store, ui: ui, hub: hub)
                            .transition(.opacity)
                    }
                }
                .modifier(CapEdgeIf(marked: marked))
                .id(line.id)
            }
        }
    }

    /// A peek's rows: the whole lines that fit `cap`, and under them how many repositories are left. A closed Passing
    /// row stands for its repositories, an open one for none (they follow it).
    private func ciPeekRows(_ list: CIList, cap: CGFloat) -> some View {
        let open = hub.ciPassingOpen || hub.focus == .ci
        let lines = ciLines(list, open: open)
        let shown = PeekCut.shown(lines.map(\.height), cap: cap)
        let hidden = lines.dropFirst(shown).reduce(0) { sum, line in
            sum + (line.kind == .passing ? (open ? 0 : list.quiet.count) : 1)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ciListRows(list, lines: lines.prefix(shown), marked: false)
            if hidden > 0 {
                MoreRow(text: "+\(hidden) more", label: plural(hidden, "more repository"), hint: "Keeps Lookout open to show them") {
                    hub.showAll(.ci)
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
        if hub.focus == .ci {
            // What the other headers, the footer and CI's own stale and undo lines leave of the screen's length.
            let extras = (staleChecked(Date()) == nil ? 0 : Self.staleHeight) + ciUndoRoom
            let free = edge.isHorizontal
                ? HubGeometry.stripRoom(maxLength: maxLength) - Theme.Metrics.pitch * (store.agents.enabled ? 2 : 1)
                : fullLength - fixedLength(ciBody: 0)
            return max(row, free - extras)
        }
        return max(4 * row, (maxLength - 210) * 0.45)
    }

    /// Nothing watched has CI on: one line aligned with the glyph column, and where to turn it on.
    var noCI: some View {
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
                if let checked = staleChecked(now) {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, Theme.Metrics.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: Self.staleHeight, alignment: .leading)
                }
            }
        }
    }

    private static let staleHeight: CGFloat = 20

    /// When CI was last checked, if that is too long ago to call the rows fresh.
    private func staleChecked(_ now: Date) -> Date? {
        guard let checked = store.ciFreshness, now.timeIntervalSince(checked) > store.settings.pollInterval * 3 else { return nil }
        return checked
    }
}

/// A row of a list that scrolls marks its bottom edge; a peek's, which never does, needs no mark.
private struct CapEdgeIf: ViewModifier {
    let marked: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if marked { content.capEdge() } else { content }
    }
}

// MARK: - Keys

extension HubState {
    /// The bar's CI cell, shown (VoiceOver's Show): the hub stays open on CI, with its first row picked and VoiceOver's
    /// focus moved to its header. Another section's focus, or a search, would hide the rows, so they step back.
    func showCI(_ store: Store, ui: UIState) {
        pinned = true
        if !query.isEmpty { query = "" }
        if focus != nil, focus != .ci { LookoutHub.animate(LookoutHub.refocus) { focus = nil } }
        if let first = ciTargets(store).first {
            selection = first
            ui.drawerSelection = nil
            requestScroll(first)
        }
        moveVoiceOver(to: "h:ci")
    }

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
        guard query.isEmpty, focus == nil || focus == .ci, !ciFolded else { return [] }
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
        // What is bound comes first, an arrow bound to Open included: its own meaning below is for the arrow left unbound.
        if shortcut == store.shortcut(.openItem) {
            if id == "passing" { hub.setCIPassingOpen(!open) } else if let repo { store.openChecks(repo) }
            return true
        }
        if flags.isEmpty, event.keyCode == 124 || event.keyCode == 123 {
            guard !isBound(shortcut) else { return false }
            // → opens it from its row; ← closes it from there or from a name under it, back on its row.
            if event.keyCode == 124, id == "passing", !open { hub.setCIPassingOpen(true); return true }
            if event.keyCode == 123, open, hub.focus != .ci { hub.setCIPassingOpen(false); select("c:passing"); return true }
            return false
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c", let repo {
            store.copyChecksURL(repo)
            return true
        }
        return false
    }
}
