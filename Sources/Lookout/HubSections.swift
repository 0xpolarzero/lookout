import AppKit
import SwiftUI

// The hub's sections: what goes in the bar's cells and beside them.
//
// One set of measures for every piece, so the sections read as one surface:
// - section headers are 30pt: title 12 semibold secondary, then a status in its state's colour, trailing actions
//   as header-size (24) IconButtons;
// - rows pad their content 8 × 6 inside a 9pt continuous rounded fill (white 0.06 on hover or when picked);
//   the layout adds the one outer inset, so nothing here pads itself from the outside;
// - every control has a tooltip: a verb phrase, then what it does and its shortcut, read from the user's settings.

extension LookoutHub {
    // MARK: Inbox

    var inboxIcon: some View {
        InboxCell(needsYou: store.unreadCount(.needsYou), bots: store.unreadCount(.bots), vertical: !edge.isHorizontal,
                  showsCount: !(showsDetail && !shrunk(.inbox))) {
            // Straight to what needs you, its newest item picked so the keys act on it at once.
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) {
                hub.go(.main)
                hub.endSearch()
                hub.filter = .needsYou
            }
            if let first = store.list(.needsYou).first {
                hub.selection = "i:" + first.id
                hub.requestScroll("i:" + first.id)
                ui.drawerSelection = nil
            }
        }
    }

    /// The filter chips are the inbox's title and status; typing swaps them for the search.
    @ViewBuilder var inboxHeader: some View {
        Group {
            if searching || hub.searchOpen { searchField.transition(.opacity) } else { filters.transition(.opacity) }
        }
        .frame(height: Theme.Metrics.line)
    }

    var searchField: some View {
        InboxSearchField(hub: hub, ui: ui, store: store, count: searchCount)
    }

    /// What the search found, by kind: "3 items · 2 sessions".
    var searchCount: String {
        let found = items.count
        let sessions = store.agents.enabled ? store.hubSessions(hub).count : 0
        if found == 0 && sessions == 0 { return "No match" }
        return [found == 0 ? nil : plural(found, "item"), sessions == 0 ? nil : plural(sessions, "session")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var filters: some View {
        HStack(spacing: 4) {
            // The tabs never give up their words: the actions after them are what yields when the column is narrow.
            ForEach(InboxFilter.allCases, id: \.self) { f in filterChip(f).fixedSize().layoutPriority(2) }
            Spacer(minLength: 0)
            if hub.filter != .done && store.unreadCount(hub.filter) > 0 {
                IconButton(symbol: "checkmark.circle", help: "Mark all as read",
                           detail: "Everything in \(hub.filter.label) · \(store.shortcut(.markAllRead).display)",
                           size: IconButton.Size.header) {
                    withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { store.markAllRead(hub.filter) }
                }
                .transition(.opacity)
            }
            if showsDetail { focusButton(.inbox) }
        }
        .padding(.trailing, 3)
        .motion(Theme.Motion.fade, value: store.unreadCount(hub.filter) > 0)
    }

    func filterChip(_ f: InboxFilter) -> some View {
        // Unread, like the count in the bar beside it; none once everything's been seen.
        let unread = store.unreadCount(f)
        let count: Int? = f == .done || unread == 0 ? nil : unread
        let detail = switch f {
        case .needsYou: "Reviews, mentions and replies from people"
        case .bots: "Comments from bots, kept quiet"
        case .done: "What you marked Done · Back to inbox from here"
        }
        return Chip(label: f.label, count: count, selected: hub.filter == f) {
            withAnimation(Theme.Motion.fade.resolved(reduce: reduce)) { hub.filter = f }
        }
        .tip(f.label, detail)
    }

    var emptyInbox: some View {
        HStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : hub.filter == .needsYou ? "checkmark.circle.fill" : "tray")
                .font(Theme.Typography.glyph(12))
                .foregroundStyle(hub.filter == .needsYou && !searching ? Theme.green : Theme.tertiary)
                .accessibilityHidden(true)
            Text(searching ? "No inbox item matches" : hub.filter == .needsYou ? "All caught up"
                 : hub.filter == .bots ? "Bots are quiet" : "Nothing here yet")
                .font(Theme.Typography.body).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }

    func itemRow(_ item: InboxItem) -> some View {
        CompactItemRow(item: item, store: store, ui: ui, hub: hub).capEdge()
    }

    /// A line of text with a link after it, padded like a row ("No CI shown  Choose repositories").
    func linkRow(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(Theme.tertiary)
            Button(action, action: perform).buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.control)
        .padding(.horizontal, Theme.Space.md)
        .frame(minHeight: Theme.Metrics.line)
    }

    // MARK: Section headers

    /// A section's header: its title and status on the left, its actions on the right; 30pt tall.
    func sectionHeader<Trailing: View>(_ title: String, status: [(String, Color)] = [],
                                       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Typography.heading).foregroundStyle(Theme.secondary).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(status.enumerated()), id: \.offset) { _, part in
                Text(part.0).font(Theme.Typography.meta.monospacedDigit()).foregroundStyle(part.1).lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, Theme.Space.md)
        .padding(.trailing, 3)
        .frame(height: Theme.Metrics.line)
        .motion(Theme.Motion.fade, value: status.map(\.0))
    }

    // MARK: CI

    /// One order for CI everywhere: what needs attention first.
    static let ciOrder: [CIState] = [.failure, .pending, .success]
    /// `ciOrder`, then the repos without a run: for the lines that list repos (the bar's counts keep `ciOrder`).
    /// Repo chips on one CI line before the rest fold into "+N".
    static let ciChipLimit = 4
    static let ciLineOrder: [CIState] = ciOrder + [.none]

    /// The repos in a CI state; `.none` is the ones with no run (nothing known yet, or no checks).
    func ciRepos(listedIn state: CIState) -> [RepoConfig] {
        Self.ciRepos(listedIn: state, in: store.ciRepos, status: store.ci)
    }

    /// Pure form of `ciRepos(listedIn:)`: a repo with no status at all, or one stored as `CIState.none`, is "no runs".
    static func ciRepos(listedIn state: CIState, in repos: [RepoConfig], status: [String: CIStatus]) -> [RepoConfig] {
        repos.filter { (status[$0.fullName]?.state ?? CIState.none) == state }
    }

    /// CI's icon in the bar, tinted by the worst state; hovering lists the repos in each.
    var ciCell: some View {
        let worst = store.worstCI
        let counts = Self.ciOrder.compactMap { state -> String? in
            let n = ciRepos(listedIn: state).count
            return n == 0 ? nil : "\(n) \(state.label)"
        }
        return Image(systemName: worst == .failure ? "xmark.seal.fill" : "checkmark.seal.fill")
            .font(Theme.Typography.glyph(15))
            .foregroundStyle(worst == CIState.none ? Theme.tertiary : worst.color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Theme.Metrics.line, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CI: \(worst == CIState.none ? "no runs" : worst.label)")
            .accessibilityValue(counts.joined(separator: ", "))
    }

    /// CI's section header: "CI" and how it's going, worst first.
    var ciHeader: some View {
        // Shrunk (another section focused), its lines are gone: every state's count, in its colour.
        let status: [(String, Color)] = shrunk(.ci)
            ? Self.ciOrder.compactMap { state in
                let n = ciRepos(listedIn: state).count
                return n == 0 ? nil : ("\(n) \(state.label)", state.color)
            } + (ciRepos(listedIn: .none).isEmpty ? [] : [("\(ciRepos(listedIn: .none).count) no runs", CIState.none.color)])
            : ciStatus.map { [$0] } ?? []
        return sectionHeader("CI", status: status) { if showsDetail { focusButton(.ci) } }
    }

    /// "2 failing" in red; "1 running" while nothing fails but something runs; "all passing" once everything has.
    var ciStatus: (String, Color)? {
        let failing = ciRepos(listedIn: .failure).count
        let running = ciRepos(listedIn: .pending).count
        let passing = ciRepos(listedIn: .success).count
        if failing > 0 { return ("\(failing) failing", Theme.red) }
        if running > 0 { return ("\(running) running", Theme.amber) }
        // "All" only when every repo shown has passed; some without a run yet make it a count.
        if passing > 0 { return (ciRepos(listedIn: CIState.none).isEmpty ? "all passing" : "\(passing) passing", Theme.tertiary) }
        return store.ciRepos.isEmpty ? nil : ("no runs", Theme.tertiary)
    }

    /// The number of repos in a CI state, beside its line; hovering lists them.
    func ciCount(_ state: CIState) -> some View {
        let n = ciRepos(listedIn: state).count
        return DotCount(n, color: state.color)
            .frame(width: 32, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(n) \(state.label)")
    }

    /// The repos in a CI state, as chips that open their checks.
    /// `compact`: along the top and bottom, where lines don't have to match the bar's cells.
    func ciLine(_ state: CIState, compact: Bool = false) -> some View {
        let repos = ciRepos(listedIn: state)
        // Repos without a run only get a line when there are some.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state == CIState.none ? "No runs" : state.title)
                .font(Theme.Typography.count)
                .foregroundStyle(repos.isEmpty ? Theme.tertiary : state.color)
                .frame(width: 52, alignment: .leading)
            if repos.isEmpty {
                Text("—").font(Theme.Typography.meta).foregroundStyle(Theme.tertiary)
            } else {
                // A few chips, then "+N": a line never grows with the number of repos (it'd push the hub off the screen).
                FlowLayout(spacing: 5) {
                    ForEach(repos.prefix(Self.ciChipLimit), id: \.fullName) { repo in
                        RepoChip(repo: repo, status: store.ci[repo.fullName], state: state) { store.openChecks(repo) }
                    }
                    if repos.count > Self.ciChipLimit {
                        let rest = repos.dropFirst(Self.ciChipLimit)
                        Text("+\(rest.count)").font(Theme.Typography.control).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).frame(height: 22)
                            .accessibilityLabel("\(rest.count) more")
                            .tip("\(rest.count) more", rest.map(\.fullName).joined(separator: "\n"))
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, compact ? 1 : Theme.Space.xs)
        .frame(maxWidth: .infinity, minHeight: compact ? 24 : Theme.Metrics.line, alignment: .leading)
    }

    // MARK: Agents

    var claudeMark: some View {
        Image(systemName: "asterisk")
            .font(Theme.Typography.glyph(14, .bold))
            .foregroundStyle(Theme.claude)
            .frame(width: Theme.Metrics.line, height: Theme.Metrics.line)
            .contentShape(Rectangle())
            .accessibilityLabel("Sessions")
    }

    /// "Sessions", then what's waiting for you (amber) and what's done and unread (blue).
    var agentsHeader: some View {
        let counts = store.agentCounts
        var status: [(String, Color)] = []
        if counts.blocked > 0 { status.append(("\(counts.blocked) waiting", Theme.amber)) }
        if counts.done > 0 { status.append(("\(counts.done) done", Theme.accent)) }
        // Claude's files missing or unreadable: the notice under the header says so; this stays when the list is shrunk.
        switch store.claudeLink {
        case .missing, .unreadable: status.append(("!", Theme.red))
        default: break
        }
        return sectionHeader("Sessions", status: status) { if showsDetail { focusButton(.agents) } }
    }

    /// A session's tile in the bar; opens it in Claude.
    func tile(_ r: AgentRow, size: CGFloat) -> some View {
        BarTile(row: r, size: size, store: store, ui: ui, hub: hub)
    }

    /// The "+" in the bar, a tile like the sessions' above it: a scratch session.
    var newSessionCell: some View {
        NewSessionTile(size: Theme.Metrics.chip) { store.startScratchSession() }
            .frame(height: Theme.Metrics.row)
    }

    /// Beside the "+": the label and the projects to start a session in.
    var newSessionDetail: some View { NewSessionRow(store: store, style: .detail) }

    // MARK: Bar actions

    var pinButton: some View {
        IconButton(symbol: hub.pinned ? "pin.fill" : "pin", help: hub.pinned ? "Unpin" : "Keep open",
                   detail: store.shortcut(.togglePanel).display,
                   size: IconButton.Size.bar, tint: hub.pinned ? Theme.amber : Theme.secondary, active: hub.pinned) {
            hub.pinned.toggle()
        }
    }

    var reposButton: some View {
        IconButton(symbol: "square.stack.3d.up.fill", help: "Repositories", detail: "Watched repos and what they notify",
                   size: IconButton.Size.bar, active: hub.page == .repos) { hub.go(.repos) }
    }

    /// Lit on Settings; on Repositories too beside the bar, where the repositories button hides with the rows.
    var settingsCell: some View {
        IconButton(symbol: "gearshape.fill", help: "Settings", detail: "⌘,", size: IconButton.Size.bar,
                   active: hub.page == .settings || (hub.page == .repos && !edge.isHorizontal)) { hub.go(.settings) }
    }

    // MARK: Footer

    /// Beside the settings cell: how syncing is going, then pin and repositories.
    var footer: some View {
        // 9pt apart: the same step as from repositories to the settings cell beside them.
        HStack(spacing: 9) {
            syncStatus
            Spacer(minLength: 0)
            pinButton
            reposButton
        }
        .frame(height: 40)
    }

    /// Sync state, as a dot and a few words: problems first, then checking, snoozed, and up to date.
    var syncStatus: some View {
        HStack(spacing: 8) {
            Ticking(coarse: true) { now in
                syncLabel(now: now)
            }
            // The rate limit is part of syncing: it pauses at 0, inbox included.
            RateNotice(store: store, fill: false).lineLimit(1).layoutPriority(-1)
        }
    }

    private func syncLabel(now: Date) -> some View {
        let s = sync(now: now)
        return Button {
            if store.authError != nil { hub.go(.settings) } else { store.refreshNow() }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if s.spinning {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                    } else if let symbol = s.symbol {
                        Image(systemName: symbol).font(Theme.Typography.glyph(9, .bold)).foregroundStyle(s.color)
                    } else {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 10, height: 10)
                Text(s.text).font(Theme.Typography.meta).foregroundStyle(s.color == Theme.green ? Theme.tertiary : s.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.Metrics.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.text)
        .accessibilityHint(s.title)
        .disabled(store.isSyncing)
        .tip(s.title, s.detail)
    }

    private struct SyncState {
        var color: Color
        var text: String
        var title: String
        var detail: String?
        var symbol: String? = nil
        var spinning = false
    }

    private func sync(now: Date) -> SyncState {
        let refresh = "Click to check now · \(store.shortcut(.refresh).display)"
        if let error = store.authError {
            return SyncState(color: Theme.red, text: "Sign-in problem", title: "Can't sign in to GitHub",
                             detail: error + "\nClick for Settings")
        }
        if store.unreachable {
            return SyncState(color: Theme.amber, text: "Not syncing", title: "Couldn't reach GitHub",
                             detail: "Check your connection · Lookout tries again on its own\n" + refresh)
        }
        let failed = store.repoErrors.keys.sorted()
        if !failed.isEmpty {
            return SyncState(color: Theme.amber, text: "\(plural(failed.count, "repo")) failed",
                             title: "Some repositories didn't sync", detail: failed.joined(separator: "\n") + "\n" + refresh)
        }
        if store.isSyncing {
            return SyncState(color: Theme.tertiary, text: "Checking…", title: "Checking GitHub",
                             detail: "Repositories, CI and review requests", spinning: true)
        }
        guard let last = store.lastSync else {
            return SyncState(color: Theme.tertiary, text: store.me == nil ? "Connecting…" : "Not checked yet",
                             title: "Connecting to GitHub", detail: nil)
        }
        let interval = store.settings.pollInterval
        let checked = "Last checked at \(last.formatted(date: .omitted, time: .shortened))"
        if now.timeIntervalSince(last) > interval * 3 {
            return SyncState(color: Theme.amber, text: "Synced \(agoPhrase(last, now: now))", title: "Not syncing",
                             detail: "\(checked) · check your connection or token\n" + refresh)
        }
        if store.isSnoozed, let until = store.settings.snoozeUntil {
            return SyncState(color: Theme.purple, text: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))",
                             title: "Notifications snoozed", detail: "No banners; the inbox keeps filling · resume in Settings",
                             symbol: "moon.fill")
        }
        let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
        return SyncState(color: Theme.green, text: "Up to date", title: checked,
                         detail: "Next check in about \(next < 60 ? "\(next)s" : "\(next / 60)m")\n\(refresh)")
    }
}

/// The search: a real text field (paste, selection, dead keys and input methods work, and VoiceOver reads it), with what it
/// found and the Esc that ends it. Typing elsewhere in the hub opens it and hands it the key (see `HubKeys`), which
/// leaves it alone while it has focus.
struct InboxSearchField: View {
    @Bindable var hub: HubState
    let ui: UIState
    let store: Store
    let count: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(Theme.Typography.glyph(12)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            TextField("Search inbox and sessions", text: $hub.query,
                      prompt: Text("Search inbox and sessions").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.Typography.title.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .accessibilityLabel("Search inbox and sessions")
                .focused($focused)
                .focusEffectDisabled()
            if !hub.query.isEmpty {
                Text(count).font(Theme.Typography.meta.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            KeyCap("Esc")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: Theme.Metrics.line)
        .background(Theme.Radius.shape(Theme.Radius.md).fill(Theme.Fill.field))
        .onAppear { requestFocus() }
        .onChange(of: hub.focusRequest) { requestFocus() }
        .onChange(of: focused) { _, isFocused in
            hub.searchFocused = isFocused
            if isFocused { DispatchQueue.main.async(execute: hub.typePendingKeys) }
        }
        .onDisappear { hub.searchFocused = false }
        // What is typed, pasted or composed in the field doesn't go through the keys: the first result is picked like theirs,
        // and nothing stays shrunk behind the results.
        .onChange(of: hub.query) {
            if !hub.query.isEmpty, hub.focus != nil {
                withAnimation(LookoutHub.refocus.resolved(reduce: LookoutHub.reduceNow)) { hub.focus = nil }
            }
            hub.pick(store.hubTargets(hub).first, ui: ui)
        }
    }

    private func requestFocus() {
        DispatchQueue.main.async {
            focused = true
            // Already focused (a key arrived while it was): nothing changes for `onChange` to answer.
            DispatchQueue.main.async(execute: hub.typePendingKeys)
        }
    }
}
