import AppKit
import Foundation
import Observation
import SwiftUI

// Undo for Done: a line under the inbox's header offers it for a few seconds, ⌘Z works for 30.

/// The last few things moved out of sight, newest last. Each is good for `validFor` seconds; the line on show is dismissed
/// by a one-shot timer, cancelled whenever it is replaced, undone or dismissed (nothing ticks at rest).
@MainActor @Observable
final class UndoStack {
    struct Entry: Identifiable {
        let id = UUID()
        /// The undo line's text: "Moved to Done".
        let message: String
        /// The inbox items it would bring back: the store's pruning leaves them alone while it can.
        let itemIDs: Set<String>
        let at: Date
        /// Whether anything was put back: false once what it concerned is gone.
        let revert: @MainActor () -> Bool
    }

    /// How long the line stays, and how long ⌘Z keeps working after the action.
    static let lineLifetime: Duration = .seconds(6)
    nonisolated static let validFor: TimeInterval = 30
    static let depth = 10

    private(set) var entries: [Entry] = []
    /// The entry whose line is showing.
    private(set) var visibleID: Entry.ID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// What a screen reader is told; the tests replace it (there is no app to post to).
    @ObservationIgnored var announce: (String) -> Void = { text in
        guard NSApp != nil else { return }
        AccessibilityNotification.Announcement(text).post()
    }
    /// Waits out the line's lifetime; the tests swap in one they release by hand.
    @ObservationIgnored var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The entry to show in the undo line.
    var line: Entry? {
        guard let visibleID else { return nil }
        return entries.last { $0.id == visibleID }
    }

    func push(_ message: String, itemIDs: Set<String>, now: Date = Date(), revert: @escaping @MainActor () -> Bool) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        let entry = Entry(message: message, itemIDs: itemIDs, at: now, revert: revert)
        entries.append(entry)
        if entries.count > Self.depth { entries.removeFirst(entries.count - Self.depth) }
        show(entry)
        announce(message + ". Undo available")
    }

    /// Takes back the newest action still within its 30 s that has something left to put back; false when there is none.
    @discardableResult
    func undo(now: Date = Date()) -> Bool {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.validFor }
        dismiss()
        while let entry = entries.popLast() {
            if entry.revert() {
                announce("Undone")
                return true
            }
        }
        return false
    }

    /// Whether ⌘Z could still bring this item back.
    func holds(_ id: String, now: Date = Date()) -> Bool {
        entries.contains { now.timeIntervalSince($0.at) <= Self.validFor && $0.itemIDs.contains(id) }
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
    /// ⌘Z and the line's button.
    @discardableResult func undoLast() -> Bool { undoStack.undo() }

    /// Puts an item back as it was before Done, unless something else has happened to it since. False when it has.
    func undoDone(_ id: String, to state: ItemState) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .discarded else { return false }
        items[i].state = state
        save()
        return true
    }
}
