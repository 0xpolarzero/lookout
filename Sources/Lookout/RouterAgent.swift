import AppKit
import Foundation
import Observation

/// What the Router's process writes on stdout (stream-json), as far as the chat cares. Pure, so it is tested on sample lines.
enum RouterStream {
    enum Event: Equatable {
        /// `system/init`: the process's Claude Code session (to resume it).
        case started(sessionID: String)
        case text(String)
        /// A tool call, with its string (and boolean) arguments.
        case toolUse(id: String, name: String, input: [String: String])
        case toolResult(id: String, isError: Bool, text: String)
        /// A session wrote to the Router (`<cross-session-message from-name=…>`).
        case peer(from: String, text: String)
        /// A turn ended.
        case result(isError: Bool, text: String)
        /// Claude Code asks before a tool runs (`control_request` `can_use_tool`): `input`'s string fields, and the names of
        /// any that aren't strings (which no allowed call has).
        case permission(id: String, tool: String, input: [String: String], otherFields: [String])
    }

    static func parse(_ line: Data) -> [Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init", let id = obj["session_id"] as? String else { return [] }
            return [.started(sessionID: id)]
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    var input: [String: String] = [:]
                    for (key, value) in block["input"] as? [String: Any] ?? [:] {
                        if let s = value as? String { input[key] = s }
                        else if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { input[key] = n.boolValue ? "true" : "false" }
                    }
                    return .toolUse(id: id, name: name, input: input)
                default:
                    return nil
                }
            }
        case "user":
            let content = (obj["message"] as? [String: Any])?["content"]
            if let text = content as? String { return peer(text).map { [$0] } ?? [] }
            var events: [Event] = []
            for block in content as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    events.append(.toolResult(id: id, isError: block["is_error"] as? Bool ?? false, text: Self.text(block["content"])))
                case "text":
                    if let event = peer(block["text"] as? String ?? "") { events.append(event) }
                default:
                    continue
                }
            }
            return events
        case "control_request":
            guard let id = obj["request_id"] as? String, let request = obj["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool" else { return [] }
            var strings: [String: String] = [:], others: [String] = []
            for (key, value) in request["input"] as? [String: Any] ?? [:] {
                if let s = value as? String { strings[key] = s } else { others.append(key) }
            }
            return [.permission(id: id, tool: request["tool_name"] as? String ?? "", input: strings, otherFields: others.sorted())]
        case "result":
            let isError = obj["is_error"] as? Bool ?? (obj["subtype"] as? String != "success")
            let errors = (obj["errors"] as? [String] ?? []).filter { !$0.hasPrefix("[ede_diagnostic]") }
            let text = (obj["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? errors.joined(separator: "\n")
            return [.result(isError: isError, text: text)]
        default:
            return []
        }
    }

    /// A tool result's text, whether a string or text blocks.
    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A message another session sent: who from, and its text without the envelope.
    static func peer(_ text: String) -> Event? {
        guard let start = text.range(of: "<cross-session-message"),
              let close = text.range(of: ">", range: start.upperBound..<text.endIndex) else { return nil }
        let attributes = String(text[start.upperBound..<close.lowerBound])
        func attribute(_ name: String) -> String? {
            guard let r = attributes.range(of: "\\b\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
            return String(attributes[r].dropFirst(name.count + 2).dropLast())
        }
        var body = text[close.upperBound...]
        if let end = body.range(of: "</cross-session-message>", options: .backwards) { body = body[..<end.lowerBound] }
        let from = attribute("from-name").flatMap { $0.isEmpty ? nil : $0 } ?? attribute("from") ?? "A session"
        return .peer(from: from, text: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One line of stdin: your message.
    static func userLine(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    /// One line of stdin: stop the current turn.
    /// One line of stdin: the answer to a permission request. Allowed with exactly the input asked about, or denied.
    static func permissionLine(id: String, allow input: [String: String]?, deny reason: String = "") -> Data {
        let decision: [String: Any] = input.map { ["behavior": "allow", "updatedInput": $0] }
            ?? ["behavior": "deny", "message": reason]
        return line(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": decision]])
    }

    static func interruptLine(id: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Splits off the whole lines of `buffer`, leaving a partial one.
    static func lines(_ buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }
}

/// What a message of yours comes with besides its text: the card you're replying to (its session is the target) and the
/// projects you tagged (routing is narrowed to them, and a new session starts there).
struct RouterContext: Equatable {
    /// A card id.
    var replyTo: String?
    /// Folder paths.
    var projects: [String]

    init(replyTo: String? = nil, projects: [String] = []) {
        self.replyTo = replyTo
        self.projects = projects
    }
}

/// The Router's Claude Code process: a headless session Lookout runs, that talks to the other sessions for you.
@Observable @MainActor final class RouterAgent {
    enum Phase: Equatable { case idle, starting, working, failed(String) }

    private(set) var phase: Phase = .idle
    /// Claude Code's bundled binary, if found, and its version ("2.1.293").
    private(set) var claudeCode: (path: String, version: String)?
    /// Your messages waiting for the current turn to end (they're in the chat already).
    private(set) var queuedCount = 0
    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored let tools: RouterTools
    /// Where the Claude app keeps its copies of Claude Code; nil in a test unless it gives one.
    @ObservationIgnored var codeRoot: URL? = UnderTest.isRunning ? nil : Claude.root.appendingPathComponent("claude-code", isDirectory: true)
    /// How long an ended process has to leave after SIGTERM before it is killed.
    @ObservationIgnored var killAfter: TimeInterval = 3
    /// How long quitting waits for the processes to be gone (SIGKILL two thirds of the way in).
    @ObservationIgnored var quitWait: TimeInterval = 1.5
    /// Each process started, and each one gone (tests follow them).
    @ObservationIgnored var onSpawn: ((Int32) -> Void)?
    @ObservationIgnored var onExit: ((Int32) -> Void)?
    /// A superseded start's config files were removed (tests wait on it).
    @ObservationIgnored var onConfigDiscarded: ((Int) -> Void)?
    /// Each look-up of a name in the registry, once applied (tests wait on it instead of on time).
    @ObservationIgnored var onPeerResolved: ((String, String?) -> Void)?
    /// Called off the main thread before a start writes its config, with the start's generation (tests hold it there).
    @ObservationIgnored var beforeConfigWrite: (@Sendable (Int) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdin: FileHandle?
    @ObservationIgnored private var server: RouterMCPServer?
    /// Between `launch` and the process running (or failing).
    @ObservationIgnored private var launching = false
    /// Processes ended but not gone yet: owned until they exit, and no new one starts meanwhile.
    @ObservationIgnored private var retiring: [Int32: Process] = [:]
    @ObservationIgnored private let writer = DispatchQueue(label: "lookout.router.stdin")
    /// Each start's number: what an older process still says is ignored.
    @ObservationIgnored private var generation = 0
    /// Your messages not written yet, oldest first: one turn at a time, since Claude Code may fold a message sent mid-turn
    /// into that turn (one `result` for two messages).
    @ObservationIgnored private var pending: [Outgoing] = [] {
        didSet { if queuedCount != pending.count { queuedCount = pending.count } }
    }
    /// The message whose turn is under way (written, its `result` not in yet).
    @ObservationIgnored private var inFlight: Outgoing?
    /// A message of yours on its way: its line is ready once its header is (a reply names the session's peer, read off the
    /// main thread).
    private struct Outgoing {
        var id = UUID()
        /// Your words, without the header: what `prepare` hands to Haiku while this turn runs.
        var text: String
        var line: Data?
    }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var resuming = false
    @ObservationIgnored private var resumeFailed = false
    @ObservationIgnored private var interrupting = false
    /// The turn under way was started by a session's message, not yours: what the Router says in it isn't shown.
    @ObservationIgnored private var peerTurn = false
    @ObservationIgnored private var toolCalls: [String: (name: String, input: [String: String])] = [:]
    @ObservationIgnored private var stderrTail: [String] = []
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    init(store: Store) {
        self.store = store
        tools = RouterTools(store: store)
        tools.claudePath = { [weak self] in self?.claudeCode?.path }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        observeSwitch()
        refreshClaudeCode()
    }

    // MARK: Finding Claude Code

    /// The highest version under `root` (`<version>/<hash>/claude.app/Contents/MacOS/claude`) that has the binary.
    nonisolated static func find(in root: URL) -> (path: String, version: String)? {
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.first?.isNumber == true }
            .sorted { compare($0, $1) == .orderedDescending }
        for version in versions {
            let dir = root.appendingPathComponent(version, isDirectory: true)
            for hash in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !hash.hasPrefix(".") {
                let path = dir.appendingPathComponent(hash).appendingPathComponent("claude.app/Contents/MacOS/claude").path
                if fm.isExecutableFile(atPath: path) { return (path, version) }
            }
        }
        return nil
    }

    /// Numeric, part by part ("2.1.293" > "2.1.29" > "2.1.3").
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Looks again off the main thread (the app updates its copy now and then).
    func refreshClaudeCode() {
        guard let root = codeRoot else { return }
        Task { [weak self] in
            let found = await OffMain.run { Self.find(in: root) }
            self?.setClaudeCode(found)
        }
    }

    private func setClaudeCode(_ found: (path: String, version: String)?) {
        if found?.path != claudeCode?.path || found?.version != claudeCode?.version { claudeCode = found }
    }

    private func setPhase(_ next: Phase) {
        if phase != next { phase = next }
    }

    // MARK: Chat

    @discardableResult
    private func append(_ role: RouterMessage.Role, _ text: String, session: String? = nil, replyTo: String? = nil,
                        projects: [String]? = nil, original: String? = nil) -> UUID? {
        guard let store else { return nil }
        var state = store.router
        let message = RouterMessage(role: role, text: text, date: Date(), sessionID: session, replyTo: replyTo,
                                    projects: projects, original: original)
        state.chat.append(message)
        RouterFeed.prune(&state)
        store.router = state
        return message.id
    }

    private func patch(_ id: UUID, _ change: (inout RouterMessage) -> Void) {
        guard let store, let i = store.router.chat.firstIndex(where: { $0.id == id }) else { return }
        var message = store.router.chat[i]
        change(&message)
        if message != store.router.chat[i] { store.router.chat[i] = message }
    }

    // MARK: Actions

    /// Adds your message to the chat and hands it to the process (started if it isn't running). Nothing while the Router
    /// or the sessions extension is off.
    /// `context`: the card you're replying to and the projects you tagged; the Router reads them in a header before your text.
    func send(_ text: String, context: RouterContext = RouterContext()) {
        guard let store, store.router.enabled, store.agents.enabled else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var seen = Set<String>()
        let projects = context.projects.filter { seen.insert($0).inserted }
        append(.you, text, replyTo: context.replyTo, projects: projects.isEmpty ? nil : projects)
        let item = Outgoing(text: text)
        pending.append(item)
        let tagged = projects.map { (name: store.folderName($0), path: $0) }
        guard let id = context.replyTo else {
            return ready(item.id, Self.header(text, reply: nil, projects: tagged))
        }
        let card = store.router.cards.first { $0.id == id }
        let session = card.flatMap { store.claudeSessions[$0.sessionID] }
        let reply = Reply(card: id, title: card?.title ?? session?.title, project: card.map { store.folderName($0.folder ?? "") },
                          peer: nil)
        guard let card, let dir = store.routerFiles?.claudeDir.appendingPathComponent("sessions", isDirectory: true) else {
            return ready(item.id, Self.header(text, reply: reply, projects: tagged))
        }
        let host = card.sessionID
        Task { [weak self] in
            let peer = await OffMain.run { ClaudePeers.read(dir: dir)[host].flatMap { $0.name.isEmpty ? nil : $0.name } }
            var named = reply
            named.peer = peer
            self?.ready(item.id, Self.header(text, reply: named, projects: tagged))
        }
    }

    /// Keeps `send(_:)` callable as a plain function value.
    func send(_ text: String) { send(text, context: RouterContext()) }

    /// The line of a waiting message is ready: it goes when its turn comes.
    private func ready(_ id: UUID, _ text: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].line = RouterStream.userLine(text)
        pump()
    }

    /// The card a message replies to, as the header names it.
    struct Reply: Equatable {
        var card: String
        var title: String?
        var project: String?
        var peer: String?
    }

    /// The structured lines the role explains, then your text: `[reply to: card … · session "…" (…) · peer "…"]` and
    /// `[projects: name = path, …]`.
    nonisolated static func header(_ text: String, reply: Reply?, projects: [(name: String, path: String)]) -> String {
        var lines: [String] = []
        if let reply {
            var parts = ["card \(reply.card)"]
            if let title = reply.title { parts.append("session \"\(title)\"" + (reply.project.map { " (\($0))" } ?? "")) }
            parts.append(reply.peer.map { "peer \"\($0)\"" } ?? "not reachable")
            lines.append("[reply to: " + parts.joined(separator: " · ") + "]")
        }
        if !projects.isEmpty {
            lines.append("[projects: " + projects.map { "\($0.name) = \($0.path)" }.joined(separator: ", ") + "]")
        }
        return lines.isEmpty ? text : (lines + [text]).joined(separator: "\n")
    }

    /// Writes the next message when no turn is under way (yours or a session's); starts the process if there is none.
    private func pump() {
        // Switched off, and `switched` hasn't run yet: nothing more goes out.
        guard let store, store.router.enabled, store.agents.enabled else { return }
        guard let stdin else { return startIfReady() }
        guard inFlight == nil, !peerTurn, let next = pending.first, let line = next.line else { return }
        pending.removeFirst()
        inFlight = next
        tools.beginTurn(next.text)
        write(line, to: stdin)
        setPhase(.working)
    }

    /// Drops what's waiting, saying how much in the chat.
    private func dropPending(_ why: String) {
        let n = pending.count
        pending = []
        if n > 0 { append(.receipt, "\(why) \(n) queued message\(n == 1 ? "" : "s")") }
    }

    /// Interrupts the current turn and drops what waits behind it; before anything was sent, cancels the start instead.
    func stop() {
        if let stdin, phase == .working {
            // The turn's tool work is void from here: a start waiting on Haiku won't make a session.
            tools.endTurn()
            interrupting = true
            write(RouterStream.interruptLine(), to: stdin)
            dropPending("Cancelled")
        } else if phase == .starting {
            end()
            pending = []
            append(.receipt, "Cancelled before sending")
            setPhase(.idle)
        }
    }

    /// Ends the process and starts the chat over.
    func newConversation() {
        end()
        let dropped = pending.count
        pending = []
        setPhase(.idle)
        guard let store else { return }
        var state = store.router
        state.chat = []
        state.claudeSessionID = nil
        if state != store.router { store.router = state }
        if dropped > 0 { append(.receipt, "Dropped \(dropped) queued message\(dropped == 1 ? "" : "s")") }
    }

    /// On quit: ends the process and waits a moment (bounded) for it to be gone, so none is left behind.
    func shutdown() {
        // Haiku or a bootstrap under way is stopped too, and waited for with the rest.
        let runs = tools.cancelRuns()
        end()
        pending = []
        let start = Date()
        func running() -> Bool {
            retiring.values.contains(where: \.isRunning) || runs.contains(where: \.isActive)
        }
        func waitGone(until limit: TimeInterval) {
            while running(), Date().timeIntervalSince(start) < limit { usleep(10_000) }
        }
        waitGone(until: quitWait * 2 / 3)
        for p in retiring.values where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        for run in runs where run.isRunning { kill(run.pid, SIGKILL) }
        waitGone(until: quitWait)
        retiring = retiring.filter { $0.value.isRunning }
    }

    /// Stops the process and its server and cancels their tool calls. A new generation: what they still say is ignored.
    private func end() {
        generation += 1
        tools.reset()
        launching = false
        if let process { retire(process) }
        process = nil
        stdin = nil
        server?.stop()
        server = nil
        toolCalls = [:]
        interrupting = false
        peerTurn = false
        started = false
        inFlight = nil
    }

    /// SIGTERM now, SIGKILL if it's still there after `killAfter`; kept in `retiring` until it exits.
    private func retire(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        retiring[pid] = p
        try? stdin?.close()
        p.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killAfter) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func write(_ line: Data, to handle: FileHandle) {
        writer.async { try? handle.write(contentsOf: line) }
    }

    /// The Router is switched off (or the sessions extension): nothing of it keeps running.
    private func observeSwitch() {
        guard let store else { return }
        withObservationTracking {
            _ = store.router.enabled
            _ = store.agents.enabled
        } onChange: { [weak self] in
            // Called before the change lands: look once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.switched()
                self?.observeSwitch()
            } }
        }
    }

    private func switched() {
        guard let store, !(store.router.enabled && store.agents.enabled) else { return }
        guard process != nil || launching || server != nil || !pending.isEmpty else { return }
        end()
        dropPending("Dropped")
        setPhase(.idle)
    }

    // MARK: Starting

    private func fail(_ reason: String) {
        launching = false
        server?.stop()
        server = nil
        pending = []
        append(.error, reason)
        setPhase(.failed(reason))
    }

    /// Starts a process for what's queued, unless one runs, is starting, or an old one is still on its way out.
    private func startIfReady() {
        guard !pending.isEmpty, let store, store.router.enabled, store.agents.enabled else { return }
        guard process == nil, !launching, retiring.isEmpty else {
            if process == nil { setPhase(.starting) }
            return
        }
        launch()
    }

    private func launch() {
        guard let store else { return }
        guard let paths = store.routerFiles else { return fail("The Router can't run here (no folder for its files).") }
        launching = true
        setPhase(.starting)
        generation += 1
        let gen = generation
        let root = codeRoot
        // Finding the binary and writing the config touch the disk: off the main thread.
        Task { [weak self] in
            let found = await OffMain.run { root.flatMap(Self.find) }
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.setClaudeCode(found)
                guard let code = found else {
                    return self.fail("Claude Code wasn't found: the Router uses the copy the Claude app installs. Open the Claude app once, then try again.")
                }
                self.serve(code.path, paths: paths, gen: gen)
            }
        }
    }

    private func serve(_ path: String, paths: RouterPaths, gen: Int) {
        let tools = tools
        let epoch = tools.epoch
        let server = RouterMCPServer { body in
            // One ticket for the whole request: a batch's later entries can't act after a Stop its first one waited out.
            let ticket = tools.ticket(epoch: epoch)
            return await RouterRPC.handle(body, tools: RouterTools.specs, version: Self.version) { name, args in
                await tools.call(name, args, ticket: ticket)
            }
        }
        self.server = server
        server.start { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(let port):
                // A file per start: a cancelled start finishing its write late can't change what a newer one loads.
                let config = Self.configURL(paths.routerHome, gen: gen)
                let settings = Self.settingsURL(paths.routerHome, gen: gen)
                let data = server.config(port: port)
                let gate = Self.gateSettings()
                let beforeWrite = beforeConfigWrite
                Task { [weak self] in
                    let error: String? = await OffMain.run {
                        beforeWrite?(gen)
                        do {
                            try FileManager.default.createDirectory(at: paths.routerHome, withIntermediateDirectories: true,
                                                                    attributes: [.posixPermissions: 0o700])
                            Self.removeConfigs(in: paths.routerHome, olderThan: gen)
                            try PrivateFile.write(data, to: config)
                            try PrivateFile.write(gate, to: settings)
                            return nil
                        } catch {
                            return error.localizedDescription
                        }
                    }
                    await MainActor.run { [weak self] in
                        guard let self, gen == self.generation else {
                            // Superseded meanwhile: its file goes (the token in it is of a stopped server).
                            try? FileManager.default.removeItem(at: config)
                            try? FileManager.default.removeItem(at: settings)
                            self?.onConfigDiscarded?(gen)
                            return
                        }
                        if let error { return self.fail("The Router couldn't start: \(error)") }
                        do {
                            try self.spawn(path, home: paths.routerHome, config: config, settings: settings, gen: gen)
                        } catch {
                            self.fail("The Router couldn't start: \(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                self.fail("The Router's tools couldn't start: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func configURL(_ home: URL, gen: Int) -> URL { home.appendingPathComponent("mcp-\(gen).json") }
    nonisolated static func settingsURL(_ home: URL, gen: Int) -> URL { home.appendingPathComponent("settings-\(gen).json") }

    /// The config files of earlier starts (lower generations: a late start never removes a newer one's).
    nonisolated static func removeConfigs(in home: URL, olderThan gen: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let stem = name.dropLast(5)
            guard let dash = stem.lastIndex(of: "-") else {
                if name == "mcp.json" { try? FileManager.default.removeItem(at: home.appendingPathComponent(name)) }
                continue
            }
            let kind = stem[..<dash], number = Int(stem[stem.index(after: dash)...])
            if ["mcp", "settings"].contains(String(kind)), let number, number < gen {
                try? FileManager.default.removeItem(at: home.appendingPathComponent(name))
            }
        }
    }

    /// The gate: every SendMessage asks first (Claude Code's own permission prompt, which the agent answers over stdin).
    /// Its native path fails closed: no answer, a closed stream or a malformed one is a refusal.
    nonisolated static func gateSettings() -> Data {
        Data(#"{"permissions":{"ask":["SendMessage"]}}"#.utf8)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1" }

    nonisolated static func arguments(config: String, settings: String, resume: String?) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "manual", "--permission-prompt-tool", "stdio",
                    "--tools", "ListAgents,SendMessage", "--allowedTools", "ListAgents,mcp__lookout",
                    "--name", "Lookout", "--setting-sources", "", "--settings", settings,
                    "--strict-mcp-config", "--mcp-config", config,
                    "--append-system-prompt", RouterPrompt.role]
        if let resume { args += ["--resume", resume] }
        return args
    }

    private func spawn(_ path: String, home: URL, config: URL, settings: URL, gen: Int) throws {
        guard let store else { return }
        // A write to a process that just died must fail, not kill Lookout.
        signal(SIGPIPE, SIG_IGN)
        let resume = store.router.claudeSessionID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Self.arguments(config: config.path, settings: settings.path, resume: resume)
        process.currentDirectoryURL = home
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let events = buffer.take(data).flatMap(RouterStream.parse)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(events, gen: gen) } }
        }
        let errorBuffer = LineBuffer()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let lines = errorBuffer.take(data).compactMap { String(data: $0, encoding: .utf8) }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.stderr(lines, gen: gen) } }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus, pid = p.processIdentifier
            // What's left on the pipes is read before the exit is handled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { self?.exited(pid, status, gen: gen) } }
        }

        try process.run()
        launching = false
        self.process = process
        onSpawn?(process.processIdentifier)
        stdin = input.fileHandleForWriting
        started = false
        resuming = resume != nil
        resumeFailed = false
        stderrTail = []
        inFlight = nil
        peerTurn = false
        pump()
        if inFlight == nil { setPhase(.idle) }
    }

    // MARK: What it says

    private func stderr(_ lines: [String], gen: Int) {
        guard gen == generation else { return }
        stderrTail = Array((stderrTail + lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).suffix(20))
    }

    /// Applies what the process said, in order.
    func apply(_ events: [RouterStream.Event], gen: Int? = nil) {
        guard gen == nil || gen == generation, let store else { return }
        for event in events {
            switch event {
            case .permission(let id, let tool, let input, let others):
                answer(id, tool, input, others)
            case .started(let id):
                started = true
                if store.router.claudeSessionID != id { store.router.claudeSessionID = id }
                setPhase(.working)
            case .text(let text):
                setPhase(.working)
                // A session's report is shown as it came (the peer line); the Router doesn't speak over it.
                if !peerTurn {
                    let shown = Self.withoutRelayHeader(text)
                    if !shown.isEmpty { append(.router, shown) }
                }
            case .toolUse(let id, let name, let input):
                toolCalls[id] = (name, input)
                setPhase(.working)
            case .toolResult(let id, let isError, let text):
                guard let call = toolCalls.removeValue(forKey: id) else { continue }
                // SendMessage says a failed delivery in its result (`success: false`), not as an error.
                let refused = call.name == "SendMessage" ? Self.undelivered(text) : nil
                if isError || refused != nil {
                    let reason = refused ?? text
                    let first = reason.split(separator: "\n").first.map(String.init) ?? "failed"
                    if refused != nil { _ = approval(call) }
                    append(.error, "\(Self.shortName(call.name)): \(first)")
                } else if let receipt = receipt(call.name, call.input, prepared: approval(call)) {
                    let line = append(.receipt, receipt.text, session: receipt.session, original: receipt.original)
                    if call.name == "SendMessage", let line, let to = call.input["to"] {
                        // The session it went to, by Claude Code's own registry; cards only when that's certain.
                        // Only the cards open now: one reopened or made while the registry is read is news after it.
                        // Each with its revision: one marked and reopened meanwhile has moved, and is left alone.
                        let eligible = Dictionary(store.router.cards.filter(\.isOpen)
                            .map { ($0.id, store.cardRevisions[$0.id, default: 0]) }, uniquingKeysWith: { a, _ in a })
                        let gen = generation
                        resolvePeer(to) { [weak self] session in
                            guard let self, let session, self.current(gen), let store = self.store else { return }
                            self.patch(line) { $0.sessionID = session }
                            var state = store.router
                            RouterFeed.address(&state, session, .router, Date()) {
                                eligible[$0.id] == store.cardRevisions[$0.id, default: 0]
                            }
                            if state != store.router { store.router = state }
                        }
                    }
                }
            case .peer(let from, let text):
                // Not while one of your turns runs: the message is then read in the middle of it, and the rest is yours.
                if inFlight == nil { peerTurn = true }
                setPhase(.working)
                let line = append(.peer, text.isEmpty ? from : "\(from): \(text)")
                let gen = generation
                resolvePeer(from) { [weak self] session in
                    guard let self, let session, let line, self.current(gen) else { return }
                    self.patch(line) {
                        $0.sessionID = session
                        if !text.isEmpty { $0.text = text }
                    }
                }
            case .result(let isError, let text):
                if resuming, !started, isError {
                    // `--resume` of a conversation that's gone: the process exits, and starts over fresh (see `exited`).
                    resumeFailed = true
                    continue
                }
                toolCalls = [:]
                if interrupting {
                    interrupting = false
                    append(.receipt, "Stopped")
                } else if isError {
                    append(.error, text.isEmpty ? "The turn failed" : text)
                }
                // The turn is over, whoever started it: its unused preparations go, and the next message can go.
                tools.endTurn()
                if peerTurn { peerTurn = false } else { inFlight = nil }
                pump()
                setPhase(inFlight != nil || peerTurn ? .working : .idle)
            }
        }
    }

    private func exited(_ pid: Int32, _ status: Int32, gen: Int) {
        onExit?(pid)
        if retiring.removeValue(forKey: pid) != nil {
            // An ended process is gone at last: what waited for it can start.
            startIfReady()
            return
        }
        guard gen == generation, let store, process?.processIdentifier == pid else { return }
        process = nil
        stdin = nil
        server?.stop()
        server = nil
        toolCalls = [:]
        tools.reset()
        if resumeFailed || (resuming && !started && status != 0
                            && stderrTail.contains { $0.contains("No conversation found") }) {
            if store.router.claudeSessionID != nil { store.router.claudeSessionID = nil }
            let unanswered = inFlight
            inFlight = nil
            if interrupting {
                // Stopped before it answered: nothing is sent again.
                interrupting = false
                append(.receipt, "Stopped")
                setPhase(.idle)
                return
            }
            // The conversation to resume is gone: a new one, with what was already sent.
            append(.error, "Couldn't resume the previous conversation; started a new one.")
            if let unanswered { pending.insert(unanswered, at: 0) }
            startIfReady()
            return
        }
        interrupting = false
        peerTurn = false
        inFlight = nil
        let detail = stderrTail.last.map { ": \($0)" } ?? ""
        let reason = status == 0 ? "The Router's process ended" : "The Router's process stopped (exit \(status))\(detail)"
        append(.error, reason)
        // What was waiting behind the lost turn goes to a new process.
        if pending.isEmpty { setPhase(.failed(reason)) } else { startIfReady() }
    }

    /// Every permission request is answered at once (none waits): only a SendMessage of this turn's prepared text, with
    /// exactly the input asked about; anything else is refused with a reason the Router reads.
    private func answer(_ id: String, _ tool: String, _ input: [String: String], _ others: [String]) {
        guard let stdin else { return }
        let refusal: String? = tool == "SendMessage"
            ? tools.approveSend(input, otherFields: others)
            : "\(tool) isn't something the Router may do"
        write(RouterStream.permissionLine(id: id, allow: refusal == nil ? input : nil, deny: refusal ?? ""), to: stdin)
    }

    /// Why SendMessage didn't deliver, from its result (`{"success":false,"message":…}`); nil when it did.
    nonisolated static func undelivered(_ result: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
              obj["success"] as? Bool == false else { return nil }
        return obj["message"] as? String ?? "Not delivered"
    }

    /// What the gate let through for a SendMessage that ran. None means it ran without the gate (its hook failed, say):
    /// said in the chat, since the text wasn't checked.
    private func approval(_ call: (name: String, input: [String: String])) -> Prepared? {
        guard call.name == "SendMessage" else { return nil }
        let to = call.input["to"] ?? "", message = call.input["message"] ?? ""
        if let ready = tools.takeApproved(to, message) { return ready }
        append(.error, "The message to \(to) went without Lookout's check")
        return nil
    }

    // MARK: Peers

    /// The desktop session (`hostSessionId`) a `SendMessage` `to` or a sender's name stands for, by Claude Code's registry of
    /// live processes: the exact peer name, or "name [ref]" with the ref telling apart peers of the same name. Nil when it
    /// matches none, or more than one.
    nonisolated static func peerSession(_ to: String, peers: [String: ClaudePeers.Peer]) -> String? {
        let exact = peers.filter { $0.value.name == to }
        if exact.count == 1 { return exact.first?.key }
        guard let match = to.range(of: #"^(.*) \[([^\]]+)\]$"#, options: .regularExpression) else { return nil }
        let text = String(to[match])
        guard let open = text.range(of: " [", options: .backwards) else { return nil }
        let name = String(text[..<open.lowerBound])
        let ref = String(text[open.upperBound...].dropLast())
        let named = peers.filter { $0.value.name == name }
        if named.count == 1 { return named.first?.key }
        let narrowed = named.filter { String($0.value.pid) == ref || $0.key == ref || $0.key.hasPrefix(ref) || $0.key.hasSuffix(ref) }
        return narrowed.count == 1 ? narrowed.first?.key : nil
    }

    /// Still the same Router: no reset since `gen`, and it and the sessions extension still on.
    private func current(_ gen: Int) -> Bool {
        guard let store else { return false }
        return gen == generation && store.router.enabled && store.agents.enabled
    }

    /// Reads the registry off the main thread, answers on it.
    private func resolvePeer(_ name: String, _ then: @escaping @MainActor (String?) -> Void) {
        guard let dir = store?.routerFiles?.claudeDir.appendingPathComponent("sessions", isDirectory: true) else {
            then(nil)
            onPeerResolved?(name, nil)
            return
        }
        Task { [weak self] in
            let session = await OffMain.run { Self.peerSession(name, peers: ClaudePeers.read(dir: dir)) }
            then(session)
            self?.onPeerResolved?(name, session)
        }
    }

    // MARK: Receipts

    /// Text without the lines that sign a message for Lookout's plugin (`⟦lookout v1 …⟧`): the chat never shows them.
    nonisolated static func withoutRelayHeader(_ text: String) -> String { RelaySigner.readable(text) }

    /// `mcp__lookout__board` → `board`.
    static func shortName(_ name: String) -> String {
        name.hasPrefix("mcp__lookout__") ? String(name.dropFirst("mcp__lookout__".count)) : name
    }

    /// The line an action leaves in the chat, and the session it was about (for a message, found later: see `apply`).
    /// Nil for tools that only read.
    func receipt(_ name: String, _ input: [String: String],
                 prepared: Prepared? = nil) -> (text: String, session: String?, original: String?)? {
        let cards = store?.router.cards ?? []
        func cardTitle(_ id: String?) -> (String, String?) {
            let card = cards.first { $0.id == id }
            return (card?.title ?? id ?? "a card", card?.sessionID)
        }
        switch Self.shortName(name) {
        case "SendMessage":
            let to = input["to"] ?? "a session"
            // Your words as the session got them: the body, never the line that signs it.
            let message = prepared?.body ?? Self.withoutRelayHeader(input["message"] ?? input["content"] ?? input["text"] ?? "")
            var first = message.split(separator: "\n").first.map(String.init) ?? ""
            if first.count > 120 { first = String(first.prefix(119)) + "…" }
            let original = prepared?.rephrased == true ? prepared?.original : nil
            // A new session's first message is the receipt of its start.
            if let project = prepared?.newSessionIn { return ("→ new session in \(project): \(first)", nil, original) }
            return ("→ \(to): \(first)", nil, original)
        case "answer_form":
            let (title, session) = cardTitle(input["card"])
            return ("→ answered \(title)", session, nil)
        case "open_session":
            let query = input["session"] ?? ""
            let found = store?.claudeSessions[query]
                ?? store?.claudeSessions.values.first { !$0.isArchived && $0.title.lowercased() == query.lowercased() }
            return ("→ opened \(found?.title ?? query)", found?.id, nil)
        case "mark":
            let (title, session) = cardTitle(input["card"])
            return (input["addressed"] == "false" ? "→ reopened \(title)" : "→ marked \(title) addressed", session, nil)
        case "board", "route", "prepare", "start_session", "ListAgents":
            // Reads, or (a start) said by the first message's receipt.
            return nil
        default:
            return ("→ \(Self.shortName(name))", nil, nil)
        }
    }
}

extension Store {
    /// Counts each card's changes (made, addressed, reopened, retitled…), so a late action can tell a card that changed and
    /// changed back from one that never moved.
    func countCardChanges(from old: [RouterCard]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for card in router.cards where before[card.id] != card { cardRevisions[card.id, default: 0] &+= 1 }
    }
}

/// Bytes from a pipe, cut into whole lines; touched only by the pipe's handler.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        return RouterStream.lines(&data)
    }
}
