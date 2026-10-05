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

        func activity(for cliID: String) -> ClaudeActivity? {
            guard let url = transcript(cliID) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let cached = cache[url], cached.0 == modified { return cached.1 }
            let activity = Claude.activity(tail: Claude.tail(of: url))
            cache[url] = (modified, activity)
            return activity
        }

        func transcript(_ cliID: String) -> URL? {
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

    /// The last step in a transcript: the tool being run, or thinking between steps.
    static func activity(tail: Data) -> ClaudeActivity? {
        let lines = tail.split(separator: UInt8(ascii: "\n")).reversed()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user" else { continue }
            let since = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
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
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode": return "Waiting for you to approve a plan"
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

/// FSEvents on a few folders (recursive), coalesced; calls back on the main queue.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init(_ urls: [URL], latency: TimeInterval = 0.2, handler: @escaping () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, urls.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
