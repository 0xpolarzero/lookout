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
    var syncButton: some View { SyncButton(store: store, hub: hub) }
}

/// The sync state is read here, in views of their own: a poll flips `isSyncing` and `lastSync` every time, and that
/// redraws these lines, not the hub (DESIGN.md 8). One `Ticking` whatever the line says: it is the same view through a
/// poll (swapping it for a plain line while syncing would mount it again, and a mount is a claim on the clock). A fault,
/// "Checking…" and "Not checked yet" name no time and ignore the one they are given.
struct SyncStatus<Content: View>: View {
    let store: Store
    @ViewBuilder let content: (SyncLine) -> Content

    /// The sync line for `content`, redrawn on the minute clock (which never starts the seconds one).
    var body: some View {
        Ticking(coarse: true) { content(SyncLine(store, now: $0)) }
    }
}

struct SyncButton: View {
    let store: Store
    let hub: HubState

    var body: some View {
        SyncStatus(store: store) { line in
            Button {
                // Not disabled while it checks: that would fade the one word that says so ("Checking…").
                if line.opensSettings { hub.go(.settings) } else if !store.isSyncing { store.refreshNow() }
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
            .help(line.help)
            .accessibilityLabel(line.text)
            .accessibilityHint(line.opensSettings ? "Opens Settings" : "Checks GitHub now")
            .voiceOverTarget("h:controls", hub: hub)
        }
    }
}

extension SyncLine {
    @MainActor init(_ store: Store, now: Date) {
        let refresh = "Check now  \(store.shortcut(.refresh).display)"
        if let error = store.authError {
            self.init(text: "Can't sign in to GitHub", color: AnyShapeStyle(Theme.red), help: error + "\nOpens Settings",
                      opensSettings: true, isFault: true)
            return
        }
        let interval = store.settings.pollInterval
        let last = store.lastSync
        let stale = store.isStale(at: now)
        let ciStale = store.isCIStale(at: now)
        // The faults are `Store.syncFault`'s, the one calculation the gear, the banner and Settings share; the rate limit has
        // its own notice beside this line, so it doesn't replace it.
        switch store.syncFault(stale: stale, ciStale: ciStale) {
        case .partial:
            let failed = store.repoErrors.keys.sorted()
            self.init(text: "\(plural(failed.count, "repository", "repositories")) didn't sync", color: AnyShapeStyle(Theme.secondary),
                      help: failed.joined(separator: "\n") + "\n" + refresh, isFault: true)
            return
        case .reviewRequests:
            self.init(text: SyncFault.reviewRequests.phrase, color: AnyShapeStyle(Theme.secondary),
                      help: (store.reviewRequestsError ?? "") + "\n" + refresh, isFault: true)
            return
        case .reviewRequestsCut:
            self.init(text: SyncFault.reviewRequestsCut.phrase, color: AnyShapeStyle(Theme.secondary),
                      help: "GitHub cut the search short, so some may be missing\n" + refresh, isFault: true)
            return
        default:
            break
        }
        if store.isSyncing {
            self.init(text: "Checking…", color: AnyShapeStyle(Theme.tertiary), help: "Checking GitHub")
            return
        }
        guard let last else {
            self.init(text: store.me == nil ? "Connecting…" : "Not checked yet", color: AnyShapeStyle(Theme.tertiary), help: refresh)
            return
        }
        if stale {
            self.init(text: "Not syncing", color: AnyShapeStyle(Theme.secondary),
                      help: "Last checked at \(last.formatted(date: .omitted, time: .shortened)): check your connection or token\n" + refresh,
                      isFault: true)
            return
        }
        if ciStale, let checked = store.ciFreshness {
            self.init(text: SyncFault.ciStale.phrase, color: AnyShapeStyle(Theme.secondary),
                      help: "CI last checked at \(checked.formatted(date: .omitted, time: .shortened))\n" + refresh, isFault: true)
            return
        }
        let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
        self.init(text: "Checked \(agoPhrase(last, now: now))", color: AnyShapeStyle(Theme.tertiary),
                  help: "Next check in about \(next < 60 ? "\(next)s" : "\(next / 60)m")\n" + refresh)
    }
}

extension LookoutHub {
    /// Still named by the old full view in HubBar.swift, which `HubOpen.swift` replaces: it goes with it.
    var footerDetail: some View { footerRow }
}
