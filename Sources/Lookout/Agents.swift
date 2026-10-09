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
    /// Bumped when the palette changes, so colours picked from an older one are picked again.
    var paletteVersion = AgentsState.palette
    static let palette = 2
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
        folderColors = version == Self.palette ? try c.decodeIfPresent([String: Int].self, forKey: .folderColors) ?? [:] : [:]
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

/// Where a session is listed, in this order: what needs you, what finished, what's working, your pinned ones, then
/// the recent rest: unpinned and quiet, listed for `Store.recentWindow` after their last activity so you can pin them.
enum AgentGroup: Int, CaseIterable, Identifiable {
    case needsYou, done, working, pinned, idle
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .done: "Done"
        case .working: "Working"
        case .pinned: "Pinned"
        case .idle: "Recent"
        }
    }
}

/// One group's sessions, as the bar and the lists show them.
struct AgentSection: Identifiable, Hashable {
    let group: AgentGroup
    let rows: [AgentRow]
    var id: AgentGroup { group }
}

struct AgentRow: Identifiable, Hashable {
    var session: ClaudeSession
    var entry: AgentEntry
    var label: String
    /// The project's colour (nil for scratch chats).
    var color: Color?
    /// The project's name as the lists say it, with enough of its path to tell it from another of the same name.
    var project: String?
    /// What it's doing, while it works.
    var activity: ClaudeActivity?
    /// Turn over, but subagents or commands it started are still running.
    var tasks: [ClaudeTask] = []
    /// The turn's summary as Markdown (**bold**, `code`), parsed once when the row is built; empty when there is none.
    var summaryText = AttributedString()

    /// The picked icon, unless you chose letters or an emoji yourself.
    var icon: String? { entry.label == nil ? entry.icon : nil }

    /// No icon yet, and no label of your own to show instead.
    var needsIcon: Bool { entry.icon == nil && entry.label == nil }

    var projectName: String { project ?? session.folderName }

    var id: String { session.id }
    var unread: Bool { entry.unread }
    var pending: Bool { !entry.kept }

    /// Mid-turn but stopped on you (a question, a plan): counts as waiting, not as working.
    var waitsForYou: Bool { session.running && activity?.waitsForYou == true }

    var group: AgentGroup {
        if waitsForYou { return .needsYou }
        if session.running { return .working }
        if entry.unread && session.summary?.blocked == true { return .needsYou }
        // Turn over but subagents or commands it started still run: it isn't done, it picks up again when they finish.
        if !tasks.isEmpty { return .working }
        if entry.unread { return .done }
        return entry.kept ? .pinned : .idle
    }

    var status: AgentStatus {
        if waitsForYou { return .blocked }
        if session.running { return .running }
        if session.summary?.blocked == true { return .blocked }
        if !tasks.isEmpty { return .running }
        return entry.unread ? .finished : .idle
    }

    /// What the strip shows: amber waiting, blue done and unread, grey otherwise (working, or left something running).
    var tint: Color? {
        switch group {
        case .needsYou: Theme.amber
        case .done: Theme.accent
        default: nil
        }
    }

    /// When the running turn began, if known.
    var workingSince: Date? { session.lastUserMessage ?? activity?.since }

    /// "Running swift test · 3m" while working: the current step, and how long the turn has run.
    func workingText(now: Date = Date()) -> String {
        let elapsed = Self.duration(now.timeIntervalSince(workingSince ?? now))
        return "\(activity?.text ?? "Working") · \(elapsed)"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    func statusText(now: Date = Date()) -> String {
        switch status {
        case .running: "working"
        case .blocked: "waiting"
        case .finished: shortAgo(session.lastActivity, now: now) == "now" ? "done just now" : "done \(shortAgo(session.lastActivity, now: now))"
        case .idle: shortAgo(session.lastActivity, now: now)
        }
    }

    /// The state in words, for VoiceOver and anywhere colour alone would carry it: waiting / working / done / pending.
    var stateName: String {
        // A pending session keeps what it left running: "pending, 2 running".
        let running = tasks.isEmpty ? "" : ", \(tasks.count) running"
        switch status {
        case .blocked: return "waiting"
        case .running: return "working" + running
        case .finished: return (unread ? "done, unread" : "done") + running
        case .idle: return (entry.kept ? "pinned" : "idle") + running
        }
    }

    /// What VoiceOver reads after the title, on every surface that shows a session: its state and its project, so two sessions
    /// with the same title in `customer-a/app` and `customer-b/app` don't sound alike, and the age the row shows: how long the
    /// turn has run while it works, else since it last did anything.
    func spokenValue(now: Date = Date()) -> String {
        let since = session.running ? workingSince ?? now : session.lastActivity
        return "\(stateName), \(projectName), \(Self.spokenAge(now.timeIntervalSince(since)))"
    }

    /// For VoiceOver, after the value: what it left running, by name (the row shows a count, and the tooltip lists them).
    var spokenHint: String {
        guard !tasks.isEmpty else { return "Opens it in Claude" }
        return "Opens it in Claude. Running: " + tasks.map(\.title).joined(separator: ", ") + "."
    }

    /// `shortAgo` and `duration` in words, counted the same way.
    static func spokenAge(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "just now" }
        let (n, unit) = s < 3600 ? (s / 60, "minute") : s < 86400 ? (s / 3600, "hour") : (s / 86400, "day")
        return plural(n, unit)
    }

    /// "3 running": what's left in the background, after the status.
    var tasksText: String? { tasks.isEmpty ? nil : "\(tasks.count) running" }

    var statusColor: Color {
        switch status {
        case .running: Theme.claude
        case .blocked: entry.unread || waitsForYou ? Theme.amber : Theme.secondary
        case .finished: Theme.accent
        case .idle: Theme.tertiary
        }
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

    /// Up to two characters, or one emoji.
    static func sanitize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        // Digits, # and * count as emoji in Unicode; real emoji are past Latin-1.
        if let scalar = first.unicodeScalars.first, scalar.properties.isEmoji, scalar.value > 0xFF {
            return String(first)
        }
        let letters = String(trimmed.filter { !$0.isWhitespace }.prefix(2))
        return letters.isEmpty ? nil : letters.uppercased()
    }
}

// MARK: - Store

/// What the views derive from the agents and the read sessions, computed once per change.
struct AgentCache {
    var rows: (kept: [AgentRow], pending: [AgentRow])
    var all: [AgentRow]
    var sections: [AgentSection]
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
        _ = recentTick
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
        // Unpinned ones stay while they work or wait to be read, and for an hour after their last activity; then
        // only a search finds them.
        let now = Date(), cutoff = now.addingTimeInterval(-Self.recentWindow)
        let pending = sessions.values
            .compactMap { s -> (ClaudeSession, AgentEntry)? in
                guard let e = byID[s.id], !e.kept, e.hiddenAt == nil, !muted.contains(s.folderKey) else { return nil }
                guard s.running || e.unread || tasks[s.id]?.isEmpty == false || s.lastActivity > cutoff else { return nil }
                return (s, e)
            }
            .sorted { $0.0.lastActivity > $1.0.lastActivity }
        // The list is read again when the next of them ages out.
        let quiet = pending.filter { !$0.0.running && !$0.1.unread && tasks[$0.0.id]?.isEmpty != false }.map { $0.0.lastActivity + Self.recentWindow }
        scheduleRecentExpiry(quiet.min().map { $0.timeIntervalSince(now) })
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
        var folders: [String] = []
        for row in allRows where !row.session.folderKey.isEmpty && !folders.contains(row.session.folderKey) {
            folders.append(row.session.folderKey)
        }
        // Pinned ones in your order, recent ones by recency (as pending already is), the rest most recent first.
        let sections = AgentGroup.allCases.compactMap { group -> AgentSection? in
            var rows = allRows.filter { $0.group == group }
            if group.rawValue < AgentGroup.pinned.rawValue {
                rows.sort { $0.session.lastActivity > $1.session.lastActivity }
            }
            return rows.isEmpty ? nil : AgentSection(group: group, rows: rows)
        }
        return AgentCache(rows: (keptRows, pendingRows), all: allRows, sections: sections,
                          counts: (allRows.filter { $0.group == .needsYou }.count, allRows.filter { $0.group == .done }.count),
                          folders: folders, entries: byID, labels: Dictionary(allRows.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }))
    }

    /// How long an unpinned session that went quiet stays listed.
    static let recentWindow: TimeInterval = 3600

    private func scheduleRecentExpiry(_ delay: TimeInterval?) {
        recentExpiry?.invalidate()
        recentExpiry = nil
        guard let delay else { return }
        let timer = Timer(timeInterval: max(1, delay + 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recentTick &+= 1 }
        }
        RunLoop.main.add(timer, forMode: .common)
        recentExpiry = timer
    }

    /// Kept sessions in your order, grouped by project (projects in the order their first session appears), then
    /// pending ones, most recent first. Labels are unique across both.
    var agentRows: (kept: [AgentRow], pending: [AgentRow]) { cache.rows }

    /// The listed sessions by group (`AgentGroup`), empty groups left out.
    var agentSections: [AgentSection] { cache.sections }

    /// A row for any session, kept or not (search results show sessions Lookout hasn't listed).
    func row(_ session: ClaudeSession, _ entry: AgentEntry? = nil, label: String? = nil) -> AgentRow {
        makeRow(session, entry ?? cache.entries[session.id], label: label)
    }

    private func makeRow(_ session: ClaudeSession, _ entry: AgentEntry?, label: String?) -> AgentRow {
        AgentRow(session: session, entry: entry ?? AgentEntry(id: session.id),
                 // Sessions outside the cache (hidden ones found through search) still show their saved label.
                 label: label ?? entry?.label ?? AgentLabel.candidates(session.title, folder: session.folderName).first ?? "··",
                 color: projectColor(session.folderKey), project: folderName(session.folderKey),
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

    /// Kept sessions split by project, for the strip's gaps and the Agents tab's headers.
    func groups(_ rows: [AgentRow]) -> [[AgentRow]] {
        var out: [[AgentRow]] = []
        for row in rows {
            if let last = out.last?.last, last.session.folderKey == row.session.folderKey {
                out[out.count - 1].append(row)
            } else {
                out.append([row])
            }
        }
        return out
    }

    func setProjectColor(_ folder: String, _ index: Int) {
        agents.folderColors[folder] = index
    }

    /// Every session matching all the words (title or folder), best first: title starts with the query, kept ones,
    /// then the most recent. For the hub's search; its list scrolls, so none is left out.
    func searchSessions(_ query: String) -> [AgentRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let labels = cache.labels
        let kept = Set(agents.entries.filter(\.kept).map(\.id))
        // 3: title starts with it, 2: the title has every word, 1: only with the folder's name.
        func score(_ s: ClaudeSession) -> Int {
            let title = s.title.lowercased()
            if words.allSatisfy({ title.contains($0) }) { return title.hasPrefix(words[0]) ? 3 : 2 }
            let both = title + " " + folderName(s.folderKey).lowercased()
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
            .map { row($0.0, label: labels[$0.0.id]) }
    }

    var allAgentRows: [AgentRow] { cache.all }

    /// What the sessions shortcut picks: the first session that needs you (stopped on a question mid-turn, or finished and
    /// unread), else the first kept one. A question mid-turn is still `running`, so "unread and not running" alone skipped it.
    var sessionShortcutPick: AgentRow? {
        let rows = agentRows
        return agentSections.first { $0.group == .needsYou || $0.group == .done }?.rows.first ?? rows.kept.first
    }

    /// Unread sessions waiting on you (amber) and the other unread finished ones (blue).
    var agentCounts: (blocked: Int, done: Int) { cache.counts }

    /// Projects with a session in your list or pending, in the order they're listed: where a new session can start.
    var agentFolders: [String] { cache.folders }

    /// Every folder a name can be asked for: the ones sessions are in and the ones muted.
    var namedFolders: Set<String> { Set(claudeSessions.values.map(\.folderKey)).union(agents.mutedFolders).subtracting([""]) }

    /// A project's name wherever it is named: its own, with as much of the path above it as it takes to tell it from another
    /// project of the same name (`customer-a/app`), the same in every menu, tag and spoken value.
    func folderName(_ folder: String) -> String {
        folder.isEmpty ? "Scratch" : folderNames[folder] ?? FolderNames.name(folder, among: Array(namedFolders))
    }

    /// Called when the sessions or the muted folders change (and with every change of what is kept, which changes neither): the
    /// names are worked out again only when the set of folders is another, and the dictionary is only written when a name did.
    func refreshFolderNames() {
        let folders = namedFolders
        guard folders != namedFoldersSeen else { return }
        namedFoldersSeen = folders
        let names = nameFolders(folders)
        if names != folderNames { folderNames = names }
    }

    var knownFolders: [String] {
        // The names to sort by are taken once each, not on every comparison.
        let keyed = Set(claudeSessions.values.map(\.folderKey)).map { ($0, FolderNames.components($0).last?.lowercased() ?? "") }
        return keyed.sorted { a, b in
            if a.0.isEmpty != b.0.isEmpty { return !a.0.isEmpty }
            return a.1 != b.1 ? a.1 < b.1 : a.0 < b.0
        }.map(\.0)
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
        if let inventory = snapshot.taskInventory { claudeTaskInventory = inventory }
        if snapshot.sessions != nil || snapshot.activity != nil || snapshot.tasks != nil { feedRouter() }
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

        // Forget long-gone pending sessions so the state file stays small, except those you gave a label or an icon.
        state.entries.removeAll { e in
            guard !e.kept, e.hiddenAt != nil, e.label == nil, e.icon == nil, !iconRequests.contains(e.id),
                  let s = byID[e.id] else { return false }
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
        if let interceptOpen { interceptOpen("New Claude session in \(folderName(folder))"); return }
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
                let haystack = (s.title + " " + folderName(s.folderKey)).lowercased()
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

    /// Kept sessions go to the end of your list (any session: it doesn't have to be pending). One already kept stays where it is.
    func keepAgent(_ id: String) {
        guard agents.entries.first(where: { $0.id == id })?.kept != true else { return }
        ensureEntry(id)
        guard let i = agents.entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = agents.entries.remove(at: i)
        entry.kept = true
        entry.hiddenAt = nil
        agents.entries.append(entry)
    }

    /// Sessions Lookout holds no entry for (old, muted, past the first read's cap) get one when you customize or
    /// keep them: hidden, so they stay unlisted until their next activity.
    private func ensureEntry(_ id: String) {
        guard !agents.entries.contains(where: { $0.id == id }), let session = claudeSessions[id] else { return }
        agents.entries.append(AgentEntry(id: id, seen: session.activity, hiddenAt: session.activity, focusedAt: session.lastFocused))
        agents.assignColor(session.folderKey)
    }

    /// Pins it, or unpins a pinned one (it stays listed as recent, leaving an hour after its last activity).
    func togglePin(_ id: String) {
        if agents.entries.first(where: { $0.id == id })?.kept == true {
            mutateAgent(id) { $0.kept = false }
        } else {
            keepAgent(id)
        }
    }

    /// Pending: hidden until its next activity. Kept: leaves your list (and comes back as pending on new activity).
    func dismissAgent(_ id: String) {
        mutateAgent(id) {
            $0.kept = false
            $0.hiddenAt = $0.seen
        }
    }

    func moveAgent(_ id: String, onto target: String) {
        guard id != target, let from = agents.entries.firstIndex(where: { $0.id == id }),
              let to = agents.entries.firstIndex(where: { $0.id == target }) else { return }
        agents.entries.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    // MARK: Icons (Jev)

    /// The session to pick an icon for next: one you asked for (it may be hidden, found through search), then the
    /// listed ones that don't have one yet. Sessions with nothing to go on are skipped until they change.
    func iconTarget() -> AgentRow? {
        iconRequests.removeAll { iconRow($0)?.needsIcon != true }
        iconDeferred = iconDeferred.filter { iconRow($0.key).map { iconStamp($0.session) } == $0.value }
        func ready(_ row: AgentRow) -> Bool { iconDeferred[row.id] == nil }
        return iconRequests.lazy.compactMap { self.iconRow($0) }.first(where: ready)
            ?? allAgentRows.first { $0.needsIcon && ready($0) }
    }

    /// What a session looked like when it had nothing to go on: new activity, a title or a transcript changes it.
    private func iconStamp(_ session: ClaudeSession) -> String {
        "\(session.title)|\(session.activity)|\(session.cliID ?? "")"
    }

    /// A row for a session Lookout keeps an entry for, listed or hidden.
    private func iconRow(_ id: String) -> AgentRow? {
        guard let session = claudeSessions[id], let entry = cache.entries[id] else { return nil }
        return row(session, entry)
    }

    /// Picks icons for the sessions that want one (see `iconTarget`), one request at a time.
    func pickIcons() {
        guard agents.enabled, agents.iconsEnabled, iconTask == nil, Date() >= iconsPausedUntil,
              let key = typesafeKey, !key.isEmpty, let next = iconTarget() else { return }
        let session = next.session
        let cliID = session.cliID
        let reader = activityReader
        let readFirst = iconFirstMessage ?? { id in reader.transcript(id).flatMap { Claude.firstMessage(head: Claude.head(of: $0)) } }
        iconTask = Task { [weak self] in
            // The transcript's head (256 KB, parsed) is read off the main thread, which may also be waiting on the
            // activity reader's lock.
            let first = await Task.detached(priority: .utility) {
                cliID.flatMap(readFirst)
            }.value
            guard let self else { return }
            // Nothing to go on yet (a brand-new session the app hasn't named): skip it until it changes, and carry on.
            if first == nil, session.title == "Untitled session" {
                self.iconDeferred[session.id] = self.iconStamp(session)
                self.iconTask = nil
                self.pickIcons()
                return
            }
            let rows = self.allAgentRows
            guard let current = self.iconRow(session.id), current.needsIcon else {
                self.iconTask = nil
                self.pickIcons()
                return
            }
            let used = Set(rows.compactMap(\.entry.icon)).union(current.entry.rejectedIcons ?? [])
            let open = SessionIcons.open(excluding: used)
            guard !open.isEmpty else { self.iconTask = nil; return }
            var state = ["session title": session.title, "project": session.folderName]
            if let first { state["first message"] = first }
            let choose = self.iconChooser ?? { options, hints, state, instructions in
                try await JevClient(key: key).choose(options, hints: hints, for: state, instructions: instructions)
            }
            do {
                // Two questions (Jev takes at most 255 options): what kind of icon, then which one.
                let kinds = try await choose(open.map(\.category.key),
                    Dictionary(uniqueKeysWithValues: open.map { ($0.category.key, $0.category.about) }), state,
                    "Which kind of icon would best show what this coding session is about?")
                let options = SessionIcons.shortlist(open, probabilities: kinds.probabilities)
                let pick = try await choose(options, SessionIcons.hints, state,
                    "Pick the icon that best shows what this coding session is about, so its owner can tell it apart from their other sessions at a glance.")
                self.mutateAgent(session.id) { $0.icon = pick.choice }
                self.iconError = nil
                self.iconTask = nil
                self.pickIcons()
            } catch {
                self.iconPickFailed(error)
            }
        }
    }

    /// A rejected key waits for a new one, and says so where it happens: the Settings line that shows it may not be open.
    /// Anything else retries in a while.
    func iconPickFailed(_ error: Error) {
        iconError = error.localizedDescription
        iconTask = nil
        let rejected = (error as? JevClient.Failure)?.message.contains("API key") == true
        iconsPausedUntil = rejected ? .distantFuture : Date().addingTimeInterval(600)
        if rejected, let said = iconError { announce(said, false) }
        scheduleClaudeTick()
    }

    /// Whether icons can be picked now: on, with a key. Without that a session keeps the icon it has, but can't get another.
    var canPickIcons: Bool { agents.enabled && agents.iconsEnabled && hasTypesafeKey }

    /// Replaces a session's icon (the old one is never offered again for it). Not while nothing could pick the next:
    /// the session would be left with none.
    func repickIcon(_ id: String) {
        guard canPickIcons else { return }
        ensureEntry(id)
        mutateAgent(id) {
            if let icon = $0.icon { $0.rejectedIcons = ($0.rejectedIcons ?? []) + [icon] }
            $0.icon = nil
        }
        iconRequests.append(id)
        pickIcons()
    }

    var typesafeKey: String? {
        // Filled in by the read at launch (see `Store.start`), never from the main thread.
        typesafeKeyCache
    }

    /// Keeps `key` in the Keychain, or removes it with nothing. False when the Keychain refused it: the key is then not
    /// saved (`iconError` says so) and what was saved before stays.
    @discardableResult
    func setTypesafeKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            Keychain.delete(Keychain.typesafe)
        } else if !(keychainWrite ?? Keychain.write)(trimmed, Keychain.typesafe) {
            iconError = "Couldn't save the key in the Keychain"
            return false
        }
        typesafeKeyCache = trimmed
        hasTypesafeKey = !trimmed.isEmpty
        iconError = nil
        iconsPausedUntil = .distantPast
        pickIcons()
        return true
    }

    func setIconsEnabled(_ on: Bool) {
        agents.iconsEnabled = on
        iconsPausedUntil = .distantPast
        pickIcons()
    }

    func setAgentLabel(_ id: String, _ label: String?) {
        let label = label.flatMap(AgentLabel.sanitize)
        if label != nil { ensureEntry(id) }
        mutateAgent(id) { $0.label = label }
    }

    func isFolderMuted(_ folder: String) -> Bool { agents.mutedFolders.contains(folder) }

    func setFolderMuted(_ folder: String, _ muted: Bool) {
        agents.mutedFolders.removeAll { $0 == folder }
        if muted { agents.mutedFolders.append(folder) }
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

/// Names for folders: the last component, and the folders above it only where another project would have the same one.
enum FolderNames {
    /// The names of all of `folders` at once. A folder whose last component no other has is named by it alone; only the ones that
    /// share a last component are compared, each by as many of the components above as it takes to differ.
    static func names(for folders: Set<String>) -> [String: String] {
        var named: [String: [String]] = [:]
        var parts: [String: [String]] = [:]
        for folder in folders {
            let own = components(folder)
            parts[folder] = own
            named[own.last ?? "", default: []].append(folder)
        }
        var names: [String: String] = [:]
        for (_, group) in named {
            for folder in group {
                let own = parts[folder]!
                var depth = 1
                while depth < own.count, group.contains(where: { $0 != folder && parts[$0]!.suffix(depth) == own.suffix(depth) }) { depth += 1 }
                names[folder] = own.suffix(depth).joined(separator: "/")
            }
        }
        return names
    }

    static func name(_ folder: String, among folders: [String]) -> String {
        guard !folder.isEmpty else { return "Scratch" }
        return names(for: Set(folders).union([folder]))[folder] ?? ""
    }

    /// A path's components, without the root and empty ones.
    static func components(_ folder: String) -> [String] {
        folder.split(separator: "/").map(String.init)
    }
}
