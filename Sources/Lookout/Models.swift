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

    var color: Color {
        switch self {
        case .issueOpened: Theme.green
        case .issueComment: Theme.accent
        case .prOpened: Theme.purple
        case .prComment: Theme.purple
        case .reviewComment: Theme.amber
        case .ciMain: Theme.green
        case .reviewRequested: Theme.amber
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
    var state: ItemState
    /// Review comments: id of the first comment in the thread.
    var threadRoot: Int?
    var path: String?
    /// Comments: whether the "for you" rule matched (kept even with All comments on, so turning it off can prune).
    var forYou: Bool?
}

enum CIState: String, Codable {
    case success, failure, pending, none

    var color: Color {
        switch self {
        case .success: Theme.green
        case .failure: Theme.red
        case .pending: Theme.amber
        case .none: Theme.tertiary
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.seal.fill"
        case .failure: "xmark.seal.fill"
        case .pending: "clock.fill"
        case .none: "seal.fill"
        }
    }

    var title: String {
        switch self {
        case .success: "Passing"
        case .failure: "Failing"
        case .pending: "Running"
        case .none: "No checks"
        }
    }

    var label: String {
        switch self {
        case .success: "passing"
        case .failure: "failing"
        case .pending: "running"
        case .none: "no checks"
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
    /// When the first review search, if it couldn't list everything, took its answer: requests last touched before it are
    /// backlog that turned up late, not news. Nil once a complete search has listed them all.
    var reviewBaselineAt: Date?
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
