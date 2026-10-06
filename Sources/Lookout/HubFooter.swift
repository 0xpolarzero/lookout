import AppKit
import SwiftUI

// The footer of the full view and the controls: sync status, Keep open, Repositories and Settings.

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

extension LookoutHub {
    // MARK: Bar actions

    /// Beside the settings cell: on the left edge, the same pieces mirrored, so pin and repositories sit by
    /// the bar on either side and the sync status out by the rounded side.
    @ViewBuilder var footerDetail: some View {
        if edge == .left {
            HStack(spacing: 9) {
                reposButton
                pinButton
                Spacer(minLength: 0)
                syncStatus
            }
            .frame(height: 40)
        } else {
            footer
        }
    }

    // MARK: Footer

    var pinButton: some View {
        IconButton(symbol: hub.pinned ? "pin.fill" : "pin", help: hub.pinned ? "Stop keeping open" : "Keep open",
                   detail: store.shortcut(.togglePanel).display, active: hub.pinned) {
            hub.pinned.toggle()
        }
    }

    var reposButton: some View {
        IconButton(symbol: "square.stack.3d.up.fill", help: "Repositories", detail: "Watched repos and what they notify",
                   active: hub.page == .repos) { hub.go(.repos) }
    }

    /// Lit on Settings; on Repositories too beside the bar, where the repositories button hides with the rows.
    var settingsCell: some View {
        IconButton(symbol: "gearshape.fill", help: "Settings", detail: "⌘,",
                   active: hub.page == .settings || (hub.page == .repos && !edge.isHorizontal)) { hub.go(.settings) }
    }

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
                Text(s.text).font(Theme.Typography.meta).foregroundStyle(s.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.Metrics.tile)
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
            return SyncState(color: Theme.secondary, text: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))",
                             title: "Notifications snoozed", detail: "No banners; the inbox keeps filling · resume in Settings",
                             symbol: "moon.fill")
        }
        let next = max(0, Int(last.addingTimeInterval(interval).timeIntervalSince(now)))
        return SyncState(color: Theme.tertiary, text: "Up to date", title: checked,
                         detail: "Next check in about \(next < 60 ? "\(next)s" : "\(next / 60)m")\n\(refresh)")
    }
}
