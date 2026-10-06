import AppKit
import SwiftUI

// Where VoiceOver's cursor goes when the hub opens or a bar cell's Show asks for its section, and what the hub says on
// its own (DESIGN.md 6.3, 7). The structure (containers, labels, actions) stays with each surface.

/// Where VoiceOver should move: asked for by `HubState.moveVoiceOver(to:)`, answered by the view that has that key.
struct VoiceOverRequest: Equatable {
    /// "i:<item>" and "a:<session>" are rows (the keyboard's own keys); "h:inbox", "h:ci" and "h:agents" a section's header, "h:controls" the controls (the peek's first row, the footer's first control).
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

    /// The hub opened from the keyboard or an action that named no row: the picked row, else the header of the section
    /// that is showing (the inbox's tabs are not there while another section has the room).
    func moveVoiceOverIntoHub() {
        if let request = voiceOverRequest, Date().timeIntervalSince(request.at) < Self.voiceOverPatience { return }
        moveVoiceOver(to: selection ?? (focus == .ci ? "h:ci" : focus == .agents ? "h:agents" : "h:inbox"))
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
    /// What the hub says when it opens: "Lookout, 5 need you, 1 CI failing, 1 session waiting", then what is wrong that
    /// it shows in a banner (sync, rate limit) or under Sessions (Claude's files): a fault found while it was closed is
    /// not a change anyone is told of.
    var openingAnnouncement: String {
        let needs = unreadCount(.needsYou)
        var parts = ["Lookout", needs > 0 ? "\(needs) need you" : "nothing needs you"]
        let failing = ciWorst.failing
        if failing > 0 { parts.append("\(failing) CI failing") }
        let waiting = agentCounts.blocked
        if agents.enabled, waiting > 0 { parts.append("\(plural(waiting, "session")) waiting") }
        var faults = [inboxNotice()?.message].compactMap { $0 }
        if agents.enabled, claudeLink == .missing || claudeLink == .unreadable {
            let line = ClaudeLinkStatus.describe(claudeLink)
            faults.append("\(line.text). \(line.detail)")
        }
        return ([parts.joined(separator: ", ")] + faults).joined(separator: ". ")
    }

    /// Each repository's state that counts (CI on, checked, not muted): what a change is told from.
    var ciStates: [String: CIState] {
        var states: [String: CIState] = [:]
        for entry in ciList.entries where entry.checked && !entry.muted { states[entry.id] = entry.state }
        return states
    }

    /// What CI changing under an open hub says, by repository and what each became: "CI failing: swift-format and zig.
    /// CI passing: lookout". Only repositories that were already known (a first answer is not a change). nil when none.
    func ciChangeAnnouncement(from old: [String: CIState], to new: [String: CIState]) -> String? {
        let list = ciList
        let words: [(CIState, String)] = [(.failure, "failing"), (.pending, "running"), (.success, "passing")]
        let parts = words.compactMap { state, word -> String? in
            let names = list.entries.filter { new[$0.id] == state && old[$0.id] != nil && old[$0.id] != state }.map { list.title($0.repo) }
            return names.isEmpty ? nil : "CI \(word): \(CISpeech.list(names))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}

/// What Lookout says to VoiceOver on its own, from one place: the hub's summary, CI changes, notices that just appeared.
/// The same words twice within a few seconds are said once.
@MainActor
enum Announce {
    private static var last: (text: String, at: Date)?

    static var voiceOverIsOn: Bool { NSApp != nil && NSWorkspace.shared.isVoiceOverEnabled }

    /// A moment after what moved the cursor, so the window taking the keyboard doesn't talk over it.
    static func say(_ text: String, after delay: Duration = .milliseconds(300)) {
        guard voiceOverIsOn else { return }
        if let last, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
        last = (text, Date())
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// Says what the hub has to say on its own, to VoiceOver (DESIGN.md 6.3): its summary when it is kept open, CI changing
/// under it while it is (changes close together are one announcement), a Claude notice that appears, and "Back to bar"
/// when it goes. From a view of its own, so only this body reads what it needs.
struct HubAnnouncer: View {
    let store: Store
    let hub: HubState
    /// The CI states before the changes now waiting to be said, and the wait that gathers them.
    @State private var ciBase: [String: CIState]?
    @State private var ciWait: Task<Void, Never>?

    var body: some View {
        Color.clear
            .onChange(of: hub.pinned) { _, pinned in
                // A page pins the hub too, and a drag puts it away: neither is the hub opening or going.
                guard hub.page == .main, !hub.dragging, Announce.voiceOverIsOn else { return }
                if pinned {
                    hub.moveVoiceOverIntoHub()
                    Announce.say(store.openingAnnouncement)
                } else {
                    Announce.say("Back to bar")
                }
            }
            .onChange(of: store.ciStates) { old, _ in ciChanged(from: old) }
            // A failed update check or download is said wherever it was asked for: Settings' row is not always on screen.
            .onChange(of: store.updater.shownError) { _, error in if let error { Announce.say(error) } }
            .onChange(of: store.claudeLink) { _, link in
                guard store.agents.enabled, hub.expanded, link == .missing || link == .unreadable else { return }
                let line = ClaudeLinkStatus.describe(link)
                Announce.say("\(line.text). \(line.detail)")
            }
    }

    /// Repositories that change within a moment of one another are told together, by name.
    private func ciChanged(from old: [String: CIState]) {
        guard hub.expanded, Announce.voiceOverIsOn else { return }
        if ciBase == nil { ciBase = old }
        ciWait?.cancel()
        ciWait = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let base = ciBase else { return }
            ciBase = nil
            if let text = store.ciChangeAnnouncement(from: base, to: store.ciStates) { Announce.say(text) }
        }
    }
}
