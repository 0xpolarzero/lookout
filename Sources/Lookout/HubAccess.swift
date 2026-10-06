import AppKit
import SwiftUI

// Where VoiceOver's cursor goes when the hub opens or a bar cell's Show asks for its section, and what the hub says on
// its own (DESIGN.md 6.3, 7). The structure (containers, labels, actions) stays with each surface.

/// Where VoiceOver should move: asked for by `HubState.moveVoiceOver(to:)`, answered by the view that has that key.
struct VoiceOverRequest: Equatable {
    /// "i:<item>" and "a:<session>" are rows (the keyboard's own keys); "h:inbox", "h:ci" and "h:agents" a section's header.
    let target: String
    let at: Date
}

extension HubState {
    /// How long a request waits for its view (a row the list has not drawn yet) before it is stale and ignored.
    static let voiceOverPatience: TimeInterval = 2

    /// Moves VoiceOver's cursor to `target` once it is on screen: the bar's Show, and the hub opening, so that what you
    /// asked for is what is read, whichever way the hub opened. Nothing happens without VoiceOver running.
    func moveVoiceOver(to target: String) {
        voiceOverRequest = VoiceOverRequest(target: target, at: Date())
    }

    /// The hub opened from the keyboard or an action that named no row: the picked row, else the inbox's header.
    func moveVoiceOverIntoHub() {
        if let request = voiceOverRequest, Date().timeIntervalSince(request.at) < Self.voiceOverPatience { return }
        moveVoiceOver(to: selection ?? "h:inbox")
    }
}

/// Takes VoiceOver's focus when its `key` is asked for. The view it is on supplies the focus state, as rows do for their
/// own (they also show their action on it).
private struct VoiceOverTarget: ViewModifier {
    let hub: HubState
    let key: String
    var focus: AccessibilityFocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            // `initial`: the view may have appeared with the hub opening, after the request was made.
            .onChange(of: hub.voiceOverRequest, initial: true) { _, request in
                guard let request, request.target == key,
                      Date().timeIntervalSince(request.at) < HubState.voiceOverPatience else { return }
                Task { @MainActor in
                    // Let the opened hub lay out before the cursor moves into it.
                    try? await Task.sleep(for: .milliseconds(100))
                    focus.wrappedValue = true
                    if hub.voiceOverRequest == request { hub.voiceOverRequest = nil }
                }
            }
    }
}

private struct HeaderVoiceOver: ViewModifier {
    let hub: HubState
    let key: String
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.accessibilityFocused($focused).modifier(VoiceOverTarget(hub: hub, key: key, focus: $focused))
    }
}

extension View {
    /// A row that answers `moveVoiceOver(to:)` for `key`, with the accessibility focus state it already keeps.
    func voiceOverTarget(_ key: String, hub: HubState, focus: AccessibilityFocusState<Bool>.Binding) -> some View {
        modifier(VoiceOverTarget(hub: hub, key: key, focus: focus))
    }

    /// A section's header (or any view with nothing else to do with VoiceOver's focus) that answers it for `key`.
    func voiceOverTarget(_ key: String, hub: HubState) -> some View {
        modifier(HeaderVoiceOver(hub: hub, key: key))
    }
}

// MARK: - Announcements

extension Store {
    /// What the hub says when it opens: "Lookout, 5 need you, 1 CI failing, 1 session waiting".
    var openingAnnouncement: String {
        let needs = unreadCount(.needsYou)
        var parts = ["Lookout", needs > 0 ? "\(needs) need you" : "nothing needs you"]
        let failing = ciWorst.failing
        if failing > 0 { parts.append("\(failing) CI failing") }
        let waiting = agentCounts.blocked
        if agents.enabled, waiting > 0 { parts.append("\(plural(waiting, "session")) waiting") }
        return parts.joined(separator: ", ")
    }

    /// What CI changing under an open hub says: "CI failing: swift-format and zig", "CI passing". Nothing when no
    /// repository has a run.
    func ciAnnouncement(for worst: CIWorst) -> String? {
        switch worst.state {
        case .failure:
            let names = ciList.attention.filter { $0.state == .failure }.map { ciList.title($0.repo) }
            return "CI failing: \(CISpeech.list(names))"
        case .pending: return "CI running"
        case .success: return "CI passing"
        case .none: return nil
        }
    }
}

/// Says what the hub has to say on its own, to VoiceOver (DESIGN.md 6.3): its summary when it is kept open, CI changing
/// under it while it is, and "Back to bar" when it goes. From a view of its own, so only this body reads what it needs.
struct HubAnnouncer: View {
    let store: Store
    let hub: HubState

    var body: some View {
        Color.clear
            .onChange(of: hub.pinned) { _, pinned in
                // A page pins the hub too, and a drag puts it away: neither is the hub opening or going.
                guard hub.page == .main, !hub.dragging, Self.voiceOverIsOn else { return }
                if pinned {
                    hub.moveVoiceOverIntoHub()
                    Self.say(store.openingAnnouncement)
                } else {
                    Self.say("Back to bar")
                }
            }
            .onChange(of: store.ciWorst) { _, worst in
                guard hub.expanded, Self.voiceOverIsOn, let text = store.ciAnnouncement(for: worst) else { return }
                Self.say(text)
            }
    }

    private static var voiceOverIsOn: Bool { NSApp != nil && NSWorkspace.shared.isVoiceOverEnabled }

    /// A moment after what moved the cursor, so the window taking the keyboard doesn't talk over it.
    private static func say(_ text: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            AccessibilityNotification.Announcement(text).post()
        }
    }
}
