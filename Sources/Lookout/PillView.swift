import AppKit
import SwiftUI

struct PillView: View {
    let store: Store
    let ui: UIState
    let actions: PillActions
    @State private var ripple = false

    var body: some View {
        VStack(spacing: 6) {
            grip
            group {
                inboxButton
            }
            if !store.ciRepos.isEmpty {
                group {
                    VStack(spacing: 8) {
                        ForEach(store.ciRepos) { repo in
                            let status = store.ci[repo.fullName]
                            CIDot(state: status?.state ?? .none)
                                .frame(width: 32, height: 10)
                                .help("\(repo.fullName) · \(status?.branch ?? "main") \(status?.state.label ?? "…")")
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.toggle(.repos) }
                }
            }
            group {
                IconButton(symbol: store.isSnoozed ? "moon.fill" : "gearshape.fill", help: "Settings", size: 32,
                           tint: store.isSnoozed ? Theme.purple : Theme.secondary,
                           active: ui.isOpen && ui.tab == .settings) {
                    actions.toggle(.settings)
                }
                .overlay(alignment: .topTrailing) {
                    if store.authError != nil || !store.repoErrors.isEmpty {
                        Circle().fill(Theme.red).frame(width: 7, height: 7).offset(x: -3, y: 3)
                    }
                }
            }
        }
        .padding(10)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .onChange(of: store.pulse) {
            ripple = false
            withAnimation(.easeOut(duration: 1.1)) { ripple = true }
        }
    }

    private var grip: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 16, height: 4)
            .frame(width: 40, height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in actions.dragChanged() }
                    .onEnded { _ in actions.dragEnded() }
            )
            .help("Drag to move · snaps to the nearest edge")
    }

    private var inboxButton: some View {
        let unread = store.unreadCount(.needsYou)
        let botUnread = store.unreadCount(.bots)
        return IconButton(symbol: unread > 0 ? "tray.full.fill" : "tray.fill", help: "Inbox (⌃⌥Space)", size: 32,
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
        .animation(.spring(duration: 0.3), value: unread)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(Capsule(style: .continuous).fill(Theme.bg))
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
