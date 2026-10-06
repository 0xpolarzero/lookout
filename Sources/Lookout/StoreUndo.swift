import AppKit
import Foundation
import Observation
import SwiftUI

// Undo for what leaves a list: Done, Done all, Clear Done here; Hide, Mute and Stop watching register theirs the same
// way. The line under the section shows for a few seconds, ⌘Z works for longer.

/// The last few things moved out of sight, newest last. Each is good for `validFor` seconds; the one on show is
/// dismissed by a one-shot timer, cancelled whenever it is replaced, undone or dismissed (nothing ticks at rest).
@MainActor @Observable
final class UndoStack {
    struct Entry: Identifiable {
        let id = UUID()
        /// The undo line's text: "Moved to Done".
        let message: String
        /// The section whose undo line shows it.
        let section: HubSection
        let at: Date
        let revert: @MainActor () -> Void
    }

    /// How long the line stays, and how long ⌘Z keeps working after the action.
    static let lineLifetime: Duration = .seconds(6)
    nonisolated static let validFor: TimeInterval = 30
    static let depth = 10

    private(set) var entries: [Entry] = []
    /// The entry whose line is showing.
    private(set) var visibleID: Entry.ID?
    @ObservationIgnored private(set) var timer: Task<Void, Never>?
    /// What a screen reader is told; the tests replace it (there is no app to post to).
    @ObservationIgnored var announce: (String) -> Void = { text in
        guard NSApp != nil else { return }
        AccessibilityNotification.Announcement(text).post()
    }
    /// Waits out the line's lifetime; the tests swap in one they release by hand.
    @ObservationIgnored var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The entry to show in this section's undo line.
    func visible(in section: HubSection) -> Entry? {
        guard let visibleID, let entry = entries.last(where: { $0.id == visibleID }), entry.section == section else { return nil }
        return entry
    }

    func push(_ message: String, in section: HubSection, announcement: String, now: Date = Date(),
              revert: @escaping @MainActor () -> Void) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        let entry = Entry(message: message, section: section, at: now, revert: revert)
        entries.append(entry)
        if entries.count > Self.depth { entries.removeFirst(entries.count - Self.depth) }
        show(entry)
        announce(announcement)
    }

    /// Takes back the newest action still within its 30 s; false when there is none.
    @discardableResult
    func undo(now: Date = Date()) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        guard let entry = entries.popLast() else { return false }
        dismiss()
        entry.revert()
        announce("Undone")
        return true
    }

    /// Hides the line (the action stays undoable with ⌘Z until it expires).
    func dismiss() {
        timer?.cancel()
        timer = nil
        visibleID = nil
    }

    private func show(_ entry: Entry) {
        timer?.cancel()
        visibleID = entry.id
        timer = Task { [weak self] in
            await self?.sleep(Self.lineLifetime)
            guard !Task.isCancelled, let self, visibleID == entry.id else { return }
            visibleID = nil
        }
    }
}

extension Store {
    /// Offers to take something back: the line shows in `section`, ⌘Z works for 30 s. `revert` must tolerate the
    /// world having moved on (check before restoring).
    func registerUndo(_ message: String, in section: HubSection = .inbox, announcement: String? = nil,
                      revert: @escaping @MainActor () -> Void) {
        undoStack.push(message, in: section, announcement: announcement ?? message + ". Undo available", revert: revert)
    }

    /// ⌘Z and the line's button.
    @discardableResult func undoLast() -> Bool { undoStack.undo() }

    // MARK: Done

    /// Moves an item to Done, with an undo line.
    func done(_ item: InboxItem) {
        let before = item.state
        guard before.isOpen else { return }
        let lane: InboxFilter = isLowPriority(item) ? .bots : .needsYou
        discard(item)
        let left = list(lane).count
        registerUndo("Moved to Done", announcement: "Moved to Done, \(left) left. Undo available") { [self] in
            restore(item.id, to: before)
        }
    }

    /// Done for every item in this tab that has been read; the unread ones stay.
    func doneAllRead(_ filter: InboxFilter) {
        let moved = list(filter).filter { $0.state == .read }
        guard !moved.isEmpty else { return }
        for item in moved { discard(item) }
        let left = list(filter).count
        registerUndo("Moved \(moved.count) to Done", announcement: "Moved \(plural(moved.count, "item")) to Done, \(left) left. Undo available") { [self] in
            for item in moved { restore(item.id, to: .read) }
        }
    }

    /// Whether the Done tab has anything Clear Done would drop.
    var hasClearableDone: Bool { items.contains { !$0.state.isOpen } }

    /// Empties Done for good (with an undo line for the next 30 s). A review request nobody has answered would come
    /// back from GitHub's search as new, so its id is remembered apart from the rows (`droppedRequests`).
    func clearDone() {
        let gone = items.filter { !$0.state.isOpen }
        guard !gone.isEmpty else { return }
        let requests = Set(gone.filter { $0.kind == .reviewRequested && $0.state == .discarded }.map(\.id))
        droppedRequests.formUnion(requests)
        removeItems { !$0.state.isOpen }
        registerUndo("Cleared \(gone.count) from Done", announcement: "Cleared \(plural(gone.count, "item")) from Done. Undo available") { [self] in
            // Only what the repositories and events watched now still allow: what was removed since stays removed.
            let known = Set(items.map(\.id))
            let back = gone.filter { !known.contains($0.id) && isWanted($0) }
            droppedRequests.subtract(requests)
            items.append(contentsOf: back)
            save()
        }
    }

    /// Whether the current configuration would keep this item: its repository is watched and follows its event (and
    /// All comments, or it is for me), or it is a review request and those are on. The inverse of what the
    /// removals (Stop watching, an event off, All comments off, review requests off) drop.
    func isWanted(_ item: InboxItem) -> Bool {
        if item.kind == .reviewRequested { return settings.reviewRequests }
        guard let repo = repos.first(where: { $0.fullName == item.repo }) else { return false }
        return repo.events.contains(item.kind) && (repo.allComments || item.forYou != false)
    }

    /// Puts an item back as it was before Done, unless something else has happened to it since.
    private func restore(_ id: String, to state: ItemState) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .discarded else { return }
        items[i].state = state
        save()
    }
}

extension InboxItem {
    /// Cleared so recently that ⌘Z may still bring it back: pruning leaves it alone until the window has passed.
    func isInUndoWindow(now: Date) -> Bool {
        clearedAt.map { now.timeIntervalSince($0) <= UndoStack.validFor } ?? false
    }
}
