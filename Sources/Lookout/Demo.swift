import Foundation

/// `--demo`: fake data for trying the UI without touching GitHub or the saved state.
@MainActor
enum Demo {
    static func populate(_ store: Store) {
        store.persists = false
        let now = Date()
        func avatar(_ login: String) -> URL? { URL(string: "https://github.com/\(login).png") }
        func item(_ kind: EventKind, _ repo: String, _ n: Int, _ title: String, _ author: String, _ snippet: String,
                  _ minutesAgo: Double, _ state: ItemState = .unread, app: Bool = false, path: String? = nil) -> InboxItem {
            InboxItem(id: UUID().uuidString, repo: repo, kind: kind, number: n, title: title, snippet: snippet,
                      author: author, avatar: avatar(author.replacingOccurrences(of: "[bot]", with: "")), authorIsApp: app,
                      url: URL(string: "https://github.com/\(repo)/issues/\(n)")!,
                      createdAt: now.addingTimeInterval(-minutesAgo * 60), state: state, path: path)
        }
        store.repos = [
            RepoConfig(fullName: "polarzero/lookout"),
            RepoConfig(fullName: "apple/swift-format"),
            RepoConfig(fullName: "ziglang/zig", events: [.prComment, .reviewComment, .ciMain]),
        ]
        store.ci = [
            "polarzero/lookout": CIStatus(state: .success, branch: "main", failing: [], checkedAt: now),
            "apple/swift-format": CIStatus(state: .failure, branch: "main", failing: ["Linux / build", "Windows / test"], checkedAt: now),
            "ziglang/zig": CIStatus(state: .pending, branch: "master", failing: [], checkedAt: now),
        ]
        store.items = [
            item(.reviewComment, "ziglang/zig", 21877, "std.Io: add vectored reads to File", "andrewrk",
                 "This should take the buffer by slice instead, otherwise we copy twice on the hot path.", 3,
                 path: "lib/std/Io/File.zig"),
            item(.prComment, "apple/swift-format", 1042, "Respect trailing comma config in collection literals", "allevato",
                 "Thanks! Could you add a test for the nested array case?", 18),
            item(.issueOpened, "polarzero/lookout", 12, "Pill overlaps the Dock when it's on the right", "mattt",
                 "With the Dock pinned right, the pill sits under it. Maybe snap to the visible frame?", 42),
            item(.reviewRequested, "apple/swift-format", 1051, "Add --lines option to format a range", "ahoppen",
                 "", 65),
            item(.issueComment, "polarzero/lookout", 9, "Support GitHub Enterprise", "kyle", "+1, we'd use this at work.", 120, .read),
            item(.prComment, "polarzero/lookout", 14, "Group notifications by repo", "vercel[bot]",
                 "Deployment ready. Preview: lookout-git-group.vercel.app", 6, app: true),
            item(.prComment, "apple/swift-format", 1042, "Respect trailing comma config in collection literals", "codecov[bot]",
                 "Coverage 87.2% (+0.4%) compared to base.", 25, app: true),
            item(.reviewComment, "ziglang/zig", 21877, "std.Io: add vectored reads to File", "squeek502",
                 "Nit: this is the same as readv on posix.", 300, .resolved, path: "lib/std/Io/File.zig"),
            item(.issueComment, "polarzero/lookout", 7, "Crash on wake from sleep", "jessesquires",
                 "Repro'd on 26.1 as well.", 900, .addressed),
        ]
        store.me = GHUser(login: "polarzero", avatarUrl: URL(string: "https://github.com/0xpolarzero.png"), type: "User")
        store.tokenSource = .ghCLI
        store.lastSync = now.addingTimeInterval(-20)
        store.rateRemaining = 4812
    }
}

import AppKit
import SwiftUI

/// `--demo --snapshot <dir>`: renders the pill and each panel tab to PNGs (no screen recording needed).
@MainActor
enum Snapshot {
    static func run(store: Store, to dir: String) {
        let ui = UIState()
        let actions = PillActions(toggle: { _ in }, dragChanged: {}, dragEnded: {})
        var windows: [(String, NSWindow)] = []
        func host<V: View>(_ name: String, _ view: V) {
            let hosting = NSHostingView(rootView: view)
            hosting.frame.size = hosting.fittingSize
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = NSColor(white: 0.22, alpha: 1)
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderFrontRegardless()
            windows.append((name, window))
        }
        host("pill", PillView(store: store, ui: ui, actions: actions))
        for (name, tab, filter) in [("inbox", PanelTab.inbox, InboxFilter.needsYou), ("bots", .inbox, .bots),
                                    ("done", .inbox, .done), ("repos", .repos, .needsYou), ("settings", .settings, .needsYou)] {
            let state = UIState()
            state.tab = tab
            state.filter = filter
            host(name, PanelView(store: store, ui: state, close: {}))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (name, window) in windows {
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            exit(0)
        }
    }
}

/// `--check owner/repo`: headless sync against live GitHub, prints what the inbox would contain.
@MainActor
enum Check {
    static func run(store: Store, repo: String) {
        store.persists = false
        Task {
            await store.authenticate()
            print("auth:", store.me?.login ?? "nil", store.tokenSource?.rawValue ?? "", store.authError ?? "")
            if let err = await store.addRepo(repo) { print("add error:", err) }
            await store.pollAll()
            for item in store.items.sorted(by: { $0.createdAt > $1.createdAt }).prefix(25) {
                print(String(format: "%-15@ %-10@ #%-6d %@ @%@ low=%d  %@", item.kind.rawValue, item.state.rawValue, item.number,
                             shortAgo(item.createdAt), item.author, store.isLowPriority(item) ? 1 : 0, String(item.title.prefix(50))))
            }
            print("items:", store.items.count, "by kind:", Dictionary(grouping: store.items, by: \.kind.rawValue).mapValues(\.count))
            print("ci:", store.ci.mapValues { "\($0.branch) \($0.state.rawValue) failing=\($0.failing)" })
            print("errors:", store.repoErrors, "cursors:", store.repos.first?.cursors ?? [:])
            print("rate:", store.gh.rateRemaining ?? -1)
            await store.pollAll()
            print("second poll rate:", store.gh.rateRemaining ?? -1, "items:", store.items.count)
            exit(0)
        }
    }
}
