import AppKit
import Foundation
import Observation
import SwiftUI

// Undo for what Repositories takes out of sight: Stop watching, and a preset that removes inbox items. The line on
// the page shows for a few seconds; ⌘Z (HubKeys) works for 30, from any page, so leaving Repositories loses nothing.

/// The last few repository changes, newest last. Each is good for `validFor` seconds, judged by its date; what the
/// line shows is separate, ended by a one-shot timer that is cancelled whenever the entry is replaced, undone or
/// dismissed (nothing ticks at rest).
@MainActor @Observable
final class RepoUndo {
    struct Entry: Identifiable {
        let id = UUID()
        /// The undo line's text: "Stopped watching apple/swift-format".
        let message: String
        let at: Date
        let revert: @MainActor () -> Void
    }

    /// How long the line stays, and how long ⌘Z keeps working after the change.
    static let lineLifetime: Duration = .seconds(6)
    static let validFor: TimeInterval = 30
    static let depth = 5

    private(set) var entries: [Entry] = []
    /// The entry whose line is showing.
    private(set) var visibleID: Entry.ID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// What a screen reader is told; the tests replace it (there is no app to post to).
    @ObservationIgnored var announce: (String) -> Void = { text in
        guard NSApp != nil else { return }
        AccessibilityNotification.Announcement(text).post()
    }
    @ObservationIgnored var lifetime = RepoUndo.lineLifetime

    /// The entry to show in the page's undo line.
    var visible: Entry? {
        guard let visibleID else { return nil }
        return entries.last { $0.id == visibleID }
    }

    func push(_ message: String, announcement: String? = nil, now: Date = Date(), revert: @escaping @MainActor () -> Void) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        let entry = Entry(message: message, at: now, revert: revert)
        entries.append(entry)
        if entries.count > Self.depth { entries.removeFirst(entries.count - Self.depth) }
        show(entry)
        announce(announcement ?? message + ". Undo available")
    }

    /// Takes back the newest change still within its 30 s; false when there is none.
    @discardableResult
    func undo(now: Date = Date()) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        guard let entry = entries.popLast() else { return false }
        dismiss()
        entry.revert()
        announce("Undone")
        return true
    }

    /// Hides the line (the change stays undoable with ⌘Z until it expires).
    func dismiss() {
        timer?.cancel()
        timer = nil
        visibleID = nil
    }

    private func show(_ entry: Entry) {
        timer?.cancel()
        visibleID = entry.id
        let lifetime = lifetime
        timer = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, visibleID == entry.id else { return }
            visibleID = nil
        }
    }
}
