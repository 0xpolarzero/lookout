import Foundation
import SwiftUI

// MARK: - Persisted state

/// What Lookout remembers about a Claude session it has shown.
struct AgentEntry: Codable, Hashable, Identifiable {
    var id: String
    /// Kept sessions stay in your list (in your order); the others are pending until you keep or remove them.
    var kept = false
    /// Two letters or an emoji chosen by you; nil uses letters from the title.
    var label: String?
    /// Lookout's own read flag. It follows the app (new turns, opening the session, the sidebar dot) but can be
    /// changed here without touching the app.
    var unread = false
    /// Activity last seen (see `ClaudeSession.activity`).
    var seen = ""
    /// Removed at this activity: hidden until there is newer activity.
    var hiddenAt: String?
    var focusedAt: Date?
    /// SF Symbol picked by Jev (shown unless you set a label yourself).
    var icon: String?
    /// Icons you asked to replace: never offered again for this session.
    var rejectedIcons: [String]?
}

struct AgentsState: Codable {
    /// The Claude sessions extension. Off by default: Lookout is a GitHub app first.
    var enabled = false
    var enabledAt: Date?
    /// Pill strip: one tile per session, or just the counts.
    var expanded = false
    /// Kept entries in display order; pending ones anywhere (they're sorted by activity).
    var entries: [AgentEntry] = []
    /// Folders whose sessions never show up as pending ("" = scratch chats).
    var mutedFolders: [String] = []
    /// Sidebar dots at the last read, to notice when one appears or disappears.
    var appUnread: [String]?
    /// Sessions active recently are offered as pending the first time the extension sees them.
    var seeded = false
    /// Colour of each project (folder path → index into `Theme.projectColors`), picked once and then kept.
    var folderColors: [String: Int] = [:]
    /// Icons picked by Jev (TypeSafe) for each session; needs a TypeSafe API key (kept in the Keychain).
    var iconsEnabled = false
    /// Bumped when the palette changes: colours picked from an older one are mapped onto the new one (see `remapped`).
    var paletteVersion = AgentsState.palette
    static let palette = 3
    /// Palette 2 (green, violet, pink, cyan, lime, silver) onto 3 (violet, pink, cyan, silver): the nearest colour
    /// that's left, the two removed ones going to different neighbours so projects that differed still do.
    static let paletteRemap2 = [0: 2, 1: 0, 2: 1, 3: 2, 4: 3, 5: 3]

    /// A stored colour index from a palette of `version`, as an index into the current one; nil when the old
    /// palette isn't known (the colours are picked again).
    static func remapped(_ index: Int, from version: Int) -> Int? {
        switch version {
        case palette: index
        case 2: paletteRemap2[index]
        default: nil
        }
    }
    /// Bumped when the icon list changes, so icons picked from an older one are picked again.
    var iconsVersion = AgentsState.icons
    static let icons = 2

    init() {}

    /// A project gets a colour the first time one of its sessions is listed: the least used one.
    mutating func assignColor(_ folder: String) {
        guard !folder.isEmpty, folderColors[folder] == nil else { return }
        let used = folderColors.values.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        folderColors[folder] = Theme.projectColors.indices.min { used[$0, default: 0] < used[$1, default: 0] } ?? 0
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        enabledAt = try c.decodeIfPresent(Date.self, forKey: .enabledAt)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? false
        entries = try c.decodeIfPresent([AgentEntry].self, forKey: .entries) ?? []
        mutedFolders = try c.decodeIfPresent([String].self, forKey: .mutedFolders) ?? []
        appUnread = try c.decodeIfPresent([String].self, forKey: .appUnread)
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        iconsEnabled = try c.decodeIfPresent(Bool.self, forKey: .iconsEnabled) ?? false
        let version = try c.decodeIfPresent(Int.self, forKey: .paletteVersion) ?? 1
        folderColors = (try c.decodeIfPresent([String: Int].self, forKey: .folderColors) ?? [:])
            .compactMapValues { Self.remapped($0, from: version) }
        if try c.decodeIfPresent(Int.self, forKey: .iconsVersion) ?? 1 != Self.icons {
            for i in entries.indices {
                entries[i].icon = nil
                entries[i].rejectedIcons = nil
            }
        }
    }
}

enum ClaudeLink: Equatable {
    case off, ok, missing, unreadable
}

// MARK: - Rows

enum AgentStatus {
    case running, blocked, finished, idle
}

struct AgentRow: Identifiable, Hashable {
    var session: ClaudeSession
    var entry: AgentEntry
    var label: String
    /// The project's colour (nil for scratch chats).
    var color: Color?
    /// What it's doing, while it works.
    var activity: ClaudeActivity?
    /// Turn over, but subagents or commands it started are still running.
    var tasks: [ClaudeTask] = []
    /// The turn's summary as Markdown (**bold**, `code`), parsed once when the row is built; empty when there is none.
    var summaryText = AttributedString()

    /// The picked icon, unless you chose letters or an emoji yourself.
    var icon: String? { entry.label == nil ? entry.icon : nil }

    var id: String { session.id }
    var unread: Bool { entry.unread }
    var pending: Bool { !entry.kept }

    /// Mid-turn but stopped on you (a question, a plan): counts as waiting, not as working.
    var waitsForYou: Bool { session.running && activity?.waitsForYou == true }

    var status: AgentStatus {
        if waitsForYou { return .blocked }
        if session.running { return .running }
        if session.summary?.blocked == true { return .blocked }
        return entry.unread ? .finished : .idle
    }

    /// Needs you: stopped mid-turn on a question, or finished on one you haven't read yet.
    var isWaiting: Bool { waitsForYou || (!session.running && unread && session.summary?.blocked == true) }

    /// What the strip shows: amber waiting, blue done and unread, grey otherwise.
    var tint: Color? {
        if waitsForYou { return Theme.amber }
        guard !session.running, entry.unread else { return nil }
        return session.summary?.blocked == true ? Theme.amber : Theme.accent
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// The state in words, for VoiceOver and anywhere colour alone would carry it: waiting / working / finished / new activity.
    var stateName: String {
        // A session with new activity keeps what it left running: "new activity, 2 running".
        let running = tasks.isEmpty ? "" : ", \(tasks.count) running"
        if pending && !unread && status != .running && status != .blocked { return "new activity" + running }
        switch status {
        case .blocked: return "waiting"
        case .running: return "working"
        case .finished: return (unread ? "finished, unread" : "finished") + running
        case .idle: return (pending ? "new activity" : "idle") + running
        }
    }

    /// When the running turn began, if known.
    var workingSince: Date? { session.lastUserMessage ?? activity?.since }

    /// How long the turn has been going.
    func elapsed(now: Date = Date()) -> String {
        Self.duration(now.timeIntervalSince(workingSince ?? now))
    }

    /// The status column of a row: "Waiting", "Working 2m", "Finished 4m".
    func statusLabel(now: Date = Date()) -> String {
        if isWaiting { return "Waiting" }
        if session.running { return "Working \(elapsed(now: now))" }
        return "Finished \(shortAgo(session.lastActivity, now: now))"
    }

    /// The one thing that matters now: the question it is blocked on, what it is doing while it works, else the
    /// turn's summary.
    var headline: AttributedString {
        if session.running { return AttributedString(activity?.text ?? "Working") }
        return summaryText
    }

    /// For VoiceOver: "waiting, lcu, 2 minutes", and "3 running" for what a finished turn left behind.
    func spokenValue(now: Date = Date()) -> String {
        let state = isWaiting ? "waiting" : session.running ? "working" : "finished"
        let age = Self.spokenAge(now.timeIntervalSince(session.running ? session.lastUserMessage ?? session.lastActivity : session.lastActivity))
        var parts = [state + (unread && !isWaiting && !session.running ? ", unread" : ""), session.folderName, age]
        if !tasks.isEmpty { parts.append("\(tasks.count) running") }
        return parts.joined(separator: ", ")
    }

    /// For VoiceOver, after the value: the question or summary, then everything it left running by name (the row
    /// shows the first and a count).
    var spokenHint: String {
        let said = String(headline.characters)
        let running = tasks.isEmpty ? "" : "Running: " + tasks.map(\.title).joined(separator: ", ") + "."
        return [said, running].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func spokenAge(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "just now" }
        let (n, unit) = s < 3600 ? (s / 60, "minute") : s < 86400 ? (s / 3600, "hour") : (s / 86400, "day")
        return plural(n, unit)
    }
}

// MARK: - Groups

/// A run of rows under one header in the sessions list.
struct SessionGroup: Identifiable {
    enum Kind: Hashable {
        /// Every session that needs you, whichever project it is in.
        case waiting
        /// A project's kept sessions; "" is scratch chats.
        case project(String)
        /// Sessions with new activity that you haven't kept.
        case newActivity
    }

    var kind: Kind
    var rows: [AgentRow]

    var id: String {
        switch kind {
        case .waiting: "waiting"
        case .project(let folder): "project:" + folder
        case .newActivity: "new"
        }
    }

    var title: String {
        switch kind {
        case .waiting: "Waiting for you"
        case .project: rows.first?.session.folderName ?? "Scratch"
        case .newActivity: "New activity"
        }
    }

    /// How many New activity rows show before "+N more".
    static let newActivityCap = 8

    /// The list's order, which the bar's tiles follow: Waiting for you (most recent first), the projects in your
    /// order (the order their first kept session is listed in, so a group doesn't move when one of its sessions starts
    /// waiting), Scratch, then New activity (most recent first). A waiting session is in the first group only.
    static func build(kept: [AgentRow], pending: [AgentRow]) -> [SessionGroup] {
        let waiting = (kept + pending).filter(\.isWaiting).sorted { $0.session.lastActivity > $1.session.lastActivity }
        var folders: [String] = []
        for row in kept where !folders.contains(row.session.folderKey) { folders.append(row.session.folderKey) }
        // Scratch chats last of the projects, wherever the first one was kept.
        folders = folders.filter { !$0.isEmpty } + folders.filter(\.isEmpty)
        var out: [SessionGroup] = []
        if !waiting.isEmpty { out.append(SessionGroup(kind: .waiting, rows: waiting)) }
        for folder in folders {
            let rows = kept.filter { $0.session.folderKey == folder && !$0.isWaiting }
            if !rows.isEmpty { out.append(SessionGroup(kind: .project(folder), rows: rows)) }
        }
        let new = pending.filter { !$0.isWaiting }
        if !new.isEmpty { out.append(SessionGroup(kind: .newActivity, rows: new)) }
        return out
    }
}

// MARK: - Labels

enum AgentLabel {
    private static let skipped: Set<String> = ["a", "an", "the", "of", "for", "and", "to", "in", "on", "with", "my", "is"]

    /// Letter pairs to try, best first: initials of the first two words, then other pairs, then the first letters.
    /// Words naming the project are left out (its colour already says it): "LCU update notifications" in lcu → UN.
    static func candidates(_ title: String, folder: String? = nil) -> [String] {
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let folderWords = Set(([folder ?? ""] + (folder ?? "").split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .map { $0.lowercased() }.filter { $0.count >= 2 })
        let meaningful = words.filter { !skipped.contains($0.lowercased()) && !folderWords.contains($0.lowercased()) }
        let use = meaningful.isEmpty ? words : meaningful
        var out: [String] = []
        func add(_ s: String) {
            let u = s.uppercased()
            if u.count == 2, !out.contains(u) { out.append(u) }
        }
        if use.count >= 2 {
            add("\(use[0].prefix(1))\(use[1].prefix(1))")
            for j in 2..<min(use.count, 5) { add("\(use[0].prefix(1))\(use[j].prefix(1))") }
            for i in 1..<min(use.count, 4) { for j in (i + 1)..<min(use.count, 5) { add("\(use[i].prefix(1))\(use[j].prefix(1))") } }
        }
        if let first = use.first {
            add(String(first.prefix(2)))
            let chars = Array(first)
            for c in chars.dropFirst(2) { add("\(chars[0])\(c)") }
        }
        return out
    }

    /// Custom labels win; generated ones avoid every label already taken, falling back to a digit.
    static func assign(_ items: [(id: String, title: String, custom: String?)], folders: [String: String] = [:]) -> [String: String] {
        var taken = Set(items.compactMap { $0.custom?.uppercased() })
        var result: [String: String] = [:]
        for item in items {
            if let custom = item.custom, !custom.isEmpty {
                result[item.id] = custom
                continue
            }
            let options = candidates(item.title, folder: folders[item.id])
            var label = options.first { !taken.contains($0) }
            if label == nil {
                let base = String((options.first ?? "S").prefix(1))
                label = (1...99).lazy.map { "\(base)\($0)" }.first { !taken.contains($0) }
            }
            taken.insert(label!)
            result[item.id] = label!
        }
        return result
    }

    /// Digits, # and * count as emoji in Unicode; real emoji are past Latin-1.
    static func isEmoji(_ label: String) -> Bool {
        guard let scalar = label.first?.unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && scalar.value > 0xFF
    }

    /// Up to two characters, or one emoji.
    static func sanitize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if isEmoji(String(first)) { return String(first) }
        let letters = String(trimmed.filter { !$0.isWhitespace }.prefix(2))
        return letters.isEmpty ? nil : letters.uppercased()
    }
}

// MARK: - Store

/// What the views derive from the agents and the read sessions, computed once per change.
struct AgentCache {
    var rows: (kept: [AgentRow], pending: [AgentRow])
    var all: [AgentRow]
    var groups: [SessionGroup]
    var counts: (blocked: Int, done: Int)
    var folders: [String]
    var entries: [String: AgentEntry]
    var labels: [String: String]
}

extension Store {
    var agentsEnabled: Bool { agents.enabled }

    /// Derived rows, memoized: views read these dozens of times per render. The getters still read the observed
    /// properties, so SwiftUI keeps tracking them; `agentCache` is dropped whenever one of them changes.
    private var cache: AgentCache {
        let state = agents, sessions = claudeSessions, activity = claudeActivity, tasks = claudeTasks
        if let agentCache { return agentCache }
        let built = buildAgentCache(state, sessions, activity, tasks)
        agentCache = built
        return built
    }

    private func buildAgentCache(_ state: AgentsState, _ sessions: [String: ClaudeSession],
                                 _ activity: [String: ClaudeActivity], _ tasks: [String: [ClaudeTask]]) -> AgentCache {
        let byID = Dictionary(state.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let muted = Set(state.mutedFolders)
        let ordered = state.entries.filter(\.kept).compactMap { e in sessions[e.id].map { ($0, e) } }
        var folderOrder: [String] = []
        for (s, _) in ordered where !folderOrder.contains(s.folderKey) { folderOrder.append(s.folderKey) }
        let kept = folderOrder.flatMap { folder in ordered.filter { $0.0.folderKey == folder } }
        let pending = sessions.values
            .compactMap { s -> (ClaudeSession, AgentEntry)? in
                guard let e = byID[s.id], !e.kept, e.hiddenAt == nil, !muted.contains(s.folderKey) else { return nil }
                return (s, e)
            }
            .sorted { $0.0.lastActivity > $1.0.lastActivity }
        let all = kept + pending
        let labels = AgentLabel.assign(all.map { (id: $0.0.id, title: $0.0.title, custom: $0.1.label) },
                                       folders: Dictionary(all.map { ($0.0.id, $0.0.folderName) }, uniquingKeysWith: { a, _ in a }))
        func rows(_ list: [(ClaudeSession, AgentEntry)]) -> [AgentRow] {
            list.map { makeRow($0.0, $0.1, label: labels[$0.0.id]) }
        }
        let keptRows = rows(kept), pendingRows = rows(pending)
        let allRows = keptRows + pendingRows
        // Summaries of sessions that are gone (or have a newer one) needn't stay parsed.
        if summaryTexts.count > allRows.count + 32 {
            let current = Set(allRows.compactMap { $0.session.summary?.detail })
            summaryTexts = summaryTexts.filter { current.contains($0.key) }
        }
        let unread = allRows.filter { $0.unread && !$0.session.running }
        let blocked = unread.filter { $0.session.summary?.blocked == true }.count
        var folders: [String] = []
        for row in allRows where !row.session.folderKey.isEmpty && !folders.contains(row.session.folderKey) {
            folders.append(row.session.folderKey)
        }
        return AgentCache(rows: (keptRows, pendingRows), all: allRows, groups: SessionGroup.build(kept: keptRows, pending: pendingRows),
                          counts: (blocked + allRows.filter(\.waitsForYou).count, unread.count - blocked),
                          folders: folders, entries: byID, labels: Dictionary(allRows.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Kept sessions in your order, grouped by project (projects in the order their first session appears), then
    /// pending ones, most recent first. Labels are unique across both.
    var agentRows: (kept: [AgentRow], pending: [AgentRow]) { cache.rows }

    /// A row for any session, kept or not (search results show sessions Lookout hasn't listed).
    func row(_ session: ClaudeSession, _ entry: AgentEntry? = nil, label: String? = nil) -> AgentRow {
        makeRow(session, entry ?? cache.entries[session.id], label: label)
    }

    private func makeRow(_ session: ClaudeSession, _ entry: AgentEntry?, label: String?) -> AgentRow {
        AgentRow(session: session, entry: entry ?? AgentEntry(id: session.id),
                 label: label ?? AgentLabel.candidates(session.title, folder: session.folderName).first ?? "··",
                 color: projectColor(session.folderKey),
                 activity: session.running ? claudeActivity[session.id] : nil,
                 tasks: session.running ? [] : claudeTasks[session.id] ?? [],
                 summaryText: summaryText(session.summary?.detail))
    }

    /// Parsed once per distinct summary (the rows are rebuilt on every change, the summaries rarely change).
    private func summaryText(_ detail: String?) -> AttributedString {
        guard let detail, !detail.isEmpty else { return AttributedString() }
        if let hit = summaryTexts[detail] { return hit }
        let text = (try? AttributedString(markdown: detail, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(detail)
        summaryTexts[detail] = text
        return text
    }

    func projectColor(_ folder: String) -> Color? {
        guard !folder.isEmpty, let i = agents.folderColors[folder] else { return nil }
        return Theme.projectColors[i % Theme.projectColors.count]
    }

    /// The sessions list in its order: every group, whole (see `SessionGroup.build`).
    var sessionGroups: [SessionGroup] { cache.groups }

    /// The groups as the hub lists them: New activity cut to its cap unless `expanded`, and how many that hid.
    func listedGroups(expanded: Bool) -> (groups: [SessionGroup], hidden: Int) {
        var groups = cache.groups, hidden = 0
        if !expanded, let i = groups.firstIndex(where: { $0.kind == .newActivity }), groups[i].rows.count > SessionGroup.newActivityCap {
            hidden = groups[i].rows.count - SessionGroup.newActivityCap
            groups[i].rows = Array(groups[i].rows.prefix(SessionGroup.newActivityCap))
        }
        return (groups, hidden)
    }

    func setProjectColor(_ folder: String, _ index: Int) {
        agents.folderColors[folder] = index
    }

    /// Every session matching all the words (title or folder), best first: title starts with the query, kept ones,
    /// then the most recent. For the switcher's type-to-find.
    func searchSessions(_ query: String, limit: Int = 8) -> [AgentRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let labels = cache.labels
        let kept = Set(agents.entries.filter(\.kept).map(\.id))
        // 3: title starts with it, 2: the title has every word, 1: only with the folder's name.
        func score(_ s: ClaudeSession) -> Int {
            let title = s.title.lowercased()
            if words.allSatisfy({ title.contains($0) }) { return title.hasPrefix(words[0]) ? 3 : 2 }
            let both = title + " " + s.folderName.lowercased()
            return words.allSatisfy { both.contains($0) } ? 1 : 0
        }
        return claudeSessions.values
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let ka = kept.contains(a.0.id), kb = kept.contains(b.0.id)
                if ka != kb { return ka }
                return a.0.lastActivity > b.0.lastActivity
            }
            .map(\.0)
            .prefix(limit)
            .map { row($0, label: labels[$0.id]) }
    }

    var allAgentRows: [AgentRow] { cache.all }

    /// Unread sessions waiting on you (amber) and the other unread finished ones (blue).
    var agentCounts: (blocked: Int, done: Int) { cache.counts }

    /// Projects with a session in your list or pending, in the order they're listed: where a new session can start.
    var agentFolders: [String] { cache.folders }

    /// Every project a session has been seen in, the one with the most recent session first: where New session offers
    /// to start one.
    var recentFolders: [String] {
        var latest: [String: Date] = [:]
        for session in claudeSessions.values where !session.folderKey.isEmpty {
            latest[session.folderKey] = max(latest[session.folderKey] ?? .distantPast, session.lastActivity)
        }
        return latest.keys.sorted { latest[$0]! != latest[$1]! ? latest[$0]! > latest[$1]! : $0 < $1 }
    }

    var knownFolders: [String] {
        Array(Set(claudeSessions.values.map(\.folderKey))).sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return URL(fileURLWithPath: a).lastPathComponent.lowercased() < URL(fileURLWithPath: b).lastPathComponent.lowercased()
        }
    }

    // MARK: Reading the app

    /// Re-reads the app's session files and sidebar dots, off the main thread. Called on file changes (and a slow
    /// timer as backup); calls made while a read is running fold into one more read.
    func refreshClaude() {
        guard agents.enabled else { return }
        claudeFeed.request(full: true, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// Re-reads only the sidebar dots (the app writes them lazily): the sessions are those of the last read.
    func refreshUnread() {
        guard agents.enabled else { return }
        claudeFeed.request(full: false, unreadOnly: true, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// What each working session is doing, from the tail of its transcript (only files that changed are read), and
    /// the background work left running by sessions whose turn is over.
    func refreshActivity() {
        guard agents.enabled else { return }
        claudeFeed.request(full: false, stamp: claudeStamp) { [weak self] in self?.applyClaude($0) }
    }

    /// Takes a read of the app back onto the main thread; properties are only set when they changed.
    private func applyClaude(_ snapshot: ClaudeSnapshot) {
        guard agents.enabled, snapshot.stamp.generation == claudeStamp.generation else { return }
        // You changed something since this read was asked for: it could undo that, so read again instead.
        if snapshot.sessions != nil, snapshot.stamp.revision != claudeStamp.revision {
            refreshClaude()
            return
        }
        if let link = snapshot.link, claudeLink != link { claudeLink = link }
        if let sessions = snapshot.sessions {
            ingesting = true
            ingest(sessions, appUnread: snapshot.appUnread, claudeFrontmost: snapshot.frontmost)
            ingesting = false
        }
        if let next = snapshot.activity, next != claudeActivity { claudeActivity = next }
        if let next = snapshot.tasks, next != claudeTasks { claudeTasks = next }
        if snapshot.sessions != nil { pickIcons() }
        scheduleClaudeTick()
    }

    /// Folds a fresh read of the app into what Lookout remembers. Pure apart from `now`, so tests drive it directly.
    func ingest(_ sessions: [ClaudeSession], appUnread: Set<String>?, claudeFrontmost: Bool, now: Date = Date()) {
        var state = agents
        let live = sessions.filter { !$0.isArchived }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let muted = Set(state.mutedFolders)
        let previousDots = state.appUnread.map(Set.init)
        // The session shown in the app right now: the most recently focused one, if the app is in front.
        let viewing = claudeFrontmost ? live.max { ($0.lastFocused ?? .distantPast) < ($1.lastFocused ?? .distantPast) }?.id : nil
        let since = state.enabledAt ?? now

        // First read: offer only the few most recent sessions, not a whole day's worth.
        let seedIDs = state.seeded ? [] : Set(live.filter { now.timeIntervalSince($0.lastActivity) < 24 * 3600 }
            .sorted { $0.lastActivity > $1.lastActivity }.prefix(8).map(\.id))

        // Archived (or deleted) sessions leave Lookout.
        state.entries.removeAll { byID[$0.id] == nil }
        var index = Dictionary(uniqueKeysWithValues: state.entries.enumerated().map { ($1.id, $0) })

        for session in live {
            guard let i = index[session.id] else {
                // First sight of a session: offered as pending if it moved recently enough to matter.
                let recent = state.seeded ? session.lastActivity > since : seedIDs.contains(session.id)
                guard recent, !muted.contains(session.folderKey) else { continue }
                var entry = AgentEntry(id: session.id, seen: session.activity, focusedAt: session.lastFocused)
                // The sidebar dot lags; a session that just finished a turn elsewhere is unread already.
                let finished = state.seeded && session.completedTurns > 0 && session.id != viewing && !session.running
                entry.unread = appUnread?.contains(session.id) == true || finished
                state.entries.append(entry)
                index[session.id] = state.entries.count - 1
                continue
            }
            var entry = state.entries[i]
            if entry.seen != session.activity {
                let turnsBefore = Int(entry.seen.split(separator: "|").first ?? "") ?? 0
                if session.completedTurns > turnsBefore {
                    // A turn finished: unread, unless you were looking at it in the app.
                    entry.unread = session.id != viewing
                } else {
                    // You sent a message, so you've seen it.
                    entry.unread = false
                }
                entry.seen = session.activity
                if entry.hiddenAt != nil, entry.hiddenAt != session.activity { entry.hiddenAt = nil }
            }
            if let focused = session.lastFocused, focused > (entry.focusedAt ?? .distantPast) {
                // Opened in the app (or from Lookout).
                if entry.focusedAt != nil { entry.unread = false }
                entry.focusedAt = focused
            }
            // The sidebar dot appearing or disappearing wins; while it doesn't change, your choice here stands.
            if let dots = appUnread, let before = previousDots {
                let was = before.contains(session.id), now = dots.contains(session.id)
                if !was && now { entry.unread = true }
                if was && !now { entry.unread = false }
            }
            state.entries[i] = entry
        }

        // Forget long-gone pending sessions so the state file stays small.
        state.entries.removeAll { e in
            guard !e.kept, e.hiddenAt != nil, let s = byID[e.id] else { return false }
            return now.timeIntervalSince(s.lastActivity) > 30 * 86400
        }
        if let appUnread { state.appUnread = appUnread.sorted() }
        state.seeded = true
        for folder in state.entries.compactMap({ byID[$0.id]?.folderKey }) { state.assignColor(folder) }
        if state.entries != agents.entries || state.appUnread != agents.appUnread || state.seeded != agents.seeded
            || state.folderColors != agents.folderColors {
            agents = state
        }
        // Only on change: the views observing these redraw on every assignment.
        if claudeSessions != byID { claudeSessions = byID }
    }

    // MARK: Actions

    private func mutateAgent(_ id: String, _ f: (inout AgentEntry) -> Void) {
        guard let i = agents.entries.firstIndex(where: { $0.id == id }) else { return }
        f(&agents.entries[i])
    }

    func openAgent(_ id: String) {
        if let interceptOpen { interceptOpen("Open in Claude · \(claudeSessions[id]?.title ?? id)") } else { Claude.open(id) }
        mutateAgent(id) { $0.unread = false }
    }

    func startAgent(in folder: String) {
        if let interceptOpen { interceptOpen("New Claude session in \(folder.isEmpty ? "Scratch" : URL(fileURLWithPath: folder).lastPathComponent)"); return }
        Claude.newSession(in: folder)
    }

    func toggleAgentRead(_ id: String) {
        mutateAgent(id) { $0.unread.toggle() }
    }

    /// Sessions you could add: not kept yet, best match first (every word must appear in the title or folder);
    /// with no query, the most recent ones.
    func agentCandidates(matching query: String, limit: Int = 6) -> [ClaudeSession] {
        let kept = Set(agents.entries.filter(\.kept).map(\.id))
        let words = query.lowercased().split(separator: " ").map(String.init)
        return claudeSessions.values
            .filter { !kept.contains($0.id) }
            .filter { s in
                let haystack = (s.title + " " + s.folderName).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { a, b in
                // Titles starting with the query first, then the most recent.
                let pa = words.first.map { a.title.lowercased().hasPrefix($0) } ?? false
                let pb = words.first.map { b.title.lowercased().hasPrefix($0) } ?? false
                return pa != pb ? pa : a.lastActivity > b.lastActivity
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Kept sessions go to the end of your list (any session: it doesn't have to be pending).
    func keepAgent(_ id: String) {
        if !agents.entries.contains(where: { $0.id == id }), let session = claudeSessions[id] {
            agents.entries.append(AgentEntry(id: id, seen: session.activity, focusedAt: session.lastFocused))
            agents.assignColor(session.folderKey)
        }
        guard let i = agents.entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = agents.entries.remove(at: i)
        entry.kept = true
        entry.hiddenAt = nil
        agents.entries.append(entry)
    }

    /// Pending: hidden until its next activity. Kept: leaves your list (and comes back as pending on new activity).
    /// Offers an undo (see `offerUndo`).
    func dismissAgent(_ id: String) {
        guard let before = agents.entries.first(where: { $0.id == id }) else { return }
        mutateAgent(id) {
            $0.kept = false
            $0.hiddenAt = $0.seen
        }
        let title = claudeSessions[id]?.title ?? "session"
        offerUndo?("Hidden \u{201C}\(title)\u{201D}") { [weak self] in
            self?.mutateAgent(id) {
                $0.kept = before.kept
                $0.hiddenAt = before.hiddenAt
            }
        }
    }

    /// Keeps every session under New activity, in the order they are listed, the ones its list cuts to "+N more"
    /// too. A pending session promoted to Waiting for you isn't under it, so it stays as it was. The ids are taken
    /// first: keeping one rebuilds the groups.
    func keepAllAgents() {
        let ids = cache.groups.first { $0.kind == .newActivity }?.rows.map(\.id) ?? []
        for id in ids { keepAgent(id) }
    }

    /// Reordering stays within a project: dropping on another project's session does nothing. The project's sessions
    /// trade places among the slots they already hold, so the projects keep their own order.
    func moveAgent(_ id: String, onto target: String) {
        guard id != target, let folder = claudeSessions[id]?.folderKey, claudeSessions[target]?.folderKey == folder else { return }
        let slots = agents.entries.indices.filter { agents.entries[$0].kept && claudeSessions[agents.entries[$0].id]?.folderKey == folder }
        var order = slots.map { agents.entries[$0] }
        guard let from = order.firstIndex(where: { $0.id == id }), let to = order.firstIndex(where: { $0.id == target }) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        for (slot, entry) in zip(slots, order) { agents.entries[slot] = entry }
    }

    /// The session above (-1) or below (+1) this one in its project's group, if it has one: what Move up and Move down
    /// swap with.
    private func neighbour(of id: String, _ step: Int) -> String? {
        guard let group = cache.groups.first(where: { g in
            if case .project = g.kind { return g.rows.contains { $0.id == id } }
            return false
        }), let i = group.rows.firstIndex(where: { $0.id == id }), group.rows.indices.contains(i + step) else { return nil }
        return group.rows[i + step].id
    }

    func canMoveAgent(_ id: String, by step: Int) -> Bool { neighbour(of: id, step) != nil }

    /// One place up (-1) or down (+1) within its project.
    func moveAgent(_ id: String, by step: Int) {
        if let target = neighbour(of: id, step) { moveAgent(id, onto: target) }
    }

    // MARK: Icons (Jev)

    /// Picks icons for listed sessions that don't have one yet, one request at a time.
    func pickIcons() {
        guard agents.enabled, agents.iconsEnabled, iconTask == nil, Date() >= iconsPausedUntil,
              let key = typesafeKey, !key.isEmpty else { return }
        let rows = allAgentRows
        guard let next = rows.first(where: { $0.entry.icon == nil && $0.entry.label == nil }) else { return }
        let session = next.session
        let cliID = session.cliID
        let reader = activityReader
        iconTask = Task { [weak self] in
            // The transcript's head (256 KB, parsed) is read off the main thread, which may also be waiting on the
            // activity reader's lock.
            let first = await Task.detached(priority: .utility) {
                cliID.flatMap { reader.transcript($0) }.flatMap { Claude.firstMessage(head: Claude.head(of: $0)) }
            }.value
            guard let self else { return }
            // Nothing to go on yet (a brand-new session the app hasn't named): wait for the next read.
            let rows = self.allAgentRows
            guard first != nil || session.title != "Untitled session",
                  let current = rows.first(where: { $0.id == session.id }), current.entry.icon == nil, current.entry.label == nil else {
                self.iconTask = nil
                if first != nil || session.title != "Untitled session" { self.pickIcons() }
                return
            }
            let used = Set(rows.compactMap(\.entry.icon)).union(current.entry.rejectedIcons ?? [])
            let open = SessionIcons.open(excluding: used)
            guard !open.isEmpty else { self.iconTask = nil; return }
            var state = ["session title": session.title, "project": session.folderName]
            if let first { state["first message"] = first }
            let client = JevClient(key: key)
            do {
                // Two questions (Jev takes at most 255 options): what kind of icon, then which one.
                let kinds = try await client.choose(open.map(\.category.key),
                    hints: Dictionary(uniqueKeysWithValues: open.map { ($0.category.key, $0.category.about) }),
                    for: state, instructions: "Which kind of icon would best show what this coding session is about?")
                let options = SessionIcons.shortlist(open, probabilities: kinds.probabilities)
                let pick = try await client.choose(options, hints: SessionIcons.hints, for: state, instructions:
                    "Pick the icon that best shows what this coding session is about, so its owner can tell it apart from their other sessions at a glance.")
                self.mutateAgent(session.id) { $0.icon = pick.choice }
                self.iconError = nil
                self.iconTask = nil
                self.pickIcons()
            } catch {
                self.iconError = error.localizedDescription
                self.iconTask = nil
                // A rejected key waits for a new one; anything else retries in a while.
                self.iconsPausedUntil = (error as? JevClient.Failure)?.message.contains("API key") == true
                    ? .distantFuture : Date().addingTimeInterval(600)
                self.scheduleClaudeTick()
            }
        }
    }

    /// Whether icons can be picked now: on, with a key. Without that a session keeps the icon it has, but can't get another.
    var canPickIcons: Bool { agents.enabled && agents.iconsEnabled && hasTypesafeKey }

    /// Replaces a session's icon (the old one is never offered again for it). Not while nothing could pick the next:
    /// the session would be left with none.
    func repickIcon(_ id: String) {
        guard canPickIcons else { return }
        mutateAgent(id) {
            if let icon = $0.icon { $0.rejectedIcons = ($0.rejectedIcons ?? []) + [icon] }
            $0.icon = nil
        }
        pickIcons()
    }

    var typesafeKey: String? {
        // Filled in by the read at launch (see `Store.start`), never from the main thread.
        typesafeKeyCache
    }

    func setTypesafeKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { Keychain.delete(Keychain.typesafe) } else { Keychain.write(trimmed, Keychain.typesafe) }
        typesafeKeyCache = trimmed
        hasTypesafeKey = !trimmed.isEmpty
        iconError = nil
        iconsPausedUntil = .distantPast
        pickIcons()
    }

    func setIconsEnabled(_ on: Bool) {
        agents.iconsEnabled = on
        iconsPausedUntil = .distantPast
        pickIcons()
    }

    func setAgentLabel(_ id: String, _ label: String?) {
        mutateAgent(id) { $0.label = label.flatMap(AgentLabel.sanitize) }
    }

    func setFolderMuted(_ folder: String, _ muted: Bool) {
        agents.mutedFolders.removeAll { $0 == folder }
        if muted { agents.mutedFolders.append(folder) }
    }

    /// Mutes a project from its menu: its sessions stop arriving as new activity. Offers an undo (see `offerUndo`).
    func muteFolder(_ folder: String) {
        setFolderMuted(folder, true)
        let name = folder.isEmpty ? "Scratch" : URL(fileURLWithPath: folder).lastPathComponent
        offerUndo?("Muted \(name)") { [weak self] in self?.setFolderMuted(folder, false) }
    }

    func setAgentsEnabled(_ on: Bool) {
        guard on != agents.enabled else { return }
        claudeStamp.generation += 1
        agents.enabled = on
        if on {
            agents.enabledAt = agents.enabledAt ?? Date()
            if persists { watchClaude() } else { refreshClaude() }
        } else {
            if persists { watchClaude() }
            claudeSessions = [:]
            claudeLink = .off
        }
        onAgentsEnabledChange?(on)
    }
}
