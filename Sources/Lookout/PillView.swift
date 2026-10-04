import AppKit
import SwiftUI

struct PillView: View {
    let store: Store
    let ui: UIState
    let actions: PillActions
    @State private var ripple = false

    var body: some View {
        // Vertical on the left/right edges, horizontal when docked to the top or bottom.
        let horizontal = ui.edge.isHorizontal
        let stack = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        stack {
            group {
                inboxButton
            }
            if !store.ciRepos.isEmpty {
                group {
                    (horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 6))) {
                        ForEach([CIState.success, .failure, .pending], id: \.self) { state in
                            ciCount(state)
                        }
                    }
                    .padding(horizontal ? .horizontal : .vertical, horizontal ? 6 : 8)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggle(.ci) }
                }
            }
        }
        .padding(2)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .environment(\.systemHelp, true)
        .onChange(of: store.pulse) {
            ripple = false
            withAnimation(.easeOut(duration: 1.1)) { ripple = true }
        }
    }


    private var inboxButton: some View {
        let unread = store.unreadCount(.needsYou)
        let botUnread = store.unreadCount(.bots)
        return IconButton(symbol: unread > 0 ? "tray.full.fill" : "tray.fill", help: "Inbox (⌃⌥L)", size: 32,
                          tint: unread > 0 ? Theme.text : Theme.secondary,
                          active: ui.isOpen && ui.tab == .inbox) {
            actions.toggle(.inbox)
        }
        .background(
            Circle()
                .stroke(Theme.amber, lineWidth: 2)
                .scaleEffect(ripple ? 1.9 : 1)
                .opacity(ripple ? 0 : 0.9)
                .opacity(store.pulse == 0 ? 0 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Theme.amber))
                    .offset(x: 5, y: -5)
                    .transition(.scale.combined(with: .opacity))
            } else if botUnread > 0 {
                Circle()
                    .fill(Theme.secondary)
                    .frame(width: 7, height: 7)
                    .offset(x: 1, y: -1)
                    .help("\(botUnread) from bots")
            }
        }
        .overlay(alignment: .bottomTrailing) { statusBadge.offset(x: 4, y: 4) }
        .animation(.spring(duration: 0.3), value: unread)
    }

    /// One row per CI state with the number of repos in it; hover lists them.
    private func ciCount(_ state: CIState) -> some View {
        let repos = store.ciRepos(in: state)
        let names = repos.map { "\($0.fullName) (\(store.ci[$0.fullName]?.branch ?? "main"))" }
        return HStack(spacing: 5) {
            CIDot(state: repos.isEmpty ? .none : state, size: 7)
            Text("\(repos.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(repos.isEmpty ? Theme.tertiary : Theme.text)
        }
        .frame(width: 32, height: 16)
        .help(repos.isEmpty ? "No repos \(state.label)" : "\(state.label.capitalized) on main:\n" + names.joined(separator: "\n"))
    }

    /// Settings live in the panel; the pill only surfaces problems and snooze.
    @ViewBuilder private var statusBadge: some View {
        if store.authError != nil || !store.repoErrors.isEmpty {
            badgeIcon("exclamationmark", Theme.red)
                .help(store.authError ?? "Some repositories failed to sync")
        } else if store.isSnoozed {
            badgeIcon("moon.fill", Theme.purple).help("Notifications snoozed")
        }
    }

    private func badgeIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .black))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: 14, height: 14)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2))
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(Capsule(style: .continuous).fill(Theme.bg))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke))
    }
}
