import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class Store {
    /// Demo and snapshot runs: never touch the Keychain (a new build would stop on an access prompt).
    nonisolated static let isDemo = CommandLine.arguments.contains { ["--demo", "--snapshot", "--playground", "--playground-shots"].contains($0) }

    var repos: [RepoConfig] = [] {
        didSet {
            memo = Memo()
            persistedRevision &+= 1
        }
    }
    var items: [InboxItem] = [] {
        didSet {
            memo = Memo()
            itemsRevision &+= 1
            persistedRevision &+= 1
        }
    }
    /// Bumped on every assignment to `items`, and those only happen on real changes: a cheap animation/memo key for views.
    private(set) var itemsRevision = 0
    var ci: [String: CIStatus] = [:] {
        didSet {
            memo = Memo()
            persistedRevision &+= 1
        }
    }
    var settings = AppSettings() {
        didSet {
            memo = Memo()
            persistedRevision &+= 1
            if oldValue.reviewRequests != settings.reviewRequests {
                // A search under way for the source as it was has nothing to say to it as it is now.
                reviewGeneration &+= 1
                if !settings.reviewRequests, !loading { removeItems { $0.kind == .reviewRequested } }
            }
            armSnoozeExpiry()
            save()
        }
    }

    /// Claude sessions extension (see Agents.swift).
    var agents = AgentsState() {
        didSet {
            agentCache = nil
            agentsRevision &+= 1
            persistedRevision &+= 1
            if !ingesting { claudeStamp.revision += 1 }
            refreshFolderNames()
            save()
        }
    }
    /// Every project's name, with as much of its path as tells it from another of the same name (`customer-a/app`): worked
    /// out when the folders change, not by each view that names a project. Only a change in it redraws what reads it.
    var folderNames: [String: String] = [:]
    /// The folders `folderNames` was worked out for: the work is skipped while they are the same.
    @ObservationIgnored var namedFoldersSeen: Set<String>?
    /// What works the names out (the tests count its runs).
    @ObservationIgnored var nameFolders: (Set<String>) -> [String: String] = FolderNames.names(for:)
    /// Bumped whenever the rows the hub shows can change (agents, sessions, activity, tasks): a cheap memo/animation key.
    private(set) var agentsRevision = 0
    var claudeSessions: [String: ClaudeSession] = [:] {
        didSet {
            agentCache = nil
            agentsRevision &+= 1
            refreshFolderNames()
        }
    }
    var claudeActivity: [String: ClaudeActivity] = [:] {
        didSet {
            agentCache = nil
            agentsRevision &+= 1
        }
    }
    /// Subagents and commands still running in sessions whose turn is over.
    var claudeTasks: [String: [ClaudeTask]] = [:] {
        didSet {
            agentCache = nil
            agentsRevision &+= 1
        }
    }
    /// Filled in right after launch (see `start`): the Keychain read stays off the main thread.
    var hasTypesafeKey = false
    var iconError: String?
    var claudeLink: ClaudeLink = .off

    var me: GHUser?
    var tokenSource: TokenSource?
    var authError: String?
    /// The first look at the account got no answer from GitHub (no network yet, a VPN down): nothing is known of the token, so
    /// this is a sync problem, not a sign-in one, and the cached rows stay.
    var unreachable = false
    var repoErrors: [String: String] = [:]
    var isSyncing = false
    var lastSync: Date?
    var rateRemaining: Int?
    /// When the GitHub rate limit resets, as of the last sync.
    @ObservationIgnored var rateResetsAt: Date?
    var suggestions: [String] = []

    @ObservationIgnored let gh = GitHubClient()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var memo = Memo()
    @ObservationIgnored private var hubOpen = false
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var pollNow = false
    /// Where the token comes from; replaced in tests (the real one can spawn `gh`).
    @ObservationIgnored var resolveToken: @Sendable () -> (String, TokenSource)? = { TokenProvider.resolve() }
    /// Counts the changes made in Settings; the token held was found under `foundAt`, and is looked for again once they differ.
    @ObservationIgnored private var credentialsChanged = 0
    @ObservationIgnored private var foundAt = 0
    /// A token was just saved or taken away: the sign-in that fails next is its result and is said aloud (a poll's isn't).
    @ObservationIgnored private(set) var awaitingSignIn = false
    @ObservationIgnored private var lastAuthAttempt: Date?
    @ObservationIgnored private var authRetry = false
    @ObservationIgnored private var refreshQueued = false
    /// Signed out, polls look for a new token this rarely: each look can spawn `gh auth token`.
    private static let authBackoff: TimeInterval = 300
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    /// When the sleeper is due to wake.
    @ObservationIgnored private var sleeperWakes: Date?
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDirty = false
    /// Bumped by every persisted property's didSet: a poll saves only if this moved.
    @ObservationIgnored private var persistedRevision = 0
    /// `persistedRevision` as of the last `save()`: a poll saves whatever changed since, whoever changed it.
    @ObservationIgnored private var savedRevision = 0
    /// When the one-shot Claude timer fires (it only ever moves earlier until it does).
    @ObservationIgnored private var claudeDeadline: Date?
    /// When each repo's CI was last checked, live (the persisted `checkedAt` only changes with the status).
    @ObservationIgnored private var ciCheckedAt: [String: Date] = [:]
    /// Review requests the last complete search listed; nil until one has (then nothing is known to be gone).
    @ObservationIgnored private var requested: Set<String>?
    /// CI checks under way, by repo, and the newest one each repo has started (see `syncCI`).
    @ObservationIgnored private var ciChecks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var ciTickets: [String: Int] = [:]
    /// What each source of a repo last failed at; `repoErrors` shows the conversations' first, then CI's (see `publishHealth`).
    @ObservationIgnored private var conversationErrors: [String: String] = [:]
    @ObservationIgnored private var ciErrors: [String: String] = [:]
    /// What a check asks GitHub, replaced by the tests.
    @ObservationIgnored var ciFetch: ((RepoConfig) async throws -> CIStatus)?
    /// Counts the times Review requests was switched, so a search that outlives its switch is let go (see `syncReviewRequests`).
    @ObservationIgnored private var reviewGeneration = 0
    @ObservationIgnored var persists = true
    /// Stops the shortcut recorder that is listening, if any. While one is, the panel's key handler stands down
    /// and the global hotkeys are released, so the recorder sees every combination.
    @ObservationIgnored private var stopRecorder: (() -> Void)?
    var isRecordingShortcut: Bool { stopRecorder != nil }
    @ObservationIgnored var onRecordingShortcutChange: ((Bool) -> Void)?
    /// Shows the inbox on a tab: where a summary banner leads.
    @ObservationIgnored var onOpenInbox: ((InboxFilter) -> Void)?
    /// Registers a global shortcut system-wide; `false` when the system refuses it.
    @ObservationIgnored var onGlobalShortcutChange: ((ShortcutAction, Shortcut) -> Bool)?
    /// The system-wide shortcuts the system last refused to register (another app holds the key), by the key it refused:
    /// one still stored does nothing, and Settings says so.
    var refusedShortcuts: [ShortcutAction: Shortcut] = [:]
    @ObservationIgnored var onAgentsEnabledChange: ((Bool) -> Void)?
    @ObservationIgnored let activityReader = Claude.ActivityReader()
    @ObservationIgnored lazy var claudeFeed = ClaudeFeed(activityReader: activityReader)
    /// Derived rows, rebuilt after any change to the agents or what was read (see Agents.swift).
    @ObservationIgnored var agentCache: AgentCache?
    /// Tells a read of the app that was asked for before you changed something from one asked for after.
    @ObservationIgnored var claudeStamp = ClaudeStamp()
    @ObservationIgnored var ingesting = false
    @ObservationIgnored var iconTask: Task<Void, Never>?
    /// Sessions you asked an icon for, picked before the rest (they may not be listed).
    @ObservationIgnored var iconRequests: [String] = []
    /// Sessions with nothing to go on yet (see `iconStamp` for when they're looked at again).
    @ObservationIgnored var iconDeferred: [String: String] = [:]
    @ObservationIgnored var iconsPausedUntil = Date.distantPast
    /// Where icons get their input and their answer (a session's first message by transcript id; Jev's choice from
    /// options, hints, state and instructions). Tests swap them for the disk and the network.
    @ObservationIgnored var iconFirstMessage: (@Sendable (String) -> String?)?
    @ObservationIgnored var iconChooser: (([String], [String: String], [String: String], String) async throws -> JevClient.Choice)?
    @ObservationIgnored var typesafeKeyCache: String?
    /// What keeps a key in the Keychain (tests answer for it).
    @ObservationIgnored var keychainWrite: ((String, String) -> Bool)?
    @ObservationIgnored private var transcriptWatcher: FolderWatcher?
    @ObservationIgnored private var sessionsWatcher: FolderWatcher?
    @ObservationIgnored private var dotsWatcher: FolderWatcher?
    @ObservationIgnored var claudeTimer: Timer?
    @ObservationIgnored private var claudeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var screensAsleep = false
    /// Parsed Markdown of session summaries (see `AgentRow.summaryText`).
    @ObservationIgnored var summaryTexts: [String: AttributedString] = [:]

    private nonisolated static func isClaude(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Claude.bundleID
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Where the state is kept, when not in the user's own file: a test's, in a folder of its own. A test run that reaches the
    /// user's file stops (see `UnderTest`).
    @ObservationIgnored var stateFile: URL?

    /// The file the state is read from and written to; nil when a test has not said where, and was stopped for it.
    private var file: URL? {
        if let stateFile { return stateFile }
        return UnderTest.refuses("the saved state (Application Support/Lookout/state.json)") ? nil : Self.fileURL
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lookout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    // MARK: Lifecycle

    func start() {
        load()
        notifier.onOpen = { [weak self] id, url, quiet in self?.openNotification(id: id, url: url, quiet: quiet) }
        notifier.setup()
        updater.automatic = { [weak self] in self?.settings.checkUpdates ?? true }
        updater.skipped = { [weak self] in self?.settings.skippedVersion }
        updater.onSkip = { [weak self] in self?.settings.skippedVersion = $0 }
        updater.start()
        observeSleep()
        restartPolling()
        watchClaude()
        Task.detached(priority: .utility) {
            let key = Keychain.read(Keychain.typesafe) ?? ""
            await MainActor.run { [weak self] in
                // A key saved meanwhile (Settings) is newer than this read.
                guard let self, self.typesafeKeyCache == nil else { return }
                self.typesafeKeyCache = key
                self.hasTypesafeKey = !key.isEmpty
                self.pickIcons()
            }
        }
    }

    /// File events give near-instant updates: the sessions folder triggers a read of the sessions, the app's local
    /// storage (where it lazily writes the sidebar dots) only a re-read of the dots. What events can't tell is covered
    /// by the app launching, quitting or coming to the front, and by a one-shot timer (see `scheduleClaudeTick`).
    func watchClaude() {
        sessionsWatcher = nil
        dotsWatcher = nil
        transcriptWatcher = nil
        claudeTimer?.invalidate()
        claudeTimer = nil
        claudeDeadline = nil
        let center = NSWorkspace.shared.notificationCenter
        claudeObservers.forEach { center.removeObserver($0) }
        claudeObservers = []
        guard agents.enabled else { return }
        sessionsWatcher = FolderWatcher([Claude.sessionsDir]) { [weak self] in
            MainActor.assumeIsolated { self?.refreshClaude() }
        }
        // The app writes to its leveldb in bursts: one read of the dots per couple of seconds is plenty.
        dotsWatcher = FolderWatcher([Claude.localStorageDir], latency: 2) { [weak self] in
            MainActor.assumeIsolated { self?.refreshUnread() }
        }
        // Transcripts change with every step an agent takes: only the working sessions' tails are read, and only the
        // transcripts of working sessions (and those with background tasks) are worth waking up for. The filter runs
        // on the watcher's queue; `isRelevant` takes its own lock.
        let feed = claudeFeed
        transcriptWatcher = FolderWatcher([Claude.transcriptsDir], latency: 0.5, relevant: { feed.isRelevant($0) }) { [weak self] in
            MainActor.assumeIsolated { self?.refreshActivity() }
        }
        func watch(_ name: Notification.Name, _ then: @escaping @MainActor (Store) -> Void) {
            claudeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard Self.isClaude(note) else { return }
                MainActor.assumeIsolated { if let self { then(self) } }
            })
        }
        // Whether the app is open decides if a session still "runs"; being in front, which one you're looking at.
        watch(NSWorkspace.didLaunchApplicationNotification) { $0.refreshClaude() }
        watch(NSWorkspace.didTerminateApplicationNotification) { $0.refreshClaude() }
        watch(NSWorkspace.didActivateApplicationNotification) { $0.refreshClaude() }
        claudeObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.claudeTimer?.invalidate()
                self?.claudeTimer = nil
                self?.claudeDeadline = nil
            }
        })
        claudeObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screensAsleep = false
                self.refreshClaude()
            }
        })
        screensAsleep = false
        refreshClaude()
    }

    /// What nothing announces is the clock: a turn with no summary stops counting as running two hours after its last
    /// message, and a background subagent that stopped writing is given up on. One timer, set after each read for the
    /// first moment something can expire (and none while the screens are asleep or nothing is running).
    func lastCICheck(_ name: String) -> Date? { ciCheckedAt[name] ?? ci[name]?.checkedAt }

    func scheduleClaudeTick() {
        guard agents.enabled, persists, !screensAsleep else {
            claudeTimer?.invalidate()
            claudeTimer = nil
            claudeDeadline = nil
            return
        }
        var next: TimeInterval?
        let now = Date()
        for session in claudeSessions.values where session.running {
            let left = (session.lastUserMessage ?? .distantPast).addingTimeInterval(Claude.runningTimeout).timeIntervalSince(now)
            next = min(next ?? left, left)
        }
        // Sessions with background work: its end isn't always an event (a command's process just exits).
        if !claudeTasks.isEmpty { next = min(next ?? 60, 60) }
        // Icon picking waits out a failure (a rejected key waits for a new one instead).
        if agents.iconsEnabled, iconsPausedUntil > now, iconsPausedUntil < .distantFuture {
            next = min(next ?? .infinity, iconsPausedUntil.timeIntervalSince(now))
        }
        guard let next else { return }
        let deadline = now.addingTimeInterval(max(next, 1) + 1)
        // Frequent reads must not keep pushing it back: it only moves earlier.
        if claudeTimer?.isValid == true, let current = claudeDeadline, current <= deadline { return }
        claudeTimer?.invalidate()
        claudeDeadline = deadline
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.claudeDeadline = nil
                self?.refreshClaude()
            }
        }
        timer.tolerance = max(next, 1) * 0.1 + 2
        RunLoop.main.add(timer, forMode: .common)
        claudeTimer = timer
    }

    func restartPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.systemAsleep { await self.pollAll() }
                await self.sleepUntilNextPoll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        sleeper?.cancel()
    }

    func refreshNow() {
        authRetry = true
        // Asked for during a poll: that one may be on its way out with what it knew before, so one more follows it.
        if isSyncing { refreshQueued = true } else { Task { await pollAll() } }
    }

    /// The hub being open means someone is looking: sync now if stale, and poll faster meanwhile.
    func setHubOpen(_ open: Bool) {
        guard open != hubOpen else { return }
        hubOpen = open
        sleeper?.cancel()
        guard open, !isSyncing else { return }
        // Signed out for want of a token, `gh auth login` may have been run since: look again, however recent the last poll.
        if awaitsToken || Date().timeIntervalSince(lastSync ?? .distantPast) > 60 { refreshNow() }
    }

    /// Signed out with no token to ask GitHub about: the only case where a look for one (it reads the Keychain and may run
    /// `gh`) is likely to find something new, once the user has signed in elsewhere.
    private var awaitsToken: Bool { me == nil && gh.token == nil && authError != nil }

    /// `gh auth login` was run in Terminal, which the app comes back from: the look the polls hold back (see `authBackoff`)
    /// is made now. Nothing happens for any other reason to be signed out.
    func appBecameActive() {
        if awaitsToken, !isSyncing { refreshNow() }
    }

    private var effectivePollInterval: TimeInterval {
        Self.pollInterval(base: settings.pollInterval, hubOpen: hubOpen, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// How often to poll: the setting, at most 30 s while the hub is open, and doubled in Low Power Mode whichever it is.
    nonisolated static func pollInterval(base: TimeInterval, hubOpen: Bool, lowPower: Bool) -> TimeInterval {
        (hubOpen ? min(base, 30) : base) * (lowPower ? 2 : 1)
    }

    /// Sleeps in slices so a change (hub opening, wake, new interval) can cut it short.
    private func sleepUntilNextPoll() async {
        while !Task.isCancelled {
            if pollNow, !systemAsleep {
                pollNow = false
                return
            }
            var wait = 3600.0
            if !systemAsleep {
                wait = effectivePollInterval - Date().timeIntervalSince(lastSync ?? .distantPast)
                // Out of calls: nothing is sent before the reset, so that is when to check again, whatever is left of the interval.
                if rateRemaining == 0, let reset = rateResetsAt {
                    if reset <= Date(), (lastSync ?? .distantPast) < reset, !isSyncing { return }
                    if reset > Date() { wait = min(wait, reset.timeIntervalSinceNow) }
                }
                if wait <= 0 {
                    if !isSyncing { return }
                    wait = 1
                }
            }
            let seconds = wait
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
            sleeper = task
            sleeperWakes = Date(timeIntervalSinceNow: seconds)
            await task.value
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemAsleep = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.systemAsleep = false
                    self.pollNow = true
                    self.sleeper?.cancel()
                }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            },
        ]
    }

    // MARK: Persistence

    private func load() {
        loading = true
        defer { loading = false }
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let state = try? dec.decode(PersistedState.self, from: data) else { return }
        repos = state.repos
        items = state.items
        ci = state.ci
        settings = state.settings
        agents = state.agents ?? AgentsState()
        savedRevision = persistedRevision
    }

    private static let writer = DispatchQueue(label: "lookout.save")

    /// Coalesced: the write happens shortly after the last call, off the main thread.
    func save() {
        // (Asked now, not when the write comes: a test that reaches the user's file is stopped where it did.)
        guard persists, !loading, file != nil else { return }
        savedRevision = persistedRevision
        saveDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot(wait: false)
        }
    }

    /// Writes any pending change now (quitting).
    func flushSave() {
        saveTask?.cancel()
        writeSnapshot(wait: true)
    }

    private func writeSnapshot(wait: Bool) {
        guard saveDirty, persists, !loading else {
            if wait { Self.writer.sync {} }
            return
        }
        guard let url = file else { return }
        saveDirty = false
        let box = SnapshotBox(state: PersistedState(repos: repos, items: items, ci: ci, settings: settings, agents: agents))
        let write: @Sendable () -> Void = {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(box.state) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if wait { Self.writer.sync(execute: write) } else { Self.writer.async(execute: write) }
    }

    private struct SnapshotBox: @unchecked Sendable { let state: PersistedState }

    // MARK: Derived

    /// Whether notifications are snoozed. The views that read it are redrawn once, when the snooze runs out (`snoozeRevision`):
    /// nothing changes in the settings then, and nothing ticks for it.
    var isSnoozed: Bool {
        _ = snoozeRevision
        return (settings.snoozeUntil ?? .distantPast) > Date()
    }

    /// Bumped when a snooze's deadline passes.
    private(set) var snoozeRevision = 0
    @ObservationIgnored private var snoozeExpiry: (deadline: Date, task: Task<Void, Never>)?

    /// One cancellable one-shot at the snooze's deadline, kept in step with the setting.
    private func armSnoozeExpiry() {
        guard let until = settings.snoozeUntil, until > Date() else {
            snoozeExpiry?.task.cancel()
            snoozeExpiry = nil
            return
        }
        guard snoozeExpiry?.deadline != until else { return }
        snoozeExpiry?.task.cancel()
        snoozeExpiry = (until, Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            guard !Task.isCancelled, let self else { return }
            snoozeRevision &+= 1
            snoozeExpiry = nil
        })
    }

    /// Derived inbox data, rebuilt lazily after `items`, `settings`, `repos` or `ci` change.
    private struct Memo {
        var lists: [InboxFilter: [InboxItem]] = [:]
        var unread: [InboxFilter: Int] = [:]
        var bots: Set<String>?
        var ciRepos: [RepoConfig]?
        var byState: [CIState: [RepoConfig]] = [:]
        var worst: CIState?
    }

    // The getters touch the observed properties so SwiftUI tracks them, even on a memo hit.
    var ciRepos: [RepoConfig] {
        let repos = self.repos
        if let hit = memo.ciRepos { return hit }
        let result = repos.filter { $0.events.contains(.ciMain) }
        memo.ciRepos = result
        return result
    }

    func ciRepos(in state: CIState) -> [RepoConfig] {
        let ci = self.ci
        let all = ciRepos
        if let hit = memo.byState[state] { return hit }
        let result = all.filter { ci[$0.fullName]?.state == state }
        memo.byState[state] = result
        return result
    }

    private var botSet: Set<String> {
        let handles = settings.botHandles
        if let hit = memo.bots { return hit }
        let result = Set(handles.map { $0.lowercased() })
        memo.bots = result
        return result
    }

    func isLowPriority(_ item: InboxItem) -> Bool {
        let author = item.author.lowercased()
        if settings.treatAppsAsBots && item.authorIsApp { return true }
        let handles = botSet
        return handles.contains(author) || handles.contains(author.replacingOccurrences(of: "[bot]", with: ""))
    }

    func list(_ filter: InboxFilter) -> [InboxItem] {
        let items = self.items
        _ = settings
        if let hit = memo.lists[filter] { return hit }
        let result = items.filter { item in
            switch filter {
            case .needsYou: item.state.isOpen && !isLowPriority(item)
            case .bots: item.state.isOpen && isLowPriority(item)
            case .done: !item.state.isOpen
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
        memo.lists[filter] = result
        return result
    }

    func unreadCount(_ filter: InboxFilter) -> Int {
        let all = list(filter)
        if let hit = memo.unread[filter] { return hit }
        let n = all.reduce(0) { $0 + ($1.state == .unread ? 1 : 0) }
        memo.unread[filter] = n
        return n
    }

    func openCount(_ filter: InboxFilter) -> Int {
        list(filter).count
    }

    var worstCI: CIState {
        let all = ciRepos
        let ci = self.ci
        if let hit = memo.worst { return hit }
        let states = all.compactMap { ci[$0.fullName]?.state }
        let result: CIState
        if states.contains(.failure) { result = .failure }
        else if states.contains(.pending) { result = .pending }
        else if states.contains(.success) { result = .success }
        else { result = .none }
        memo.worst = result
        return result
    }

    // MARK: Item actions

    private func mutate(_ id: String, _ f: (inout InboxItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
        save()
    }

    /// A clicked banner: its item, a summary's inbox (on Bots when it only covered bots), or the page it was about.
    func openNotification(id: String, url: String?, quiet: Bool = false) {
        if let item = items.first(where: { $0.id == id }) {
            open(item)
        } else if id.hasPrefix(Notifier.summaryPrefix) {
            onOpenInbox?(quiet ? .bots : .needsYou)
        } else if let url = [url, id].lazy.compactMap({ $0.flatMap { URL(string: $0) } }).first(where: { $0.scheme == "https" }) {
            // The item is gone (its repo was removed, say): the page it was about still makes sense.
            Link.open(url)
        }
    }

    /// Playground: report what would open instead of opening it.
    @ObservationIgnored var interceptOpen: ((String) -> Void)?

    func open(_ item: InboxItem) {
        if let interceptOpen { interceptOpen("Open on GitHub · \(item.title)") } else { Link.open(item.url) }
        if item.state == .unread { markRead(item) }
    }

    func markRead(_ item: InboxItem) {
        mutate(item.id) { $0.state = .read }
        notifier.remove([item.id])
    }
    func markUnread(_ item: InboxItem) { mutate(item.id) { $0.state = .unread } }
    func discard(_ item: InboxItem) {
        mutate(item.id) { $0.state = .discarded }
        notifier.remove([item.id])
    }
    func restore(_ item: InboxItem) { mutate(item.id) { $0.state = .read } }

    func markAllRead(_ filter: InboxFilter) {
        let ids = Set(list(filter).filter { $0.state == .unread }.map(\.id))
        for i in items.indices where ids.contains(items[i].id) { items[i].state = .read }
        notifier.remove(Array(ids))
        save()
    }

    /// Drops items (and their banners) that no longer match what a repo is set to follow.
    func removeItems(where shouldRemove: (InboxItem) -> Bool) {
        let gone = items.filter(shouldRemove).map(\.id)
        guard !gone.isEmpty else { return }
        let set = Set(gone)
        items.removeAll { set.contains($0.id) }
        notifier.remove(gone)
        save()
    }

    func shortcut(_ action: ShortcutAction) -> Shortcut {
        settings.shortcuts?[action.rawValue] ?? action.defaultShortcut
    }

    /// A stored system-wide shortcut that another app held when Lookout tried to register it.
    func isShortcutHeldByAnotherApp(_ action: ShortcutAction) -> Bool {
        refusedShortcuts[action].map { $0 == shortcut(action) } ?? false
    }

    /// `nil` resets to the default. A global one the system refuses (another app holds the key) is not kept: the one that
    /// works stays stored and registered, and the refusal is returned.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> ShortcutRefusal? {
        var all = settings.shortcuts ?? [:]
        all[action.rawValue] = shortcut == action.defaultShortcut ? nil : shortcut
        let wanted = all[action.rawValue] ?? action.defaultShortcut
        if action.isGlobal, onGlobalShortcutChange?(action, wanted) == false { return .unavailable(wanted) }
        settings.shortcuts = all.isEmpty ? nil : all
        return nil
    }

    /// Asks the system again for the stored system-wide key another app held, which it may have let go of since.
    func retryShortcut(_ action: ShortcutAction) -> Bool {
        !action.isGlobal || onGlobalShortcutChange?(action, shortcut(action)) != false
    }

    /// A recorder starts listening; one that already was is stopped, so only one ever is.
    func beginRecordingShortcut(stop: @escaping () -> Void) {
        stopRecorder?()
        stopRecorder = stop
        onRecordingShortcutChange?(true)
    }

    func endRecordingShortcut() {
        stopRecorder = nil
        onRecordingShortcutChange?(false)
    }

    func addBot(_ handle: String) {
        let h = handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !h.isEmpty, !settings.botHandles.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) else { return }
        settings.botHandles.append(h)
    }

    func removeBot(_ handle: String) {
        settings.botHandles.removeAll { $0 == handle }
    }

    func snooze(for seconds: TimeInterval?) {
        settings.snoozeUntil = seconds.map { Date().addingTimeInterval($0) }
    }

    func snoozeUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        settings.snoozeUntil = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
    }

    // MARK: Auth

    /// Signs in with the token held, else the one `resolveToken` finds. A token already held is asked about as it is: finding one
    /// reads the Keychain and may run `gh`, which a poll that fails (offline, a VPN down, GitHub's own trouble) would do every
    /// minute. Only no token, one GitHub refused (`dropRejectedToken`), or a change in Settings (`setToken`) looks again.
    func authenticate() async {
        // What Settings changes while this waits (on the token found, or on /user) is about another token: nothing of it is kept.
        let asked = credentialsChanged
        if gh.token == nil || foundAt != credentialsChanged {
            lastAuthAttempt = Date()
            let find = resolveToken
            let resolved = await Task.detached(operation: find).value
            guard asked == credentialsChanged else { return }
            guard let (token, source) = resolved else {
                gh.token = nil
                me = nil
                tokenSource = nil
                unreachable = false
                signInFailed("No GitHub token found. Run `gh auth login`, or paste a token in Settings.")
                return
            }
            gh.token = token
            tokenSource = source
            foundAt = asked
        }
        do {
            let user = try await gh.get("/user", as: GHUser.self)
            guard asked == credentialsChanged else { return }
            me = user
            authError = nil
            awaitingSignIn = false
            unreachable = false
        } catch {
            guard asked == credentialsChanged else { return }
            if error is URLError {
                // Only a missing or refused token is a sign-in problem: an earlier one is not this attempt's.
                authError = nil
                unreachable = true
                return
            }
            me = nil
            unreachable = false
            signInFailed(error.localizedDescription)
        }
    }

    /// Sets the sign-in problem. The editor in Settings closes once the Keychain has a token, before GitHub answers, so the
    /// refusal of what was just saved is said too, once; a later poll's is only shown.
    private func signInFailed(_ reason: String) {
        authError = reason
        guard awaitingSignIn else { return }
        awaitingSignIn = false
        Announce.say(reason, again: true)
    }

    /// Revoked or expired: forget the token and who it was, so the next look resolves one again
    /// (the user may have run `gh auth login` meanwhile).
    private func dropRejectedToken() {
        gh.token = nil
        me = nil
        tokenSource = nil
        lastAuthAttempt = nil
        authError = "GitHub rejected the token. Run `gh auth login` again, then Retry."
    }

    /// Keeps `token` in the Keychain, or removes it with nothing, and signs in again with what is there. False when the
    /// Keychain refused it: nothing changes then, and the token that was saved before still signs in.
    @discardableResult
    func setToken(_ token: String?) -> Bool {
        if let token, !token.isEmpty {
            guard (keychainWrite ?? Keychain.write)(token, Keychain.github) else { return false }
        } else {
            Keychain.delete()
        }
        me = nil
        awaitingSignIn = true
        credentialsChanged += 1
        refreshNow()
        return true
    }

    // MARK: Repos

    func addRepo(_ input: String) async -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "github.com/") { name = String(name[range.upperBound...]) }
        name = name.split(separator: "/").prefix(2).joined(separator: "/")
        guard name.split(separator: "/").count == 2 else { return "Use the owner/repo format" }
        guard !repos.contains(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) else { return "Already watching \(name)" }
        if me == nil { await authenticate() }
        do {
            let info: GHRepo = try await gh.get("/repos/\(name)")
            var config = RepoConfig(fullName: info.fullName)
            config.defaultBranch = info.defaultBranch
            repos.append(config)
            save()
            suggestions.removeAll { $0 == info.fullName }
            await sync(info.fullName)
            save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeRepo(_ repo: RepoConfig) {
        repos.removeAll { $0.id == repo.id }
        removeItems { $0.repo == repo.fullName && $0.kind != .reviewRequested }
        notifier.removeBanners(of: repo.fullName)
        ci[repo.fullName] = nil
        // Polls never visit it again, so its fault would outlive it (the gear's badge, the banner, Settings).
        conversationErrors[repo.fullName] = nil
        ciErrors[repo.fullName] = nil
        repoErrors[repo.fullName] = nil
        endCIChecks(repo.fullName)
        save()
    }

    func toggle(_ kind: EventKind, on repo: RepoConfig) {
        guard let i = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        if repos[i].events.contains(kind) {
            repos[i].events.remove(kind)
            removeItems { $0.repo == repo.fullName && $0.kind == kind }
            if kind == .ciMain {
                endCIChecks(repo.fullName)
                // CI is not watched any more: what it failed at is no fault of the repo's.
                ciErrors[repo.fullName] = nil
                publishHealth(repo.fullName)
            }
        } else {
            repos[i].events.insert(kind)
        }
        save()
        if kind == .ciMain && repos[i].events.contains(kind) {
            let name = repo.fullName
            Task { try? await syncCI(name) }
        }
    }

    func moveRepo(_ name: String, onto target: String) {
        guard name != target, let from = repos.firstIndex(where: { $0.fullName == name }),
              let to = repos.firstIndex(where: { $0.fullName == target }) else { return }
        repos.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    func toggleAllComments(_ repo: RepoConfig) {
        guard let i = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[i].allComments.toggle()
        if !repos[i].allComments {
            removeItems { $0.repo == repo.fullName && $0.forYou == false }
        }
        save()
    }

    func loadSuggestions() async {
        guard suggestions.isEmpty else { return }
        if me == nil { await authenticate() }
        var names: [String] = []
        if let involved: GHSearch<GHIssue> = try? await gh.get("/search/issues", ["q": "involves:@me", "sort": "updated", "per_page": "100"]) {
            names += involved.items.compactMap { $0.repositoryUrl.map { repoName(from: $0) } }
        }
        if let mine: [GHRepo] = try? await gh.get("/user/repos", ["sort": "pushed", "per_page": "100", "affiliation": "owner,collaborator,organization_member"]) {
            names += mine.map(\.fullName)
        }
        var seen = Set(repos.map { $0.fullName.lowercased() })
        suggestions = names.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: Polling

    func pollAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            lastSync = Date()
            if rateRemaining != gh.rateRemaining { rateRemaining = gh.rateRemaining }
            rateResetsAt = gh.rateResetsAt
            // A reset learned now (a refresh by hand) may come before the wake the sleeper was set for: it sets that again.
            if gh.rateRemaining == 0, let reset = rateResetsAt, reset > Date(), let wakes = sleeperWakes, reset < wakes { sleeper?.cancel() }
            prune()
            if persistedRevision != savedRevision { save() }
            if refreshQueued {
                refreshQueued = false
                Task { await pollAll() }
            }
        }
        // Signed out: look for a token when asked (Retry, a refresh) or once the backoff has passed. One already held is
        // asked about at every poll: that is a request, not a look in the Keychain and `gh`.
        let asked = authRetry
        authRetry = false
        // A 401 from outside a poll (adding a repo, suggestions) left the token and who it was cached.
        if gh.tokenRejected { dropRejectedToken() }
        if me == nil, asked || gh.token != nil || Date().timeIntervalSince(lastAuthAttempt ?? .distantPast) >= Self.authBackoff {
            await authenticate()
        }
        guard me != nil else { return }
        defer { if gh.tokenRejected { dropRejectedToken() } }
        gh.reserveETags(forRepositories: repos.count)
        await withTaskGroup(of: Void.self) { group in
            var names = repos.map(\.fullName).makeIterator()
            for _ in 0..<4 {
                guard let name = names.next() else { break }
                group.addTask { @MainActor in await self.sync(name) }
            }
            while await group.next() != nil {
                if let name = names.next() { group.addTask { @MainActor in await self.sync(name) } }
            }
        }
        if settings.reviewRequests {
            await syncReviewRequests()
        }
    }

    func sync(_ name: String) async {
        let watchedSince = repos.first(where: { $0.fullName == name })?.addedAt
        var failure: Error?
        do {
            try await syncConversations(name)
            try await syncThreads(name)
        } catch {
            failure = error
        }
        // A request that outlived the repo's removal (or its removal and return, which is a new repo) has nobody to tell.
        if repos.contains(where: { $0.fullName == name && $0.addedAt == watchedSince }) {
            conversationErrors[name] = failure?.localizedDescription
            // Published here, not left to the CI check: with CI off there is none, and the fault would never come or go.
            publishHealth(name)
        }
        // CI has endpoints of its own: conversations failing doesn't keep it from being checked. Its own fault is published
        // by the check (`syncCI`), under its ticket.
        try? await syncCI(name)
    }

    /// `repoErrors` is what the sources of a repo (its conversations, its CI) failed at, the conversations' first.
    private func publishHealth(_ name: String) {
        guard repos.contains(where: { $0.fullName == name }) else { return }
        let message = conversationErrors[name] ?? ciErrors[name]
        if repoErrors[name] != message { repoErrors[name] = message }
    }

    /// What a check of a repo's CI came to, for its sync health: nothing if the check was overtaken (CI switched off, and
    /// perhaps on again, whose own check is the newer one; or the repo removed).
    private func publishCIHealth(_ name: String, failure: String?, ticket: Int) {
        guard ciTickets[name] == ticket, repos.contains(where: { $0.fullName == name && $0.events.contains(.ciMain) }) else { return }
        ciErrors[name] = failure
        publishHealth(name)
    }

    /// Whether `repo`, as an answer was asked for it, is still what is watched: not stopped (nor stopped and watched again),
    /// and following the same events.
    private func isCurrent(_ repo: RepoConfig) -> Bool {
        guard let now = repos.first(where: { $0.fullName == repo.fullName }) else { return false }
        return now.addedAt == repo.addedAt && now.events == repo.events && now.allComments == repo.allComments
    }

    private func updateRepo(_ name: String, _ f: (inout RepoConfig) -> Void) {
        guard let i = repos.firstIndex(where: { $0.fullName == name }) else { return }
        var repo = repos[i]
        f(&repo)
        if repo != repos[i] { repos[i] = repo }
    }

    func syncConversations(_ name: String) async throws {
        guard let repo = repos.first(where: { $0.fullName == name }), let me = me?.login.lowercased() else { return }
        let ev = repo.events
        let baseline = repo.addedAt.addingTimeInterval(-24 * 3600)
        func cursor(_ key: String) -> Date { repo.cursors[key] ?? baseline }
        func query(_ key: String) -> [String: String] {
            ["sort": "updated", "direction": "asc", "per_page": "100", "since": Self.isoFormatter.string(from: cursor(key))]
        }

        var fresh: [InboxItem] = []
        // Committed with the merged items, so a saved state never has a cursor past items it lacks.
        var newCursors: [String: Date] = [:]
        var mentioned = Set<String>()
        var titles: [Int: String] = [:]
        // (number, my comment date, thread root) — applied after new items merge.
        var myReplies: [(number: Int, at: Date, root: Int?)] = []

        if !ev.isDisjoint(with: [.issueOpened, .prOpened, .issueComment, .prComment, .reviewComment]) {
            let issues: [GHIssue] = try await gh.get("/repos/\(name)/issues", query("issues").merging(["state": "all"]) { a, _ in a })
            for issue in issues {
                titles[issue.number] = issue.title
                let kind: EventKind = issue.pullRequest != nil ? .prOpened : .issueOpened
                guard ev.contains(kind), issue.createdAt >= cursor("issues").addingTimeInterval(-1),
                      let user = issue.user, user.login.lowercased() != me else { continue }
                fresh.append(InboxItem(
                    id: "\(name)#\(kind.rawValue)#\(issue.id)", repo: name, kind: kind, number: issue.number,
                    title: issue.title, snippet: snippet(issue.body), author: user.login, avatar: user.avatarUrl,
                    authorIsApp: user.isApp, url: issue.htmlUrl, createdAt: issue.createdAt, state: .unread))
            }
            if let last = issues.map(\.updatedAt).max() { newCursors["issues"] = last }
        }

        if !ev.isDisjoint(with: [.issueOpened, .prOpened, .issueComment, .prComment]) {
            let comments: [GHComment] = try await gh.get("/repos/\(name)/issues/comments", query("comments"))
            for c in comments {
                guard let user = c.user, let number = c.issueUrl.flatMap({ Int($0.lastPathComponent) }) else { continue }
                if user.login.lowercased() == me {
                    myReplies.append((number, c.createdAt, nil))
                    continue
                }
                let kind: EventKind = c.htmlUrl.path.contains("/pull/") ? .prComment : .issueComment
                guard ev.contains(kind), c.createdAt >= cursor("comments").addingTimeInterval(-1) else { continue }
                if mentionsMe(c.body, me) { mentioned.insert("\(name)#c#\(c.id)") }
                fresh.append(InboxItem(
                    id: "\(name)#c#\(c.id)", repo: name, kind: kind, number: number,
                    title: title(for: number, in: name, titles), snippet: snippet(c.body), author: user.login,
                    avatar: user.avatarUrl, authorIsApp: user.isApp, url: c.htmlUrl, createdAt: c.createdAt, state: .unread))
            }
            if let last = comments.map(\.updatedAt).max() { newCursors["comments"] = last }
        }

        if ev.contains(.reviewComment) {
            let comments: [GHComment] = try await gh.get("/repos/\(name)/pulls/comments", query("review"))
            for c in comments {
                guard let user = c.user, let number = c.pullRequestUrl.flatMap({ Int($0.lastPathComponent) }) else { continue }
                let root = c.inReplyToId ?? c.id
                if user.login.lowercased() == me {
                    myReplies.append((number, c.createdAt, root))
                    continue
                }
                guard c.createdAt >= cursor("review").addingTimeInterval(-1) else { continue }
                if mentionsMe(c.body, me) { mentioned.insert("\(name)#r#\(c.id)") }
                fresh.append(InboxItem(
                    id: "\(name)#r#\(c.id)", repo: name, kind: .reviewComment, number: number,
                    title: title(for: number, in: name, titles), snippet: snippet(c.body), author: user.login,
                    avatar: user.avatarUrl, authorIsApp: user.isApp, url: c.htmlUrl, createdAt: c.createdAt,
                    state: .unread, threadRoot: root, path: c.path))
            }
            if let last = comments.map(\.updatedAt).max() { newCursors["review"] = last }
        }

        let known = Set(items.map(\.id))
        var added = fresh.filter { !known.contains($0.id) }
        let commentKinds: Set<EventKind> = [.issueComment, .prComment, .reviewComment]
        let needInfo = Set(added.filter { $0.title == "#\($0.number)" || commentKinds.contains($0.kind) }.map(\.number))
        let reviewNumbers = Set(added.filter { $0.kind == .reviewComment }.map(\.number))
        let info: [Int: ThreadInfo]? = needInfo.isEmpty ? [:]
            : try? await fetchThreads(name, Array(needInfo), participation: true, reviewThreads: reviewNumbers, me: me)
        // The repo may have been stopped, or set to follow something else, while the answers were out: nothing of them is
        // kept, counted or told (the cursors stay, so a repo that is still watched asks again).
        guard isCurrent(repo) else { return }
        // Comments only count when they're on my thread, mention me, or come after I joined the conversation.
        // Always evaluated (and remembered), so switching All comments off later can prune what isn't for me.
        // If the lookup failed (or only partly answered), keep what it couldn't judge rather than silently
        // dropping something addressed to me.
        for i in added.indices {
            let thread = info?[added[i].number]
            if let title = thread?.title { added[i].title = title }
            let isMentioned = mentioned.contains(added[i].id)
            if commentKinds.contains(added[i].kind) {
                added[i].forYou = Self.relevance(added[i], thread: thread, mentioned: isMentioned, me: me)
            }
        }
        if !repo.allComments {
            added = added.filter { $0.forYou != false }
        }
        if !added.isEmpty { items.append(contentsOf: added) }
        if !newCursors.isEmpty { updateRepo(name) { $0.cursors.merge(newCursors) { _, new in new } } }

        // Anything I replied to after it was posted is addressed.
        if !myReplies.isEmpty {
            var all = items
            var changed = false
            for reply in myReplies {
                for i in all.indices where all[i].repo == name && all[i].number == reply.number
                    && all[i].state.isOpen && all[i].createdAt < reply.at {
                    if let root = reply.root {
                        if all[i].threadRoot == root { all[i].state = .addressed; changed = true }
                    } else if EventKind.conversationKinds.contains(all[i].kind) {
                        all[i].state = .addressed
                        changed = true
                    }
                }
            }
            if changed { items = all }
        }

        // From the stored copies: a reply above may have settled an item that just arrived.
        let arrived = Set(added.map(\.id))
        announce(items.filter { arrived.contains($0.id) && $0.state == .unread && $0.createdAt > repo.addedAt })
    }

    struct ThreadInfo {
        var title: String?
        var author: String?
        /// When I commented on (or reviewed) the issue/PR.
        var activity: [Date] = []
        /// Review thread root comment id → when I posted in that thread.
        var reviewActivity: [Int: [Date]] = [:]
        /// The comments/reviews, or the review threads, were cut off: my earlier activity may be beyond them.
        var activityTruncated = false
        var reviewThreadsTruncated = false
    }

    /// GraphQL calls (40 threads each) for the threads new comments landed on: titles, authors and my participation.
    func fetchThreads(_ name: String, _ numbers: [Int], participation: Bool, reviewThreads: Set<Int>,
                      me: String) async throws -> [Int: ThreadInfo] {
        // One at a time: a failed batch fails the lookup, so no thread is ever judged on partial information.
        var result: [Int: ThreadInfo] = [:]
        let sorted = numbers.sorted()
        for start in stride(from: 0, to: sorted.count, by: 40) {
            let batch = sorted[start..<min(start + 40, sorted.count)]
            result.merge(try await fetchThreadBatch(name, batch, participation: participation,
                                                    reviewThreads: reviewThreads, me: me)) { a, _ in a }
        }
        return result
    }

    private func fetchThreadBatch(_ name: String, _ numbers: ArraySlice<Int>, participation: Bool, reviewThreads: Set<Int>,
                                  me: String) async throws -> [Int: ThreadInfo] {
        let parts = name.split(separator: "/")
        let common = participation ? "title author { login } comments(last: 100) { pageInfo { hasPreviousPage } nodes { author { login } createdAt } }" : "title"
        var q = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") {"
        for n in numbers {
            var pr = common
            if participation { pr += " reviews(last: 50) { pageInfo { hasPreviousPage } nodes { author { login } submittedAt } }" }
            if reviewThreads.contains(n) {
                pr += " reviewThreads(last: 60) { pageInfo { hasPreviousPage } nodes { comments(first: 50) { pageInfo { hasNextPage } nodes { databaseId author { login } createdAt } } } }"
            }
            q += " n\(n): issueOrPullRequest(number: \(n)) { ... on Issue { \(common) } ... on PullRequest { \(pr) } }"
        }
        q += " } }"
        let json = try await gh.graphql(q)
        guard let repoObj = (json["data"] as? [String: Any])?["repository"] as? [String: Any] else {
            throw GitHubError(message: "Couldn't load threads for \(name)")
        }

        // GraphQL can answer part of a query alongside `errors` (resource limits, a thread that's gone):
        // a thread it reported on, or left out, is unknown rather than "not mine". An error that says nothing
        // about where it happened makes the whole batch unknown.
        var failed = Set<String>()
        for case let error as [String: Any] in json["errors"] as? [Any] ?? [] {
            guard let alias = (error["path"] as? [Any])?.dropFirst().first as? String else { return [:] }
            failed.insert(alias)
        }

        func nodes(_ obj: Any?, _ key: String) -> [[String: Any]] {
            ((obj as? [String: Any])?[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        }
        func truncated(_ obj: Any?, _ key: String, _ flag: String) -> Bool {
            (((obj as? [String: Any])?[key] as? [String: Any])?["pageInfo"] as? [String: Any])?[flag] as? Bool ?? false
        }
        func login(_ node: [String: Any]) -> String? { ((node["author"] as? [String: Any])?["login"] as? String)?.lowercased() }
        func date(_ node: [String: Any], _ key: String) -> Date? { (node[key] as? String).flatMap { Self.isoFormatter.date(from: $0) } }

        var result: [Int: ThreadInfo] = [:]
        for (key, value) in repoObj {
            guard let n = Int(key.dropFirst()), !failed.contains(key), let obj = value as? [String: Any] else { continue }
            var info = ThreadInfo(title: obj["title"] as? String, author: login(obj))
            info.activity = nodes(obj, "comments").filter { login($0) == me }.compactMap { date($0, "createdAt") }
                + nodes(obj, "reviews").filter { login($0) == me }.compactMap { date($0, "submittedAt") }
            info.activityTruncated = truncated(obj, "comments", "hasPreviousPage") || truncated(obj, "reviews", "hasPreviousPage")
            info.reviewThreadsTruncated = truncated(obj, "reviewThreads", "hasPreviousPage")
            for thread in nodes(obj, "reviewThreads") {
                let comments = nodes(thread, "comments")
                if truncated(thread, "comments", "hasNextPage") { info.reviewThreadsTruncated = true }
                guard let root = comments.first?["databaseId"] as? Int else { continue }
                info.reviewActivity[root] = comments.filter { login($0) == me }.compactMap { date($0, "createdAt") }
            }
            result[n] = info
        }
        return result
    }

    /// The "comments that are for me" rule (used when a repo's All comments switch is off).
    nonisolated static func isRelevant(_ item: InboxItem, thread: ThreadInfo?, mentioned: Bool, me: String) -> Bool {
        guard [.issueComment, .prComment, .reviewComment].contains(item.kind), !mentioned else { return true }
        guard let thread else { return false }
        if thread.author == me { return true }
        if item.kind == .reviewComment {
            return thread.reviewActivity[item.threadRoot ?? -1]?.contains { $0 < item.createdAt } ?? false
        }
        return thread.activity.contains { $0 < item.createdAt }
    }

    /// `isRelevant`, or nil when the thread was cut off before it could say: only a whole view can rule a comment out.
    nonisolated static func relevance(_ item: InboxItem, thread: ThreadInfo?, mentioned: Bool, me: String) -> Bool? {
        if isRelevant(item, thread: thread, mentioned: mentioned, me: me) { return true }
        guard let thread else { return nil }
        let cut = item.kind == .reviewComment ? thread.reviewThreadsTruncated : thread.activityTruncated
        return cut ? nil : false
    }

    nonisolated static func mentions(_ body: String?, _ me: String) -> Bool {
        guard let body else { return false }
        let pattern = "(?<![\\w/@-])@" + NSRegularExpression.escapedPattern(for: me) + "(?![\\w-])"
        return body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func mentionsMe(_ body: String?, _ me: String) -> Bool {
        Self.mentions(body, me)
    }


    /// Review threads: resolution state lives only in GraphQL.
    private func syncThreads(_ name: String) async throws {
        let recent = Date().addingTimeInterval(-21 * 86400)
        let tracked = items.filter { $0.repo == name && $0.kind == .reviewComment && $0.state != .discarded && $0.createdAt > recent }
        let numbers = Array(Set(tracked.map(\.number))).sorted().suffix(20)
        guard !numbers.isEmpty else { return }
        let parts = name.split(separator: "/")
        var q = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") {"
        for n in numbers {
            q += " pr\(n): pullRequest(number: \(n)) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { databaseId } } } } }"
        }
        q += " } }"
        let json = try await gh.graphql(q)
        guard let repoObj = (json["data"] as? [String: Any])?["repository"] as? [String: Any] else { return }

        var resolved: [Int: Bool] = [:]
        for case let pr as [String: Any] in repoObj.values {
            let nodes = (pr["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            for node in nodes {
                let first = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first
                if let id = first?["databaseId"] as? Int, let isResolved = node["isResolved"] as? Bool {
                    resolved[id] = isResolved
                }
            }
        }
        var all = items
        var changed = false
        for i in all.indices where all[i].repo == name && all[i].kind == .reviewComment {
            guard let root = all[i].threadRoot, let r = resolved[root] else { continue }
            if r, all[i].state != .discarded, all[i].state != .resolved { all[i].state = .resolved; changed = true }
            if !r, all[i].state == .resolved { all[i].state = .read; changed = true }
        }
        if changed { items = all }
    }

    /// Checks one repo's CI. A request while one is under way for the same repo waits for that one's answer instead of
    /// asking again, so "Check now" pressed twice, or during a poll, is one round trip.
    func syncCI(_ name: String) async throws {
        if let running = ciChecks[name] { return try await running.value }
        guard let repo = repos.first(where: { $0.fullName == name }), repo.events.contains(.ciMain) else { return }
        let ticket = (ciTickets[name] ?? 0) + 1
        ciTickets[name] = ticket
        let check = Task { @MainActor [self] in
            // A check `endCIChecks` already gave up on leaves what a newer one registered.
            defer { if ciTickets[name] == ticket { ciChecks[name] = nil } }
            do {
                publishCI(name, try await (ciFetch ?? fetchCI)(repo), ticket: ticket)
                publishCIHealth(name, failure: nil, ticket: ticket)
            } catch {
                // An overtaken check (CI switched off, the repo removed, a newer check begun) publishes nothing: its fault is
                // no news of the source as it is now.
                publishCIHealth(name, failure: error.localizedDescription, ticket: ticket)
                throw error
            }
        }
        ciChecks[name] = check
        try await check.value
    }

    /// Whatever is under way for a repo no longer counts: it was removed or its CI turned off, and what comes back must
    /// not bring it back.
    private func endCIChecks(_ name: String) {
        ciTickets[name, default: 0] += 1
        ciChecks[name] = nil
    }

    /// Asks GitHub for a repo's CI, and the commit's headline.
    private func fetchCI(_ repo: RepoConfig) async throws -> CIStatus {
        let name = repo.fullName
        var repo = repo
        if repo.defaultBranch == nil {
            let info: GHRepo = try await gh.get("/repos/\(name)")
            updateRepo(name) { $0.defaultBranch = info.defaultBranch }
            repo.defaultBranch = info.defaultBranch
        }
        let branch = repo.defaultBranch!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let ref = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        // Only push-triggered Actions runs count: issue/comment-triggered workflows also run against the
        // default branch HEAD and would otherwise make CI look red.
        let actions: GHWorkflowRuns = try await gh.get("/repos/\(name)/actions/runs",
                                                       ["branch": branch, "event": "push", "per_page": "30"])
        let sha = actions.workflowRuns.first?.headSha
        let target = sha ?? ref
        async let checksReq: GHCheckRuns = gh.get("/repos/\(name)/commits/\(target)/check-runs", ["per_page": "100"])
        async let statusReq: GHCombinedStatus = gh.get("/repos/\(name)/commits/\(target)/status")
        let (checks, combined) = try await (checksReq, statusReq)
        let reading = Self.readCI(runs: actions.workflowRuns, sha: sha, checks: checks.checkRuns, combined: combined)
        let commit = sha ?? combined.sha
        // The headline comes from the Actions run; a repo with only external CI asks the commit for it (once per commit).
        let title = await ciHeadline(name, commit: commit, runTitle: actions.workflowRuns.first?.displayTitle)
        return CIStatus(state: reading.state, branch: branch, sha: commit,
                        url: URL(string: "https://github.com/\(name)/commit/\(commit)"),
                        failing: reading.failing, checkedAt: Date(), title: title, updatedAt: reading.changedAt)
    }

    /// Takes an answer in, unless a newer check or the repo's removal has overtaken it. Nothing here waits: what the
    /// repo was before (for the notifications) is read in the same step that replaces it.
    func publishCI(_ name: String, _ status: CIStatus, ticket: Int) {
        guard ciTickets[name] == ticket else { return }
        let previous = ci[name]?.state
        // `checkedAt` always differs: only a real change is worth an assignment (and a re-render, and a save).
        ciCheckedAt[name] = status.checkedAt
        if var old = ci[name] {
            old.checkedAt = status.checkedAt
            if old != status { ci[name] = status; save() }
        } else {
            ci[name] = status
            save()
        }

        let (state, commit, branch) = (status.state, status.sha ?? "", status.branch)
        if previous == .success || previous == .pending, state == .failure {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI failing on \(branch)",
                   subtitle: status.failing.prefix(3).joined(separator: ", "), body: "", quiet: false, url: status.url)
        } else if previous == .failure, state == .success {
            notify(id: "https://github.com/\(name)/commit/\(commit)", title: "\(name) · CI back to green",
                   subtitle: branch, body: "", quiet: true, url: status.url)
        }
    }

    /// What CI's three sources say about one commit.
    struct CIReading: Equatable {
        var state: CIState
        var failing: [String]
        /// The latest change among them: an Actions run, an external check run or a legacy status.
        var changedAt: Date?
    }

    /// Folds Actions runs (the latest of each workflow, on `sha`) and their jobs, external check runs and legacy statuses
    /// into one state, the names that failed and when it last changed. Any of the three can be all a repo has.
    nonisolated static func readCI(runs: [GHWorkflowRuns.Run], sha: String?, checks: [GHCheckRuns.Run],
                                   combined: GHCombinedStatus) -> CIReading {
        var latest: [Int: GHWorkflowRuns.Run] = [:]
        for run in runs where run.headSha == sha && latest[run.workflowId] == nil { latest[run.workflowId] = run }
        let external = checks.filter { $0.app?.slug != "github-actions" }

        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        // A failed workflow is named by the jobs that failed in it (each is a check run in the run's own suite); its own
        // name stands in only when none is found. Jobs of runs not chosen above (another trigger) never count.
        let jobs = checks.filter { $0.app?.slug == "github-actions" && bad.contains($0.conclusion ?? "") }
        var failing: [String] = []
        for run in latest.values.filter({ bad.contains($0.conclusion ?? "") }).sorted(by: { $0.name < $1.name }) {
            let failed = jobs.filter { run.checkSuiteId != nil && $0.checkSuite?.id == run.checkSuiteId }.map(\.name)
            failing += failed.isEmpty ? [run.name] : failed
        }
        failing += external.filter { bad.contains($0.conclusion ?? "") }.map(\.name)
        failing += combined.statuses.filter { $0.state == "failure" || $0.state == "error" }.map(\.context)
        let pending = latest.values.contains { $0.status != "completed" }
            || external.contains { $0.status != "completed" }
            || combined.statuses.contains { $0.state == "pending" }
        let any = !latest.isEmpty || !external.isEmpty || combined.totalCount > 0
        let state: CIState = !failing.isEmpty ? .failure : pending ? .pending : any ? .success : .none
        let changed = latest.values.compactMap(\.updatedAt)
            + external.compactMap { $0.completedAt ?? $0.startedAt }
            + combined.statuses.compactMap { $0.updatedAt ?? $0.createdAt }
        return CIReading(state: state, failing: failing, changedAt: changed.max())
    }

    /// The commit's headline: the Actions run's title when there is one; else what the commit says, asked once per
    /// commit (a repo with only external CI has no run to read it from).
    func ciHeadline(_ name: String, commit: String, runTitle: String?) async -> String? {
        if let runTitle { return runTitle }
        if let known = ci[name], known.sha == commit, let title = known.title { return title }
        let found: GHCommit? = try? await gh.get("/repos/\(name)/commits/\(commit)")
        return found?.headline
    }

    /// GitHub's search returns at most 1000 results, 100 a page.
    private static let reviewRequestPages = 10

    func syncReviewRequests() async {
        var found: [GHIssue] = []
        var complete = false
        // Switched off (or off and on) while a page was out: what comes back is no answer to the source as it is now.
        let generation = reviewGeneration
        do {
            for page in 1...Self.reviewRequestPages {
                let result: GHSearch<GHIssue> = try await gh.get("/search/issues", [
                    "q": "is:open is:pr user-review-requested:@me archived:false", "per_page": "100", "page": "\(page)"])
                guard generation == reviewGeneration else { return }
                found += result.items
                if result.incompleteResults == true { break }
                if found.count >= (result.totalCount ?? (result.items.count < 100 ? found.count : .max)) {
                    complete = true
                    break
                }
                // A short page with more still to come: GitHub lost some, so what was read is not everything.
                if result.items.count < 100 { break }
            }
        } catch {
            guard generation == reviewGeneration else { return }
            // The pages that did arrive are real requests: kept, as a search that stopped short (nothing can be told missing).
            if !found.isEmpty { applyReviewRequests(found, complete: false) }
            return
        }
        applyReviewRequests(found, complete: complete)
    }

    /// `complete`: `found` is every pending request. Only then can a missing one be told from one that moved off the
    /// pages read (past 1000 results, or a search GitHub cut short), which must not be marked answered.
    func applyReviewRequests(_ found: [GHIssue], complete: Bool) {
        let first = !settings.didInitialReviewSync
        // A first search that couldn't list everything (cut short, or past ten pages) leaves the rest of what was already there
        // to turn up later: a request last touched before it is that backlog, one touched after it is news.
        let baseline = settings.reviewBaselineAt
        var current = Set<String>()
        var added: [InboxItem] = []
        for pr in found {
            let id = "rr#\(pr.id)"
            current.insert(id)
            guard let user = pr.user, let repoURL = pr.repositoryUrl else { continue }
            if let i = items.firstIndex(where: { $0.id == id }) {
                // Back after I dealt with it: a new request. (Done while still requested stays Done.)
                guard items[i].state == .addressed else { continue }
                items[i].state = .unread
                items[i].createdAt = first ? pr.updatedAt : Date()
                added.append(items[i])
                continue
            }
            let backlog = first || baseline.map { pr.updatedAt <= $0 } == true
            let item = InboxItem(
                id: id, repo: repoName(from: repoURL), kind: .reviewRequested, number: pr.number, title: pr.title,
                snippet: snippet(pr.body), author: user.login, avatar: user.avatarUrl, authorIsApp: user.isApp,
                url: pr.htmlUrl, createdAt: backlog ? pr.updatedAt : Date(), state: .unread)
            items.append(item)
            if !backlog { added.append(item) }
        }
        // Request disappeared: I reviewed it (or it was withdrawn/closed). A Done one is forgotten, so a new request
        // on the same PR starts fresh.
        requested = complete ? current : requested.map { $0.union(current) }
        if complete {
            for i in items.indices where items[i].kind == .reviewRequested && items[i].state.isOpen && !current.contains(items[i].id) {
                items[i].state = .addressed
            }
            items.removeAll { $0.kind == .reviewRequested && $0.state == .discarded && !current.contains($0.id) }
        }
        if first {
            // The first answer is the baseline, whether or not it was the whole list: from here on a request is told from backlog.
            settings.didInitialReviewSync = true
            settings.reviewBaselineAt = complete ? nil : Date()
        } else if complete, baseline != nil {
            settings.reviewBaselineAt = nil
        }
        announce(added)
    }

    func prune(now: Date = Date()) {
        // A Done request that is still requested stays, or the next poll would bring it back unread: however old, however
        // many newer items there are.
        func protected(_ item: InboxItem) -> Bool {
            item.kind == .reviewRequested && item.state == .discarded && requested?.contains(item.id) ?? true
        }
        func expired(_ item: InboxItem) -> Bool {
            if protected(item) { return false }
            let age = now.timeIntervalSince(item.createdAt)
            return (!item.state.isOpen && age > 14 * 86400) || age > 60 * 86400
        }
        if items.contains(where: expired) { items.removeAll(where: expired) }
        // The protected ones are outside the cap too.
        let held = items.filter(protected)
        if items.count - held.count > Self.itemCap {
            let rest = items.filter { !protected($0) }.sorted { $0.createdAt > $1.createdAt }
            items = held + rest.prefix(Self.itemCap)
        }
    }

    /// The most items kept, newest first, whatever their age.
    static let itemCap = 1500

    // MARK: Notifications

    private func announce(_ new: [InboxItem]) {
        guard !new.isEmpty else { return }
        let important = new.filter { !isLowPriority($0) }
        if new.count > 4 {
            let repos = Set(new.map(\.repo)).sorted()
            notify(id: Notifier.summaryPrefix + UUID().uuidString, title: "\(new.count) new items",
                   subtitle: repos.joined(separator: ", "), body: "", quiet: important.isEmpty, repos: repos)
            return
        }
        for item in new {
            let path = item.path.map { " · \($0)" } ?? ""
            notify(id: item.id, title: "\(item.kind.label) · \(item.repo)#\(item.number)", subtitle: item.title,
                   body: "@\(item.author)\(path): \(item.snippet)", quiet: isLowPriority(item), url: item.url)
        }
    }

    private func notify(id: String, title: String, subtitle: String, body: String, quiet: Bool, url: URL? = nil,
                        repos: [String] = []) {
        guard settings.notifications, !isSnoozed else { return }
        notifier.post(id: id, title: title, subtitle: subtitle, body: body, quiet: quiet, url: url, repos: repos)
    }

    // MARK: Helpers

    private func title(for number: Int, in repo: String, _ titles: [Int: String]) -> String {
        titles[number] ?? items.first(where: { $0.repo == repo && $0.number == number })?.title ?? "#\(number)"
    }

    private func repoName(from url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }

    private func snippet(_ body: String?) -> String {
        guard let body else { return "" }
        var text = body
        // Drop HTML comments (PR templates, bot metadata) and fenced code.
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " [code] ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[#*_>`]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespaces).prefix(280))
    }
}
