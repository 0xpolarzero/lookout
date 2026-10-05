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
            withAnimation(.easeOut(duration: 0.18)) {
                hub.go(.main)
                hub.query = ""
                hub.filter = .needsYou
            }
            if let first = store.list(.needsYou).first {
                hub.selection = "i:" + first.id
                ui.drawerSelection = nil
            }
        }
    }

    /// The filter chips are the inbox's title and status; typing swaps them for the search.
    @ViewBuilder var inboxHeader: some View {
        Group {
            if searching { searchField.transition(.opacity) } else { filters.transition(.opacity) }
        }
        .frame(height: 30)
    }

    var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            HStack(spacing: 1) {
                Text(hub.query).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Caret()
            }
            Spacer(minLength: 0)
            Text(searchCount).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
            KeyCap("Esc")
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// What the search found, by kind: "3 items · 2 sessions".
    var searchCount: String {
        let found = items.count
        let sessions = store.agents.enabled ? store.hubSessions(hub).count : 0
        if found == 0 && sessions == 0 { return "No match" }
        func plural(_ n: Int, _ word: String) -> String? { n == 0 ? nil : "\(n) \(word)\(n == 1 ? "" : "s")" }
        return [plural(found, "item"), plural(sessions, "session")].compactMap { $0 }.joined(separator: " · ")
    }

    var filters: some View {
        HStack(spacing: 4) {
            ForEach(InboxFilter.allCases, id: \.self) { f in filterChip(f) }
            Spacer(minLength: 0)
            if hub.filter != .done && store.unreadCount(hub.filter) > 0 {
                IconButton(symbol: "checkmark.circle", help: "Mark all as read",
                           detail: "Everything in \(hub.filter.label) · \(store.shortcut(.markAllRead).display)",
                           size: IconButton.Size.header) {
                    withAnimation(.easeOut(duration: 0.2)) { store.markAllRead(hub.filter) }
                }
                .transition(.opacity)
            }
            if showsDetail { focusButton(.inbox) }
        }
        .padding(.trailing, 3)
        .animation(.easeOut(duration: 0.15), value: store.unreadCount(hub.filter) > 0)
    }

    func filterChip(_ f: InboxFilter) -> some View {
        // Unread, like the count in the bar beside it; none once everything's been seen.
        let unread = store.unreadCount(f)
        let count: Int? = f == .done || unread == 0 ? nil : unread
        let detail = switch f {
        case .needsYou: "Reviews, mentions and replies from people"
        case .bots: "Comments from bots, kept quiet"
        case .done: "What you marked done · back to the inbox from here"
        }
        return Chip(label: f.label, count: count, selected: hub.filter == f) {
            withAnimation(.easeOut(duration: 0.18)) { hub.filter = f }
        }
        .tip(f.label, detail)
    }

    var emptyInbox: some View {
        HStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : hub.filter == .needsYou ? "checkmark.circle.fill" : "tray")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hub.filter == .needsYou && !searching ? Theme.green : Theme.tertiary)
            Text(searching ? "No inbox item matches" : hub.filter == .needsYou ? "All caught up"
                 : hub.filter == .bots ? "Bots are quiet" : "Nothing here yet")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    func itemRow(_ item: InboxItem) -> some View {
        CompactItemRow(item: item, store: store, selected: hub.selection == "i:" + item.id, low: hub.filter == .bots) {
            hub.selection = "i:" + item.id
            ui.drawerSelection = nil
        }
    }

    func moreButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A line of text with a link after it, padded like a row ("No CI shown  Choose repositories").
    func linkRow(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(Theme.tertiary)
            Button(action, action: perform).buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
    }

    // MARK: Section headers

    /// A section's header: its title and status on the left, its actions on the right; 30pt tall.
    func sectionHeader<Trailing: View>(_ title: String, status: [(String, Color)] = [],
                                       @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            ForEach(Array(status.enumerated()), id: \.offset) { _, part in
                Text(part.0).font(.system(size: 11).monospacedDigit()).foregroundStyle(part.1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 30)
        .animation(.easeOut(duration: 0.15), value: status.map(\.0))
    }

    // MARK: CI

    /// One order for CI everywhere: what needs attention first.
    static let ciOrder: [CIState] = [.failure, .pending, .success]

    /// CI's icon in the bar, tinted by the worst state; hovering lists the repos in each.
    var ciCell: some View {
        let worst = store.worstCI
        return Image(systemName: worst == .failure ? "xmark.seal.fill" : "checkmark.seal.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(worst == .none ? Theme.tertiary : worst.color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    /// CI's section header: "CI" and how it's going, worst first.
    var ciHeader: some View {
        // Shrunk (another section focused), its lines are gone: every state's count, in its colour.
        let status: [(String, Color)] = shrunk(.ci)
            ? Self.ciOrder.compactMap { state in
                let n = store.ciRepos(in: state).count
                return n == 0 ? nil : ("\(n) \(state.label)", state.color)
            }
            : ciStatus.map { [$0] } ?? []
        return sectionHeader("CI", status: status) { if showsDetail { focusButton(.ci) } }
    }

    /// "2 failing" in red; "1 running" while nothing fails but something runs; "all passing" once everything has.
    var ciStatus: (String, Color)? {
        let failing = store.ciRepos(in: .failure).count
        let running = store.ciRepos(in: .pending).count
        let passing = store.ciRepos(in: .success).count
        if failing > 0 { return ("\(failing) failing", Theme.red) }
        if running > 0 { return ("\(running) running", Theme.amber) }
        if passing > 0 { return ("all passing", Theme.tertiary) }
        return store.ciRepos.isEmpty ? nil : ("no runs yet", Theme.tertiary)
    }

    /// The number of repos in a CI state, beside its line; hovering lists them.
    func ciCount(_ state: CIState) -> some View {
        let n = store.ciRepos(in: state).count
        return HStack(spacing: 5) {
            CIDot(state: n == 0 ? .none : state, size: 7)
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(n == 0 ? Theme.tertiary : Theme.text)
                .contentTransition(.numericText(value: Double(n)))
        }
        .frame(width: 32, height: 30)
        .contentShape(Rectangle())
    }

    /// The repos in a CI state, as chips that open their checks.
    func ciLine(_ state: CIState) -> some View {
        let repos = store.ciRepos(in: state)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(repos.isEmpty ? Theme.tertiary : state.color)
                .frame(width: 52, alignment: .leading)
            if repos.isEmpty {
                Text("—").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(repos, id: \.fullName) { repo in
                        RepoChip(repo: repo, status: store.ci[repo.fullName], state: state) { store.openChecks(repo) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    // MARK: Agents

    var claudeMark: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.claude)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    var agentsCell: some View { claudeMark }

    /// "Agents", then what's waiting for you (amber) and what's done and unread (blue).
    var agentsHeader: some View {
        let counts = store.agentCounts
        var status: [(String, Color)] = []
        if counts.blocked > 0 { status.append(("\(counts.blocked) waiting", Theme.amber)) }
        if counts.done > 0 { status.append(("\(counts.done) done", Theme.accent)) }
        return sectionHeader("Agents", status: status) { if showsDetail { focusButton(.agents) } }
    }

    /// A session's tile in the bar; opens it in Claude. Collapsed, it says which session it is.
    @ViewBuilder func tile(_ r: AgentRow, size: CGFloat) -> some View {
        let button = Button { store.openAgent(r.id) } label: {
            AgentTile(row: r, size: size, selected: hub.selection == "a:" + r.id)
        }
        .buttonStyle(.plain)
        .frame(height: 36)
        .onHover { if $0 { hub.selection = "a:" + r.id; ui.drawerSelection = r.id } }
        // No tooltip: hovering opens the sessions' panel, a row beside each tile.
        button
    }

    /// The "+" in the bar, a tile like the sessions' above it: a scratch session.
    var newSessionCell: some View {
        NewSessionTile(size: 26) { store.startScratchSession() }
            .frame(height: 36)
    }

    /// Beside the "+": the label and the projects to start a session in.
    var newSessionDetail: some View { NewSessionRow(store: store, style: .detail) }

    // MARK: Bar actions

    var pinButton: some View {
        IconButton(symbol: hub.pinned ? "pin.fill" : "pin", help: hub.pinned ? "Unpin" : "Keep open",
                   detail: "\(store.shortcut(.togglePanel).display) · twice for see-through",
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

    var settingsButton: some View { settingsCell }

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
        TimelineView(.periodic(from: .now, by: 10)) { context in
            syncLabel(now: context.date)
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
                        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(s.color)
                    } else {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 10, height: 10)
                Text(s.text).font(.system(size: 11)).foregroundStyle(s.color == Theme.green ? Theme.tertiary : s.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let failed = store.repoErrors.keys.sorted()
        if !failed.isEmpty {
            return SyncState(color: Theme.amber, text: "\(failed.count) repo\(failed.count == 1 ? "" : "s") failed",
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
            return SyncState(color: Theme.amber, text: "Synced \(shortAgo(last, now: now)) ago", title: "Not syncing",
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
