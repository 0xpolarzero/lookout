import SwiftUI

struct PanelView: View {
    let store: Store
    @Bindable var ui: UIState
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.stroke).frame(height: 1)
            Group {
                switch ui.tab {
                case .inbox: InboxView(store: store, ui: ui, close: close)
                case .ci: CIView(store: store, ui: ui)
                case .repos: ReposView(store: store)
                case .settings: SettingsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            footer
        }
        .foregroundStyle(Theme.text)
        .tipSpace()
        .frame(width: UIController.panelContent.width, height: UIController.panelContent.height)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(ui.tab.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 2) {
                IconButton(symbol: "tray.fill", help: "Inbox", active: ui.tab == .inbox) { ui.tab = .inbox }
                IconButton(symbol: "checkmark.seal.fill", help: "CI", active: ui.tab == .ci) { ui.tab = .ci }
                IconButton(symbol: "square.stack.3d.up.fill", help: "Repositories", active: ui.tab == .repos) { ui.tab = .repos }
                IconButton(symbol: "gearshape.fill", help: "Settings", active: ui.tab == .settings) { ui.tab = .settings }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            IconButton(symbol: "xmark", help: "Close", detail: "Esc · ⌃⌥Space toggles the panel", tint: Theme.tertiary, action: close)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 52)
        .zIndex(1)
    }

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 6) {
                if let error = store.authError {
                    Circle().fill(Theme.red).frame(width: 6, height: 6)
                    Text(error).lineLimit(1).truncationMode(.tail)
                } else if store.me == nil {
                    Text("Connecting to GitHub…")
                } else {
                    syncStatus(now: context.date)
                    if store.isSnoozed, let until = store.settings.snoozeUntil {
                        Text("· Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(Theme.purple)
                    }
                }
                Spacer()
                // Only worth showing when the shared GitHub rate limit is running low.
                if let rate = store.rateRemaining, rate < 500 {
                    Label("\(rate.formatted()) API calls left this hour", systemImage: "exclamationmark.triangle.fill")
                        .monospacedDigit()
                        .foregroundStyle(Theme.amber)
                        .tip("GitHub rate limit low",
                             "Shared with gh and other tools using your account. Syncing pauses at 0 until the hour resets.")
                }
                if store.me != nil {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh now",
                               detail: "Checks every repository, CI and review requests", size: 20) { store.refreshNow() }
                        .disabled(store.isSyncing)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 30)
        }
    }

    /// "Up to date" while polling is healthy; says how stale things are only when that matters.
    @ViewBuilder private func syncStatus(now: Date) -> some View {
        if store.isSyncing {
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            Text("Checking GitHub…")
        } else if let last = store.lastSync {
            let interval = store.settings.pollInterval
            let stale = now.timeIntervalSince(last) > interval * 3
            let failed = store.repoErrors.keys.sorted()
            let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
            HStack(spacing: 6) {
                Circle().fill(stale || !failed.isEmpty ? Theme.amber : Theme.green).frame(width: 6, height: 6)
                Text(stale ? "Last synced \(shortAgo(last, now: now)) ago"
                     : failed.isEmpty ? "Up to date" : "\(failed.count) repo\(failed.count == 1 ? "" : "s") failed to sync")
            }
            .tip("Last checked at \(last.formatted(date: .omitted, time: .standard))",
                 (failed.isEmpty ? "" : failed.joined(separator: "\n") + "\n")
                     + (stale ? "Not syncing: check your connection or token" : "Next check in about \(next)s"))
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    let store: Store
    @Bindable var ui: UIState
    let close: () -> Void
    @State private var selection: String?
    @FocusState private var focused: Bool
    @Environment(\.previewSelection) private var previewSelection

    var body: some View {
        let list = store.list(ui.filter)
        VStack(spacing: 0) {
            filterBar
            if store.repos.isEmpty && !store.settings.reviewRequests {
                empty(symbol: "square.stack.3d.up", title: "Watch a repository",
                      subtitle: "Pick repos and the events you care about.") {
                    Button("Add repository") { ui.tab = .repos }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            } else if list.isEmpty {
                switch ui.filter {
                case .needsYou: empty(symbol: "checkmark.circle", title: "All caught up", subtitle: "Nothing is waiting on you.") { EmptyView() }
                case .bots: empty(symbol: "cpu", title: "Bots are quiet", subtitle: "Comments from bot accounts land here, without sound.") { EmptyView() }
                case .done: empty(symbol: "archivebox", title: "Nothing here yet", subtitle: "Addressed, resolved and discarded items.") { EmptyView() }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(list) { item in
                                ItemRow(item: item, store: store, selected: selection == item.id,
                                        low: store.isLowPriority(item))
                                    .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .tipSpace()
                    .onChange(of: selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if selection == nil { selection = previewSelection }
        }
        .onKeyPress(.downArrow) { move(1, in: list); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
        .onKeyPress(.return) {
            if let item = selected(in: list) { store.open(item) }
            return .handled
        }
        .onKeyPress(.space) {
            if let item = selected(in: list) { item.state == .unread ? store.markRead(item) : store.markUnread(item) }
            return .handled
        }
        .onKeyPress(.delete) {
            if let item = selected(in: list) {
                move(1, in: list)
                item.state.isOpen ? store.discard(item) : store.restore(item)
            }
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(InboxFilter.allCases, id: \.self) { filter in
                Chip(label: filter.label, count: filter == .done ? nil : store.openCount(filter),
                     selected: ui.filter == filter) {
                    ui.filter = filter
                    selection = nil
                }
            }
            Spacer()
            if ui.filter != .done {
                IconButton(symbol: "checkmark.circle", help: "Mark all as read",
                           detail: "Everything in \(ui.filter.label)") { store.markAllRead(ui.filter) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func empty<Action: View>(symbol: String, title: String, subtitle: String,
                                     @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            action()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selected(in list: [InboxItem]) -> InboxItem? {
        list.first { $0.id == selection }
    }

    private func move(_ delta: Int, in list: [InboxItem]) {
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : list.count)
        selection = list[min(max(current + delta, 0), list.count - 1)].id
    }
}

struct ItemRow: View {
    let item: InboxItem
    let store: Store
    let selected: Bool
    let low: Bool
    @State private var isHovering = false
    @Environment(\.previewHover) private var previewHover
    private var hover: Bool { isHovering || previewHover == item.id }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(url: item.avatar, size: 28)
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(item.kind.color))
                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.state == .unread ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !hover {
                        Text(shortAgo(item.createdAt))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    Text("@\(item.author)").foregroundStyle(low ? Theme.tertiary : Theme.secondary)
                    Text("·")
                    Text(item.kind.label)
                    Text("·")
                    Text("\(item.repo.split(separator: "/").last ?? "")#\(item.number)")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)

                if let path = item.path {
                    Label(path, systemImage: "doc.text")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                if !item.state.isOpen {
                    stateTag.padding(.top, 3)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.white.opacity(0.09) : hover ? Theme.hover : .clear)
        )
        .overlay(alignment: .leading) {
            if item.state == .unread {
                Circle().fill(low ? Theme.secondary : Theme.amber).frame(width: 6, height: 6).padding(.leading, 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hover { actions.padding(6) }
        }
        .opacity(item.state == .unread || hover || selected ? 1 : 0.72)
        .contentShape(Rectangle())
        .onTapGesture { store.open(item) }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu { menu }
        .zIndex(hover ? 1 : 0)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if item.state.isOpen {
                if item.state == .unread {
                    IconButton(symbol: "checkmark", help: "Mark as read", detail: "Space", size: 24) { store.markRead(item) }
                } else {
                    IconButton(symbol: "circle.fill", help: "Mark as unread", detail: "Space", size: 24) { store.markUnread(item) }
                }
                IconButton(symbol: "xmark", help: "Discard", detail: "Moves it to Done · ⌫", size: 24) { store.discard(item) }
            } else {
                IconButton(symbol: "arrow.uturn.backward", help: "Back to inbox", detail: "⌫", size: 24) { store.restore(item) }
            }
            IconButton(symbol: "arrow.up.right", help: "Open on GitHub", detail: "Marks it read · Return", size: 24) { store.open(item) }
        }
        .padding(2)
        .background(Capsule().fill(Theme.bg))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }

    private var stateTag: some View {
        let (label, symbol, color): (String, String, Color) = switch item.state {
        case .addressed: ("Addressed", "arrowshape.turn.up.left.fill", Theme.green)
        case .resolved: ("Resolved", "checkmark.circle.fill", Theme.purple)
        default: ("Discarded", "xmark.circle.fill", Theme.tertiary)
        }
        return Label(label, systemImage: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(color.opacity(0.13)))
    }

    @ViewBuilder private var menu: some View {
        Button("Open on GitHub") { store.open(item) }
        Button("Copy link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        Divider()
        if item.state.isOpen {
            Button(item.state == .unread ? "Mark as read" : "Mark as unread") {
                item.state == .unread ? store.markRead(item) : store.markUnread(item)
            }
            Button("Discard") { store.discard(item) }
        } else {
            Button("Back to inbox") { store.restore(item) }
        }
        Divider()
        if !low {
            Button("Treat @\(item.author) as a bot") { store.addBot(item.author) }
        } else if store.settings.botHandles.contains(where: { $0.caseInsensitiveCompare(item.author) == .orderedSame }) {
            Button("Stop treating @\(item.author) as a bot") {
                store.settings.botHandles.removeAll { $0.caseInsensitiveCompare(item.author) == .orderedSame }
            }
        }
    }
}

// Demo/snapshot only: force a row to look hovered or keyboard-selected.
extension EnvironmentValues {
    @Entry var previewHover: String? = nil
    @Entry var previewSelection: String? = nil
    @Entry var previewTip: String? = nil
}
