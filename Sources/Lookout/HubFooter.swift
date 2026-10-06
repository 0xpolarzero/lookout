import AppKit
import SwiftUI

// The footer of the full view (DESIGN.md 4.11): one 36pt row, last on every edge. On the left how syncing is going, as
// a button that checks now; on the right Keep open and Repositories. Settings is the gear cell, not part of it.

/// Beside the sync status, on every edge: the GitHub rate limit running low (nothing otherwise).
struct RateNotice: View {
    let store: Store
    /// Takes the whole line (its text at the leading edge); off, only the room it needs.
    var fill = true

    var body: some View {
        RateLimitWarning(store: store)
            .font(Theme.Typography.meta)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    }
}

/// How syncing is going, in a few words: a fault says what and why, otherwise when it last checked.
struct SyncLine {
    var text: String
    var color: AnyShapeStyle
    /// The system tooltip: what a click does, with the detail the words leave out.
    var help: String
    /// A sign-in problem goes to Settings; everything else checks now.
    var opensSettings = false
    var isFault = false
}

extension LookoutHub {
    /// The footer row, as tall as every one-line row.
    var footerRow: some View {
        HStack(spacing: Theme.Space.md) {
            syncButton
            RateNotice(store: store, fill: false).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 0)
            pinButton
            reposButton
        }
        .padding(.leading, Theme.Metrics.rowPadding)
        .padding(.trailing, Theme.Space.hair)
        .frame(height: Theme.Metrics.pitch)
    }

    var pinButton: some View {
        IconButton(symbol: hub.pinned ? "pin.fill" : "pin", help: hub.pinned ? "Stop keeping open" : "Keep open",
                   detail: store.shortcut(.togglePanel).display, active: hub.pinned) {
            hub.pinned.toggle()
        }
    }

    var reposButton: some View {
        IconButton(symbol: "books.vertical", help: "Repositories", detail: "Watched repos and what they notify",
                   active: hub.page == .repos) { hub.go(.repos) }
    }

    /// Lit while Settings is open; its tooltip and label say what a click does.
    var settingsCell: some View {
        let open = hub.page == .settings
        return IconButton(symbol: open ? "gearshape.fill" : "gearshape", help: open ? "Close Settings" : "Settings",
                          detail: "⌘,", active: open) { open ? hub.back() : hub.go(.settings) }
    }

    /// "Checked 2m ago", or the fault in its place: a button that checks now (or opens Settings to sign in).
    var syncButton: some View {
        syncLine { line in
            Button {
                if line.opensSettings { hub.go(.settings) } else { store.refreshNow() }
            } label: {
                Text(line.text)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(line.color)
                    .lineLimit(1)
                    .frame(minHeight: Theme.Metrics.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(Theme.Radius.small)
            .disabled(store.isSyncing)
            .help(line.help)
            .accessibilityLabel(line.text)
            .accessibilityHint(line.opensSettings ? "Opens Settings" : "Checks GitHub now")
        }
    }

    /// Whether the sync line says how long ago it checked, and so has to follow the clock. A fault, "Checking…" and "Not
    /// checked yet" name no time: they are drawn once, with nothing subscribed to the clock.
    private var syncNamesTime: Bool {
        store.authError == nil && store.repoErrors.isEmpty && !store.isSyncing && store.lastSync != nil
    }

    /// The sync line for `content`, redrawn on the minute clock (which never starts the seconds one) only while it counts minutes.
    @ViewBuilder func syncLine<Content: View>(@ViewBuilder _ content: @escaping (SyncLine) -> Content) -> some View {
        if syncNamesTime {
            Ticking(minute: true) { content(syncLine(now: $0)) }
        } else {
            content(syncLine(now: Date()))
        }
    }

    func syncLine(now: Date) -> SyncLine {
        let refresh = "Check now  \(store.shortcut(.refresh).display)"
        if let error = store.authError {
            return SyncLine(text: "Can't sign in to GitHub", color: AnyShapeStyle(Theme.red), help: error + "\nOpens Settings",
                            opensSettings: true, isFault: true)
        }
        let failed = store.repoErrors.keys.sorted()
        if !failed.isEmpty {
            return SyncLine(text: "\(plural(failed.count, "repository", "repositories")) didn't sync", color: AnyShapeStyle(Theme.secondary),
                            help: failed.joined(separator: "\n") + "\n" + refresh, isFault: true)
        }
        if store.isSyncing {
            return SyncLine(text: "Checking…", color: AnyShapeStyle(Theme.tertiary), help: "Checking GitHub")
        }
        guard let last = store.lastSync else {
            return SyncLine(text: store.me == nil ? "Connecting…" : "Not checked yet", color: AnyShapeStyle(Theme.tertiary), help: refresh)
        }
        let interval = store.settings.pollInterval
        if now.timeIntervalSince(last) > interval * 3 {
            return SyncLine(text: "Not syncing", color: AnyShapeStyle(Theme.secondary),
                            help: "Last checked at \(last.formatted(date: .omitted, time: .shortened)): check your connection or token\n" + refresh,
                            isFault: true)
        }
        let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
        return SyncLine(text: "Checked \(agoPhrase(last, now: now))", color: AnyShapeStyle(Theme.tertiary),
                        help: "Next check in about \(next < 60 ? "\(next)s" : "\(next / 60)m")\n" + refresh)
    }
}

extension LookoutHub {
    /// Still named by the old full view in HubBar.swift, which `HubOpen.swift` replaces: it goes with it.
    var footerDetail: some View { footerRow }
}
