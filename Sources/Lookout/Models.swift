import Foundation
import SwiftUI

enum EventKind: String, Codable, CaseIterable, Identifiable {
    case issueOpened, issueComment, prOpened, prComment, reviewComment, ciMain, reviewRequested

    var id: String { rawValue }

    /// Events that can be toggled per repository.
    static let repoToggles: [EventKind] = [.issueOpened, .issueComment, .prOpened, .prComment, .reviewComment, .ciMain]
    /// Item kinds that a plain conversation comment from me addresses.
    static let conversationKinds: Set<EventKind> = [.issueOpened, .issueComment, .prOpened, .prComment]

    var label: String {
        switch self {
        case .issueOpened: "New issue"
        case .issueComment: "Issue comment"
        case .prOpened: "New pull request"
        case .prComment: "PR comment"
        case .reviewComment: "Review comment"
        case .ciMain: "CI"
        case .reviewRequested: "Review requested"
        }
    }

    var toggleLabel: String {
        switch self {
        case .issueOpened: "Issues"
        case .issueComment: "Issue comments"
        case .prOpened: "Pull requests"
        case .prComment: "PR comments"
        case .reviewComment: "Review comments"
        case .ciMain: "CI"
        case .reviewRequested: "Review requests"
        }
    }

    var tipDetail: String {
        switch self {
        case .issueOpened: "When someone opens an issue"
        case .prOpened: "When someone opens a pull request"
        case .ciMain: "Status of the default branch"
        case .reviewRequested: "When your review is requested"
        default: "Every comment in this repo"
        }
    }

    var symbol: String {
        switch self {
        case .issueOpened: "smallcircle.filled.circle"
        case .issueComment: "bubble.left.fill"
        case .prOpened: "arrow.triangle.pull"
        case .prComment: "bubble.right.fill"
        case .reviewComment: "chevron.left.forwardslash.chevron.right"
        case .ciMain: "checkmark.seal.fill"
        case .reviewRequested: "eye.fill"
        }
    }
}

enum ItemState: String, Codable {
    case unread, read, addressed, resolved, discarded

    /// Still waiting on me.
    var isOpen: Bool { self == .unread || self == .read }
}

struct RepoConfig: Codable, Identifiable, Hashable {
    var fullName: String
    var events: Set<EventKind> = Set(EventKind.repoToggles)
    var defaultBranch: String?
    /// Per-endpoint `since` cursors (max `updated_at` seen). Stable cursors keep URLs stable, so ETags give free 304s.
    var cursors: [String: Date] = [:]
    var addedAt: Date = Date()
    /// Off: only comments on my issues/PRs, mentioning me, or after I joined the thread.
    var allComments = false

    var id: String { fullName }
    var owner: String { String(fullName.split(separator: "/").first ?? "") }
    var name: String { String(fullName.split(separator: "/").last ?? "") }
    var url: URL { URL(string: "https://github.com/\(fullName)")! }
}

extension RepoConfig {
    /// Tolerates state files written before newer fields existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decode(String.self, forKey: .fullName)
        events = try c.decodeIfPresent(Set<EventKind>.self, forKey: .events) ?? Set(EventKind.repoToggles)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        cursors = try c.decodeIfPresent([String: Date].self, forKey: .cursors) ?? [:]
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        allComments = try c.decodeIfPresent(Bool.self, forKey: .allComments) ?? false
    }
}

struct InboxItem: Codable, Identifiable, Hashable {
    var id: String
    var repo: String
    var kind: EventKind
    var number: Int
    var title: String
    var snippet: String
    var author: String
    var avatar: URL?
    var authorIsApp: Bool
    var url: URL
    var createdAt: Date
    var state: ItemState {
        // Whatever takes an item out of the inbox (Done, addressed, resolved) stamps when; back in, the stamp goes.
        didSet {
            if state.isOpen { clearedAt = nil } else if oldValue.isOpen { clearedAt = Date() }
        }
    }
    /// Review comments: id of the first comment in the thread.
    var threadRoot: Int?
    var path: String?
    /// Comments: whether the "for you" rule matched (kept even with All comments on, so turning it off can prune).
    var forYou: Bool?
    /// When it left the inbox (nil while open, and for items cleared before this was kept): Done sorts by it, then
    /// by `createdAt`.
    var clearedAt: Date?
}

/// A repository's CI state. One table gives each state its words and its silhouette, for every place CI is drawn or
/// spoken (DESIGN.md 4.0): the bar's glyph, the rows, the header phrase, VoiceOver.
enum CIState: String, Codable {
    case success, failure, pending, none

    /// The glyph's colour, concrete: some drawing paths (a symbol effect's content transition) lose a `Theme.Ink`.
    func color(_ resolved: Theme.Resolved) -> Color {
        switch self {
        case .success, .none: resolved.tertiary
        case .failure: Theme.red
        case .pending: resolved.secondary
        }
    }

    /// A silhouette of its own, so the states read apart without their colours.
    var symbol: String {
        switch self {
        case .failure: "xmark.octagon.fill"
        case .pending: "circle.dashed"
        case .success: "checkmark.circle"
        case .none: "minus.circle"
        }
    }

    /// Names a group of repos in this state.
    var title: String {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .none: "No runs"
        }
    }

    /// In a sentence or after a count: "1 failing".
    var label: String {
        switch self {
        case .success: "passing"
        case .failure: "failing"
        case .pending: "running"
        case .none: "no runs"
        }
    }

    /// What VoiceOver says of one repo in this state.
    var voice: String {
        switch self {
        case .none: "no runs yet"
        default: label
        }
    }
}

struct CIStatus: Codable, Hashable {
    var state: CIState
    var branch: String
    var sha: String?
    var url: URL?
    var failing: [String]
    var checkedAt: Date
    /// Headline of the latest commit on the branch, and when its runs last changed.
    var title: String?
    var updatedAt: Date?
}

struct AppSettings: Codable {
    var botHandles: [String] = []
    var treatAppsAsBots = true
    var pollInterval: Double = 60
    var notifications = true
    var reviewRequests = true
    var snoozeUntil: Date?
    var didInitialReviewSync = false
    /// Customized shortcuts by ShortcutAction raw value; missing ones use the defaults.
    var shortcuts: [String: Shortcut]?
    /// Look for new releases in the background (default on).
    var checkUpdates: Bool?
    /// A release you chose to skip: not offered again by automatic checks.
    var skippedVersion: String?
    /// Keep the pill at the middle of its edge: dragging only picks the edge (default off).
    var centerPill: Bool?
}

struct PersistedState: Codable {
    var repos: [RepoConfig]
    var items: [InboxItem]
    var ci: [String: CIStatus]
    var settings: AppSettings
    var agents: AgentsState?
    /// Muted CI by repo full name: the commit sha it was muted at (see `Store.mutedCI`).
    var mutedCI: [String: String]?
    /// Review request ids cleared from Done while still pending (see `Store.droppedRequests`).
    var droppedRequests: [String]?
}

enum InboxFilter: String, CaseIterable {
    case needsYou, bots, done

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .bots: "Bots"
        case .done: "Done"
        }
    }
}

enum PanelTab {
    case inbox, ci, agents, repos, settings

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .ci: "CI"
        case .agents: "Sessions"
        case .repos: "Repositories"
        case .settings: "Settings"
        }
    }
}
