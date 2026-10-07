import AppKit
import CoreServices
import Foundation

/// A Claude Code session of the Claude desktop app, as read from the app's own files. Nothing here is a public API:
/// every field is optional on disk, and anything unexpected is skipped rather than trusted.
struct ClaudeSession: Identifiable, Hashable {
    var id: String
    var title: String
    /// Repository root (worktrees collapse onto it); nil for scratch chats, which have no folder of their own.
    var folder: String?
    var isArchived = false
    var completedTurns = 0
    var lastActivity: Date
    var lastFocused: Date?
    var lastUserMessage: Date?
    /// The app's own one-line summary of the latest finished turn.
    var summary: Summary?
    var running = false
    /// Claude Code's own session id: names the transcript (`~/.claude/projects/*/<id>.jsonl`).
    var cliID: String?

    struct Summary: Hashable {
        var blocked: Bool
        var detail: String
    }

    var folderName: String { folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Scratch" }
    /// Mute key: the folder path, or "" for scratch chats.
    var folderKey: String { folder ?? "" }
    /// Changes whenever a turn finishes or a new message is sent.
    var activity: String { "\(completedTurns)|\(Int((lastUserMessage ?? .distantPast).timeIntervalSince1970))" }
}

/// What a working agent is on right now, and since when.
struct ClaudeActivity: Hashable {
    var text: String
    var since: Date
    /// Stopped mid-turn on you: a question, or a plan to approve.
    var waitsForYou = false
}

/// A subagent or shell command a session started in the background, still running.
struct ClaudeTask: Hashable, Identifiable {
    enum Kind: Hashable { case agent, command }
    var id: String
    var kind: Kind
    var title: String
    var since: Date
    /// What a subagent is on (from its own transcript); commands don't say.
    var activity: ClaudeActivity? = nil
}

enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Claude", isDirectory: true)
    static let sessionsDir = root.appendingPathComponent("claude-code-sessions", isDirectory: true)
    static let localStorageDir = root.appendingPathComponent("Local Storage/leveldb", isDirectory: true)
    /// A turn older than this with no summary is a session that died mid-turn, not one still working.
    static let runningTimeout: TimeInterval = 2 * 3600

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            || FileManager.default.fileExists(atPath: sessionsDir.path)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Opens the conversation in the app (its own link format, the one it hands out for sessions).
    static func open(_ id: String) {
        guard let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a new Code session in a folder (the app's own link, the one its dock menu uses for recent folders).
    static func newSession(in folder: String) {
        var components = URLComponents(string: "claude://code/new")
        components?.queryItems = [URLQueryItem(name: "folder", value: folder)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Sessions

    private struct Raw: Decodable {
        var sessionId: String?
        var cliSessionId: String?
        var title: String?
        var cwd: String?
        var originCwd: String?
        var gitAnchorsFolderRealpath: String?
        var isArchived: Bool?
        var completedTurns: Int?
        var createdAt: Double?
        var lastActivityAt: Double?
        var lastFocusedAt: Double?
        var latestUserFrameAt: Double?
        var postTurnSummary: Summary?
        var postTurnSummaryFor: String?
        var lastAssistantUuid: String?

        struct Summary: Decodable {
            var status_category: String?
            var status_detail: String?
        }
    }

    static func decodeSession(_ data: Data, appRunning: Bool = true, now: Date = Date()) -> ClaudeSession? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let id = raw.sessionId, id.hasPrefix("local_") else {
            return nil
        }
        func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        let path = raw.gitAnchorsFolderRealpath ?? raw.originCwd ?? raw.cwd
        let scratch = path.map { $0.contains("/Claude/scratch-workspaces/") } ?? true
        let lastActivity = date(raw.lastActivityAt) ?? date(raw.createdAt) ?? .distantPast
        // The summary is written once a turn is over and names the message it covers; while a turn runs it is
        // missing or still points at an older message.
        let current = raw.postTurnSummaryFor != nil && raw.postTurnSummaryFor == raw.lastAssistantUuid
        let summary = current ? raw.postTurnSummary.map {
            ClaudeSession.Summary(blocked: $0.status_category == "blocked",
                                  detail: ($0.status_detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } : nil
        let lastMessage = date(raw.latestUserFrameAt)
        let running = appRunning && !current && raw.isArchived != true
            && lastMessage.map { now.timeIntervalSince($0) < runningTimeout } ?? false
        return ClaudeSession(
            id: id, title: raw.title?.isEmpty == false ? raw.title! : "Untitled session",
            folder: scratch ? nil : path, isArchived: raw.isArchived ?? false,
            completedTurns: raw.completedTurns ?? 0, lastActivity: lastActivity,
            lastFocused: date(raw.lastFocusedAt), lastUserMessage: lastMessage,
            summary: summary, running: running, cliID: raw.cliSessionId)
    }

    enum ReadError: Error {
        case missing, unreadable
    }

    /// Re-decodes only the files whose modification date changed since the last call.
    final class SessionReader {
        private var cache: [URL: (Date, ClaudeSession?)] = [:]

        func read() -> Result<[ClaudeSession], ReadError> {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: Claude.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return .failure(.missing)
            }
            let appRunning = Claude.isRunning
            var sessions: [ClaudeSession] = []
            var seen = Set<URL>()
            var files = 0
            for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
                files += 1
                seen.insert(url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                var session: ClaudeSession?
                if let cached = cache[url], cached.0 == modified {
                    session = cached.1
                } else {
                    session = (try? Data(contentsOf: url)).flatMap { Claude.decodeSession($0) }
                    cache[url] = (modified, session)
                }
                // Running depends on the clock and on the app being open, so it's recomputed every time.
                if var s = session {
                    if s.running, !appRunning || Date().timeIntervalSince(s.lastUserMessage ?? .distantPast) > Claude.runningTimeout {
                        s.running = false
                    }
                    sessions.append(s)
                }
            }
            cache = cache.filter { seen.contains($0.key) }
            if files > 0 && sessions.isEmpty { return .failure(.unreadable) }
            return .success(sessions)
        }
    }

    // MARK: Activity (what a working agent is doing, from its transcript)

    static let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Finds transcripts and reads only their tail, again only when they changed.
    final class ActivityReader {
        private var paths: [String: URL] = [:]
        private var cache: [URL: (Date, ClaudeActivity?)] = [:]
        /// Read from the refresh queue and (for icons) from the main thread.
        private let lock = NSLock()

        func activity(for cliID: String) -> ClaudeActivity? {
            guard let url = transcript(cliID) else { return nil }
            lock.lock()
            defer { lock.unlock() }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let cached = cache[url], cached.0 == modified { return cached.1 }
            let activity = Claude.activity(tail: Claude.tail(of: url))
            cache[url] = (modified, activity)
            return activity
        }

        func transcript(_ cliID: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            if let known = paths[cliID], FileManager.default.fileExists(atPath: known.path) { return known }
            let dirs = (try? FileManager.default.contentsOfDirectory(at: Claude.transcriptsDir, includingPropertiesForKeys: nil)) ?? []
            let found = dirs.lazy.map { $0.appendingPathComponent("\(cliID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
            paths[cliID] = found
            return found
        }
    }

    static func tail(of url: URL, bytes: Int = 96 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? handle.readToEnd()) ?? Data()
    }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The last step in a transcript: the tool being run, or thinking between steps.
    static func activity(tail: Data) -> ClaudeActivity? {
        let lines = tail.split(separator: UInt8(ascii: "\n")).reversed()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user" else { continue }
            let since = (obj["timestamp"] as? String).flatMap { try? Date($0, strategy: Self.iso) } ?? Date()
            let content = (obj["message"] as? [String: Any])?["content"]
            let parts = content as? [[String: Any]] ?? []
            if type == "assistant" {
                if let tool = parts.last(where: { $0["type"] as? String == "tool_use" }) {
                    let name = tool["name"] as? String ?? ""
                    return ClaudeActivity(text: describe(tool: name, input: tool["input"] as? [String: Any] ?? [:]),
                                          since: since, waitsForYou: ["AskUserQuestion", "ExitPlanMode"].contains(name))
                }
                return ClaudeActivity(text: parts.contains { $0["type"] as? String == "text" } ? "Writing" : "Thinking", since: since)
            }
            // A tool's result, or your message: the model is working out the next step.
            return ClaudeActivity(text: "Thinking", since: since)
        }
        return nil
    }

    static func describe(tool name: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        }
        func short(_ s: String, _ n: Int = 48) -> String {
            let line = s.split(separator: "\n").first.map(String.init) ?? s
            return line.count > n ? String(line.prefix(n - 1)) + "…" : line
        }
        switch name {
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return short(d) }
            return "Running " + short(input["command"] as? String ?? "a command", 36)
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + file(name == "NotebookEdit" ? "notebook_path" : "file_path")
        case "Write": return "Writing " + file()
        case "Read": return "Reading " + file()
        case "Grep", "Glob": return "Searching" + ((input["pattern"] as? String).map { " for " + short($0, 28) } ?? "")
        case "Agent", "Task": return "Delegating" + ((input["description"] as? String).map { ": " + short($0, 36) } ?? "")
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading " + ((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page")
        case "TodoWrite": return "Planning"
        // Stopped on you: the row's second line is the question itself, or the plan's title, when the input has it.
        case "AskUserQuestion":
            let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return first.flatMap { $0.isEmpty ? nil : short($0, 120) } ?? "Asking you a question"
        case "ExitPlanMode":
            // A plan is Markdown: its first line is usually a heading.
            let title = (input["plan"] as? String)?.split(separator: "\n").lazy
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*").union(.whitespaces)) }
                .first { !$0.isEmpty }
            return title.map { "Approve the plan: " + short($0, 96) } ?? "Waiting for you to approve a plan"
        case "Skill": return "Using " + ((input["skill"] as? String) ?? "a skill")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "a tool"
                return "Using " + (server.count > 20 ? "a connector" : server)
            }
            return name.isEmpty ? "Working" : "Using " + name
        }
    }

    // MARK: Background (subagents and shell commands still running after a turn)

    /// Claude Code lists each session's background tasks in `<root>/<project>/<cliID>/tasks/<id>.output`: a symlink to
    /// the transcript for a subagent, a file the command writes to for a shell command.
    static let tasksRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
    /// A subagent whose transcript hasn't moved in this long died with its session (or the app).
    static let agentTimeout: TimeInterval = 30 * 60

    /// Every task folder, by the session it belongs to.
    static func taskFolders() -> [String: URL] {
        let fm = FileManager.default
        var folders: [String: URL] = [:]
        for project in (try? fm.contentsOfDirectory(at: tasksRoot, includingPropertiesForKeys: nil)) ?? [] {
            for session in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [] {
                let tasks = session.appendingPathComponent("tasks", isDirectory: true)
                if fm.fileExists(atPath: tasks.path) { folders[session.lastPathComponent] = tasks }
            }
        }
        return folders
    }

    /// Files under `tasksRoot` that a process of yours has as its output: the shell commands still running. A command's
    /// output stays open exactly as long as it runs, so this is the system's answer, with no timeout to guess.
    static func openTaskOutputs() -> Set<String> {
        let prefix = tasksRoot.path + "/"
        let uid = getuid()
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var open = Set<String>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var bsd = proc_bsdshortinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbsi_uid == uid else { continue }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if path.hasPrefix(prefix) { open.insert(path) }
        }
        return open
    }

    /// The tasks a session still has running. Finished ones are remembered, so a session's list is only read again when
    /// its folder or transcript changes.
    final class TaskReader {
        private var finished = Set<String>()
        private var titles: [String: String] = [:]
        private var agentActivity: [URL: (Date, ClaudeActivity?)] = [:]
        /// Task ids announced as ended in each session transcript. Transcripts only grow, so only new bytes are searched.
        private var scans: [URL: (offset: Int, ended: Set<String>, inode: UInt64)] = [:]

        /// Reads only what was appended since the last scan; a replaced or shortened file is scanned from the start.
        private func scanTranscript(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return }
            let inode = UInt64(info.st_ino), size = Int(info.st_size)
            var scan = scans[url] ?? (0, [], inode)
            if scan.inode != inode || size < scan.offset { scan = (0, [], inode) }
            guard size > scan.offset, let handle = try? FileHandle(forReadingFrom: url) else { scans[url] = scan; return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(scan.offset))
            if let chunk = try? handle.readToEnd() {
                scan.offset = Claude.scanEnds(chunk, base: scan.offset, into: &scan.ended)
            }
            scans[url] = scan
        }

        /// Whether some command in the folder is still unaccounted for, i.e. whether the process list is worth reading.
        func needsOpenOutputs(in folder: URL) -> Bool {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
            return entries.contains { entry in
                entry.pathExtension == "output" && !finished.contains(entry.deletingPathExtension().lastPathComponent)
                    && (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            }
        }

        func tasks(in folder: URL, transcript: URL?, openOutputs: Set<String>, now: Date = Date()) -> [ClaudeTask] {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .creationDateKey]
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            var tasks: [ClaudeTask] = []
            // The transcript is read in full at most once per call, and only for a command's title.
            var whole: Data??
            func transcriptData() -> Data? {
                if whole == nil { whole = .some(transcript.flatMap { try? Data(contentsOf: $0) }) }
                return whole!
            }
            var scanned = false
            func ended(_ id: String) -> Bool {
                guard let transcript else { return false }
                if !scanned {
                    scanned = true
                    scanTranscript(transcript)
                }
                return scans[transcript]?.ended.contains(id) == true
            }
            for entry in entries where entry.pathExtension == "output" {
                let id = entry.deletingPathExtension().lastPathComponent
                guard !finished.contains(id) else { continue }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let since = values?.creationDate ?? now
                if values?.isSymbolicLink == true {
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: entry.path) else { continue }
                    let agent = URL(fileURLWithPath: target)
                    let modified = (try? agent.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    // Its end is announced to the session that started it.
                    if now.timeIntervalSince(modified) > Claude.agentTimeout || ended(id) {
                        finished.insert(id)
                        continue
                    }
                    let title = titles[id] ?? Claude.agentTitle(meta: agent.deletingPathExtension().appendingPathExtension("meta.json"))
                    titles[id] = title
                    tasks.append(ClaudeTask(id: id, kind: .agent, title: title, since: since, activity: activity(agent, modified)))
                } else {
                    guard openOutputs.contains(entry.path) else {
                        // (A file only just listed may not be open yet.)
                        if now.timeIntervalSince(since) > 5 { finished.insert(id) }
                        continue
                    }
                    let title = titles[id] ?? transcriptData().flatMap { Claude.commandTitle(id, in: $0) } ?? "Background command"
                    titles[id] = title
                    tasks.append(ClaudeTask(id: id, kind: .command, title: title, since: since))
                }
            }
            return tasks.sorted { $0.since < $1.since }
        }

        private func activity(_ url: URL, _ modified: Date) -> ClaudeActivity? {
            if let cached = agentActivity[url], cached.0 == modified { return cached.1 }
            let activity = Claude.activity(tail: Claude.tail(of: url))
            agentActivity[url] = (modified, activity)
            return activity
        }
    }

    /// Collects the ids of every `<task-id>…</task-id>` notice from `base` on, where `chunk` is the file's bytes from
    /// there. Returns where to resume: just short of the end (a tag may be cut), or at an unfinished notice.
    @discardableResult
    static func scanEnds(_ chunk: Data, base: Int, into ended: inout Set<String>) -> Int {
        let open = Data("<task-id>".utf8), close = Data("</task-id>".utf8)
        var resume = max(0, chunk.count - open.count + 1)
        var cursor = chunk.startIndex
        while let found = chunk.range(of: open, in: cursor..<chunk.endIndex) {
            let from = found.upperBound
            guard let end = chunk.range(of: close, in: from..<min(chunk.endIndex, from + 200)) else {
                if chunk.endIndex - found.lowerBound < 300 { resume = min(resume, found.lowerBound - chunk.startIndex) }
                cursor = from
                continue
            }
            ended.insert(String(decoding: chunk[from..<end.lowerBound], as: UTF8.self))
            cursor = end.upperBound
        }
        return base + resume
    }

    /// The session's transcript has the notice Claude Code sends when a task ends.
    static func announcesEnd(of id: String, in transcript: Data) -> Bool {
        transcript.range(of: Data("<task-id>\(id)</task-id>".utf8)) != nil
    }

    static func agentTitle(meta: URL) -> String {
        struct Meta: Decodable { var description: String? }
        let description = (try? Data(contentsOf: meta)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }?.description
        return description?.isEmpty == false ? description! : "Subagent"
    }

    /// What the session called the command: the description (or command) of the call that answered "…with ID: <id>".
    static func commandTitle(_ id: String, in transcript: Data) -> String? {
        func line(around range: Range<Data.Index>) -> [String: Any]? {
            let newline = UInt8(ascii: "\n")
            let start = transcript[..<range.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? transcript.startIndex
            let end = transcript[range.upperBound...].firstIndex(of: newline) ?? transcript.endIndex
            return try? JSONSerialization.jsonObject(with: transcript[start..<end]) as? [String: Any]
        }
        func content(_ obj: [String: Any]?) -> [[String: Any]] {
            (obj?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        }
        guard let launched = transcript.range(of: Data("with ID: \(id).".utf8)),
              let callID = content(line(around: launched)).lazy.compactMap({ $0["tool_use_id"] as? String }).first,
              let called = transcript.range(of: Data("\"id\":\"\(callID)\"".utf8)),
              let call = content(line(around: called)).first(where: { $0["id"] as? String == callID }),
              let input = call["input"] as? [String: Any] else { return nil }
        let text = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? input["command"] as? String
        return text.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
    }

    // MARK: Unread (the sidebar's blue dots)

    private static let unreadKey = Array("epitaxy-unread-v1".utf8)

    /// Session ids with a blue dot in the app's sidebar. The app writes this to disk lazily (up to ~30 s late).
    static func unreadIDs() -> Set<String>? {
        guard let raw = LevelDB.latest(in: localStorageDir, keySuffix: unreadKey) else { return nil }
        return parseUnread(raw)
    }

    /// Chromium Local Storage values start with an encoding byte: 1 = Latin-1, 0 = UTF-16LE.
    static func parseUnread(_ raw: [UInt8]) -> Set<String>? {
        guard let first = raw.first else { return nil }
        let body = Data(raw.dropFirst())
        let text = first == 0 ? String(data: body, encoding: .utf16LittleEndian) : String(data: body, encoding: .isoLatin1)
        struct Stored: Decodable {
            struct State: Decodable { var unreadIds: [String]? }
            var state: State?
        }
        guard let data = text?.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let ids = stored.state?.unreadIds else { return nil }
        return Set(ids)
    }
}

/// FSEvents on a few folders (recursive), coalesced. Events arrive on a utility queue, where `relevant` filters
/// them; only a relevant batch hops to the main queue to call `handler`.
final class FolderWatcher {
    /// What the stream's callback holds (retained by the stream itself, so a callback in flight never outlives it).
    private final class Callbacks {
        let relevant: (([String]) -> Bool)?
        let handler: () -> Void
        init(relevant: (([String]) -> Bool)?, handler: @escaping () -> Void) {
            self.relevant = relevant
            self.handler = handler
        }
    }

    private static let queue = DispatchQueue(label: "lookout.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(_ urls: [URL], latency: TimeInterval = 0.2, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: nil, handler: handler))
    }

    /// Per-file events: `relevant` gets the paths that changed (off the main thread), so the handler only runs for
    /// the ones that matter.
    init(_ urls: [URL], latency: TimeInterval = 0.2, relevant: @escaping ([String]) -> Bool, handler: @escaping () -> Void) {
        start(urls, latency: latency, Callbacks(relevant: relevant, handler: handler))
    }

    private func start(_ urls: [URL], latency: TimeInterval, _ callbacks: Callbacks) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(callbacks).toOpaque(),
                                           retain: nil, release: { info in
            if let info { Unmanaged<Callbacks>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let callbacks = Unmanaged<Callbacks>.fromOpaque(info).takeUnretainedValue()
            if let relevant = callbacks.relevant,
               !relevant(unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []) { return }
            DispatchQueue.main.async { callbacks.handler() }
        }
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        if callbacks.relevant != nil {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, urls.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged.passUnretained(callbacks).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - Background reading

/// Everything one read of the app produced. `sessions` is nil for an activity-only refresh.
struct ClaudeSnapshot {
    var link: ClaudeLink?
    var sessions: [ClaudeSession]?
    var appUnread: Set<String>?
    var frontmost = false
    var activity: [String: ClaudeActivity]?
    var tasks: [String: [ClaudeTask]]?
    /// What the store looked like when the read was asked for (see `Store.applyClaude`).
    var stamp = ClaudeStamp()
}

/// `generation` changes when the extension is switched; `revision` when you change something about an agent.
struct ClaudeStamp: Equatable {
    var generation = 0
    var revision = 0
}

/// Reads the app's files on its own serial queue (the readers keep caches and aren't thread-safe), so none of it
/// touches the main thread. Requests made while a read is running are folded into one more read afterwards.
final class ClaudeFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lookout.claude", qos: .utility)
    private let sessionReader = Claude.SessionReader()
    private let taskReader = Claude.TaskReader()
    let activityReader: Claude.ActivityReader
    private let lock = NSLock()
    private var scheduled = false
    private var wantFull = false
    private var wantActivity = false
    private var wantUnread = false
    private var stamp = ClaudeStamp()
    private var deliver: (@MainActor (ClaudeSnapshot) -> Void)?
    private var relevant = Set<String>()
    // Only touched on `queue`.
    private var live: [ClaudeSession]?
    private var allSessions: [ClaudeSession]?
    private var openCache: (Date, Set<String>)?

    init(activityReader: Claude.ActivityReader) { self.activityReader = activityReader }

    /// Reads (everything, or just activity and tasks for the sessions seen last) and calls `apply` on the main thread.
    /// `unreadOnly` re-reads just the sidebar dots (the sessions are those of the last read).
    func request(full: Bool, unreadOnly: Bool = false, stamp: ClaudeStamp, apply: @escaping @MainActor (ClaudeSnapshot) -> Void) {
        lock.lock()
        self.stamp = stamp
        deliver = apply
        if full { wantFull = true } else if unreadOnly { wantUnread = true } else { wantActivity = true }
        let start = !scheduled
        scheduled = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                let full = wantFull || (wantUnread && wantActivity), any = wantFull || wantActivity || wantUnread
                let unread = wantUnread && !wantFull && !wantActivity
                let stamp = stamp, apply = deliver
                wantFull = false
                wantActivity = false
                wantUnread = false
                if !any { scheduled = false }
                lock.unlock()
                guard any else { return }
                var snapshot = unread ? readUnread() : read(full: full)
                snapshot.stamp = stamp
                guard let apply else { continue }
                DispatchQueue.main.async { MainActor.assumeIsolated { apply(snapshot) } }
            }
        }
    }

    /// Whether a changed transcript path belongs to a session that is working or has background tasks.
    func isRelevant(_ paths: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains { path in relevant.contains { path.contains($0) } }
    }

    /// Only the dots: the sessions are those of the last read, so a full read is needed first.
    private func readUnread() -> ClaudeSnapshot {
        guard let sessions = allSessions else { return read(full: true) }
        var snapshot = ClaudeSnapshot()
        snapshot.link = .ok
        snapshot.sessions = sessions
        snapshot.appUnread = Claude.unreadIDs()
        snapshot.frontmost = Claude.isFrontmost
        return snapshot
    }

    private func read(full: Bool) -> ClaudeSnapshot {
        var snapshot = ClaudeSnapshot()
        if full || live == nil {
            switch sessionReader.read() {
            case .failure(.missing):
                allSessions = nil
                snapshot.link = .missing
                return snapshot
            case .failure:
                allSessions = nil
                snapshot.link = .unreadable
                return snapshot
            case .success(let sessions):
                snapshot.link = .ok
                snapshot.sessions = sessions
                snapshot.appUnread = Claude.unreadIDs()
                snapshot.frontmost = Claude.isFrontmost
                allSessions = sessions
                live = sessions.filter { !$0.isArchived }
            }
        }
        let sessions = live ?? []
        var activity: [String: ClaudeActivity] = [:]
        var watched = Set<String>()
        for session in sessions where session.running {
            guard let cli = session.cliID else { continue }
            watched.insert(cli)
            if let found = activityReader.activity(for: cli) { activity[session.id] = found }
        }
        var tasks: [String: [ClaudeTask]] = [:]
        let folders = Claude.isRunning ? Claude.taskFolders() : [:]
        let idle = sessions.filter { !$0.running && $0.cliID.map { folders[$0] != nil } == true }
        if !idle.isEmpty {
            // The process list is only worth walking while some command's fate is still unknown.
            let open = idle.contains { $0.cliID.flatMap { folders[$0] }.map(taskReader.needsOpenOutputs) == true }
                ? openOutputs() : []
            for session in idle {
                guard let cli = session.cliID, let folder = folders[cli] else { continue }
                watched.insert(cli)
                let found = taskReader.tasks(in: folder, transcript: activityReader.transcript(cli), openOutputs: open)
                if !found.isEmpty { tasks[session.id] = found }
            }
        }
        lock.lock()
        relevant = watched
        lock.unlock()
        snapshot.activity = activity
        snapshot.tasks = tasks
        return snapshot
    }

    private func openOutputs() -> Set<String> {
        if let (at, set) = openCache, Date().timeIntervalSince(at) < 2 { return set }
        let set = Claude.openTaskOutputs()
        openCache = (Date(), set)
        return set
    }
}
