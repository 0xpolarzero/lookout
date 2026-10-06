import AppKit
import Foundation
import SwiftUI
@testable import Lookout

// What several suites need alike: key events, a window out of sight for rendering, the run loop pumped until a view has
// settled, and a wait for a condition that the code under test brings about on its own.

/// Set from an observation's change handler, which is not isolated.
final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}

/// A key press as the hub's monitor sees it: `characters` are what the key types, `window` is the one it goes to.
func keyDown(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "", in window: NSWindow? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
                     keyCode: UInt16(code))!
}

extension NSWindow {
    /// A borderless window far off screen, showing `content`: what the tests that measure or draw a view render in.
    @MainActor static func offscreen(_ content: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        return window
    }

    /// Takes the content out and puts the window away: what was hosted lets go of what it held.
    func dismiss() {
        contentView = nil
        orderOut(nil)
    }
}

extension NSView {
    /// Lets the run loop turn `turns` times, `interval` seconds each, laying the view out (and drawing it) as it goes.
    @MainActor func settle(turns: Int = 8, interval: TimeInterval = 0.05, display: Bool = false) {
        for _ in 0..<turns {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            layoutSubtreeIfNeeded()
            if display { displayIfNeeded() }
        }
    }

    /// Lets the run loop run for `seconds`, laying the view out as it goes.
    @MainActor func settle(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            layoutSubtreeIfNeeded()
        }
    }

    /// The first view of `type` at or below this one.
    func first<V: NSView>(_ type: V.Type) -> V? {
        (self as? V) ?? subviews.lazy.compactMap { $0.first(type) }.first
    }
}

/// Waits for `condition`, which something the test started brings about: for `seconds` of turns of the main actor, counted
/// and not timed, because the rendering tests can hold it for minutes at a time and a deadline would pass unseen.
@MainActor func eventually(upTo seconds: Int = 10, _ condition: () -> Bool) async throws {
    for _ in 0..<seconds * 50 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
}

/// The moment the session fixtures are relative to.
let sessionsNow = Date(timeIntervalSince1970: 2_000_000_000)

/// A session as the Claude app reports it, `minutesAgo` before `sessionsNow`: finished with a summary, or (`running`) mid-turn.
func session(_ id: String, turns: Int = 3, folder: String? = "/code/app", minutesAgo: Double = 5, messageMinutesAgo: Double? = nil,
             focusedMinutesAgo: Double? = 60, blocked: Bool = false, running: Bool = false, archived: Bool = false) -> ClaudeSession {
    ClaudeSession(id: id, title: "Session \(id)", folder: folder, isArchived: archived, completedTurns: turns,
                  lastActivity: sessionsNow.addingTimeInterval(-minutesAgo * 60),
                  lastFocused: focusedMinutesAgo.map { sessionsNow.addingTimeInterval(-$0 * 60) },
                  lastUserMessage: sessionsNow.addingTimeInterval(-(messageMinutesAgo ?? minutesAgo + 1) * 60),
                  summary: running ? nil : .init(blocked: blocked, detail: "Detail \(id)"), running: running)
}

/// An inbox item with nothing in it that a test does not ask for.
func inboxItem(_ id: String = "1", repo: String = "a/b", kind: EventKind = .issueComment, number: Int = 1, title: String = "t",
               author: String = "x", authorIsApp: Bool = false, at createdAt: Date = Date(), state: ItemState = .unread,
               forYou: Bool? = nil, threadRoot: Int? = nil) -> InboxItem {
    InboxItem(id: id, repo: repo, kind: kind, number: number, title: title, snippet: "", author: author, avatar: nil,
              authorIsApp: authorIsApp, url: URL(string: "https://github.com/\(repo)")!, createdAt: createdAt, state: state,
              threadRoot: threadRoot, forYou: forYou)
}

/// A status for a repository's default branch: a failure fails `build` unless `failing` says otherwise, and its runs last
/// changed when it was checked unless `updatedAt` says so.
func ciStatus(_ state: CIState, sha: String? = "a1", failing: [String]? = nil, checkedAt: Date = Date(), updatedAt: Date? = nil) -> CIStatus {
    CIStatus(state: state, branch: "main", sha: sha, failing: failing ?? (state == .failure ? ["build"] : []), checkedAt: checkedAt,
             updatedAt: updatedAt ?? checkedAt)
}

extension Store {
    /// A store that writes nothing to disk, signed in as `login` when one is given.
    @MainActor static func unsaved(signedInAs login: String? = nil) -> Store {
        let store = Store()
        store.persists = false
        store.me = login.map { GHUser(login: $0, avatarUrl: nil, type: "User") }
        return store
    }
}
