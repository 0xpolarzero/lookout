import Foundation
import Network

// MARK: - HTTP

/// Just enough HTTP/1.1 for one local client: a request line, headers and a `Content-Length` body in; a status, headers
/// and a `Content-Length` body out. No chunked bodies (Claude Code's MCP client never sends them). The head is read on its
/// own, so a request is judged (token, path, size) before any of its body is read.
enum MiniHTTP {
    struct Head: Equatable {
        var method: String
        var path: String
        /// Names lowercased.
        var headers: [String: String]
        var contentLength: Int

        /// HTTP/1.1 keeps the connection unless the client says otherwise.
        var keepAlive: Bool { headers["connection"]?.lowercased() != "close" }
    }

    enum Parsed: Equatable {
        /// Wait for more bytes.
        case incomplete
        /// Answer with this status and close.
        case invalid(Int)
        /// The whole head, and how many bytes of the buffer it took (the body follows).
        case head(Head, consumed: Int)
    }

    static let maxHeader = 16 * 1024
    static let maxBody = 1024 * 1024

    static func parseHead(_ buffer: Data) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        let window = buffer.prefix(maxHeader + separator.count)
        guard let end = window.range(of: separator) else {
            return buffer.count > maxHeader ? .invalid(431) : .incomplete
        }
        guard buffer.distance(from: buffer.startIndex, to: end.lowerBound) <= maxHeader else { return .invalid(431) }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"].map({ $0.lowercased() != "identity" }) == true { return .invalid(411) }
        var length = 0
        if let value = headers["content-length"] {
            guard let n = Int(value), n >= 0 else { return .invalid(400) }
            length = n
        }
        let head = Head(method: String(parts[0]), path: String(parts[1]), headers: headers, contentLength: length)
        return .head(head, consumed: buffer.distance(from: buffer.startIndex, to: end.upperBound))
    }

    static func response(_ status: Int, body: Data? = nil, keepAlive: Bool, headers extra: [String: String] = [:]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason(status))"]
        if let body, !body.isEmpty { lines.append("Content-Type: application/json") }
        lines.append("Content-Length: \(body?.count ?? 0)")
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { data.append(body) }
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

// MARK: - JSON-RPC

/// MCP's JSON-RPC, for tools only. Pure but for `call`, so the protocol is tested without a socket.
enum RouterRPC {
    struct Reply: Equatable {
        var status: Int
        var body: Data?
    }

    /// What a tool says back: text for the model, flagged when the tool refused or failed.
    struct ToolResult: Equatable {
        var text: String
        var isError = false

        static func error(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
    }

    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let invalidRequest = -32600
    static let parseError = -32700

    static let maxBatch = 16
    static let maxResponse = 1024 * 1024
    static let internalError = -32603

    /// One POST body, single or batch (at most `maxBatch` messages). `call` runs a tool by name, or returns nil for a name
    /// it doesn't know. The replies together stay under `maxResponse` bytes, but for the short error that stands in for each
    /// reply that wouldn't fit.
    static func handle(_ body: Data, tools: [[String: Any]], version: String = "1", maxResponse: Int = maxResponse,
                       call: (String, [String: Any]) async -> ToolResult?) async -> Reply {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return Reply(status: 400, body: encode(error(nil, parseError, "Parse error")))
        }
        var budget = maxResponse
        func fit(_ reply: [String: Any], id: Any?) -> [String: Any] {
            let size = encode(reply).count
            if size <= budget {
                budget -= size
                return reply
            }
            let small = error(id, internalError, "Response too large")
            budget -= encode(small).count
            return small
        }
        if let batch = json as? [Any] {
            guard !batch.isEmpty else { return Reply(status: 400, body: encode(error(nil, invalidRequest, "Empty batch"))) }
            guard batch.count <= maxBatch else {
                return Reply(status: 400, body: encode(error(nil, invalidRequest, "At most \(maxBatch) messages in a batch")))
            }
            var out: [[String: Any]] = []
            for item in batch {
                if let reply = await one(item, tools: tools, version: version, call: call) {
                    out.append(fit(reply, id: (item as? [String: Any])?["id"]))
                }
            }
            return out.isEmpty ? Reply(status: 202, body: nil) : Reply(status: 200, body: encode(out))
        }
        guard let reply = await one(json, tools: tools, version: version, call: call) else { return Reply(status: 202, body: nil) }
        return Reply(status: 200, body: encode(fit(reply, id: (json as? [String: Any])?["id"])))
    }

    /// The reply to one message; nil for a notification or a client's response, which get none.
    private static func one(_ item: Any, tools: [[String: Any]], version: String,
                            call: (String, [String: Any]) async -> ToolResult?) async -> [String: Any]? {
        guard let message = item as? [String: Any] else { return error(nil, invalidRequest, "Invalid request") }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to something we never ask, or garbage: nothing to say to a response, an error to the rest.
            if message["result"] != nil || message["error"] != nil { return nil }
            return error(id, invalidRequest, "Invalid request")
        }
        guard let id, !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "lookout", "version": version],
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, invalidParams, "Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let out = await call(name, arguments) else { return error(id, invalidParams, "Unknown tool: \(name)") }
            return result(id, ["content": [["type": "text", "text": out.text]], "isError": out.isError])
        default:
            return error(id, methodNotFound, "Method not found")
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
    }
}

// MARK: - Server

/// The Router's tools, served to its own Claude Code process only: on 127.0.0.1, at a port the system picks, behind a
/// token made for each start and handed over in the 0600 config file. Bounded in every way a stuck or hostile client could
/// use: connections, header and body size, and time to send a request or sit idle.
final class RouterMCPServer: @unchecked Sendable {
    struct Limits {
        var maxConnections = 8
        /// From a request's first byte to its last.
        var requestTimeout: TimeInterval = 10
        /// Between requests on a kept-alive connection.
        var idleTimeout: TimeInterval = 60
    }

    let token: String
    let limits: Limits
    private let queue = DispatchQueue(label: "lookout.router.mcp")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    /// Requests being answered: cancelled when the server stops, so nothing they do lands after.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private let handle: @MainActor (Data) async -> RouterRPC.Reply

    init(limits: Limits = Limits(), handle: @escaping @MainActor (Data) async -> RouterRPC.Reply) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        self.limits = limits
        self.handle = handle
    }

    /// What a request's head gets: the token, the path, the method and the body's size are checked before the body is read.
    enum Route: Equatable {
        case reply(Int, allow: Bool)
        case accept
    }

    static func route(_ head: MiniHTTP.Head, token: String) -> Route {
        let expected = Data("Bearer \(token)".utf8)
        let given = Data((head.headers["authorization"] ?? "").utf8)
        guard given.count == expected.count, zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .reply(401, allow: false)
        }
        let path = head.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.path
        guard path == "/mcp" else { return .reply(404, allow: false) }
        guard head.method == "POST" else { return .reply(405, allow: true) }
        guard head.contentLength <= MiniHTTP.maxBody else { return .reply(413, allow: false) }
        return .accept
    }

    /// Listens; `ready` gets the port (or why it couldn't), on the main thread.
    func start(ready: @escaping @MainActor (Result<UInt16, Error>) -> Void) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            DispatchQueue.main.async { MainActor.assumeIsolated { ready(.failure(error)) } }
            return
        }
        var answered = false
        let finish: (Result<UInt16, Error>) -> Void = { result in
            guard !answered else { return }
            answered = true
            DispatchQueue.main.async { MainActor.assumeIsolated { ready(result) } }
        }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { finish(.success(port)) }
            case .failed(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(CocoaError(.userCancelled)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        queue.async {
            guard !self.stopped else { return listener.cancel() }
            self.listener = listener
            listener.start(queue: self.queue)
        }
    }

    /// Stops listening, drops every connection and cancels the requests being answered.
    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.close() }
            self.connections = [:]
            self.tasks.values.forEach { $0.cancel() }
            self.tasks = [:]
        }
    }

    /// For the tests: how many connections are held now.
    func connectionCount() -> Int { queue.sync { connections.count } }

    private func accept(_ nw: NWConnection) {
        let connection = Connection(nw: nw, queue: queue)
        guard !stopped, connections.count < limits.maxConnections else {
            nw.start(queue: queue)
            connection.send(MiniHTTP.response(503, keepAlive: false)) { connection.close() }
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                connection.disarm()
                self?.connections[key] = nil
            default:
                break
            }
        }
        nw.start(queue: queue)
        connection.arm(limits.idleTimeout, .idle)
        serve(connection)
    }

    /// Reads and answers one request at a time, in order: the head first (judged at once), then the body.
    private func serve(_ connection: Connection) {
        guard !connection.closed, !connection.busy else { return }
        if connection.head == nil {
            switch MiniHTTP.parseHead(connection.buffer) {
            case .incomplete:
                // The first byte of a request starts its own deadline, whatever was left of the idle one.
                if !connection.buffer.isEmpty, connection.mode != .request { connection.arm(limits.requestTimeout, .request) }
                return more(connection)
            case .invalid(let status):
                return reject(connection, status, allow: false)
            case .head(let head, let consumed):
                connection.buffer.removeFirst(consumed)
                if connection.mode != .request { connection.arm(limits.requestTimeout, .request) }
                switch Self.route(head, token: token) {
                case .reply(let status, let allow): return reject(connection, status, allow: allow)
                case .accept: connection.head = head
                }
            }
        }
        guard let head = connection.head else { return }
        guard connection.buffer.count >= head.contentLength else { return more(connection) }
        let body = Data(connection.buffer.prefix(head.contentLength))
        connection.buffer.removeFirst(head.contentLength)
        connection.head = nil
        connection.busy = true
        // The handler's own time isn't the client's: no deadline while it runs.
        connection.disarm()
        let keepAlive = head.keepAlive
        let id = UUID()
        let handle = handle
        tasks[id] = Task { @MainActor in
            let reply = await handle(body)
            let cancelled = Task.isCancelled
            self.queue.async {
                self.tasks[id] = nil
                guard !cancelled, !self.stopped, !connection.closed else { return connection.close() }
                connection.busy = false
                connection.send(MiniHTTP.response(reply.status, body: reply.body, keepAlive: keepAlive)) { [weak self] in
                    guard let self else { return }
                    guard keepAlive else { return connection.close() }
                    if connection.buffer.isEmpty {
                        connection.arm(self.limits.idleTimeout, .idle)
                    } else {
                        connection.arm(self.limits.requestTimeout, .request)
                    }
                    self.serve(connection)
                }
            }
        }
    }

    private func reject(_ connection: Connection, _ status: Int, allow: Bool) {
        connection.busy = true
        connection.send(MiniHTTP.response(status, keepAlive: false, headers: allow ? ["Allow": "POST"] : [:])) { connection.close() }
    }

    /// Asks for more bytes, once at a time; the client closing ends the connection.
    private func more(_ connection: Connection) {
        guard !connection.receiving, !connection.closed else { return }
        if connection.eof { return connection.close() }
        connection.receiving = true
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            connection.receiving = false
            if let data { connection.buffer.append(data) }
            if complete { connection.eof = true }
            if error != nil { return connection.close() }
            self?.serve(connection)
        }
    }

    /// Only touched on the server's queue.
    private final class Connection: @unchecked Sendable {
        let nw: NWConnection
        let queue: DispatchQueue
        var buffer = Data()
        var head: MiniHTTP.Head?
        var busy = false
        var receiving = false
        var eof = false
        var closed = false
        private var deadline: DispatchWorkItem?
        /// What the deadline is for: waiting between requests, or a request coming in.
        enum Mode { case none, idle, request }
        private(set) var mode = Mode.none

        init(nw: NWConnection, queue: DispatchQueue) {
            self.nw = nw
            self.queue = queue
        }

        /// Closes the connection unless something re-arms or disarms it within `seconds`.
        func arm(_ seconds: TimeInterval, _ mode: Mode) {
            self.mode = mode
            deadline?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.close() }
            deadline = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        func disarm() {
            deadline?.cancel()
            deadline = nil
            mode = .none
        }

        func send(_ data: Data, then: @escaping () -> Void) {
            nw.send(content: data, completion: .contentProcessed { _ in then() })
        }

        func close() {
            guard !closed else { return }
            closed = true
            disarm()
            nw.cancel()
        }
    }

    /// `--mcp-config`'s file: the server's address and its token.
    func config(port: UInt16) -> Data {
        let object: [String: Any] = ["mcpServers": ["lookout": [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

// MARK: - Tools

/// What the Router can do besides messaging: read the board, pick a target, answer a form, start or open a session, mark a
/// card. Each acts on the store, on the main thread.
@MainActor final class RouterTools {
    private weak var store: Store?
    /// Jev's pick for `route`; tests answer for it (else TypeSafe, with the user's key).
    var chooser: (([String], [String: String], [String: String], String) async throws -> JevClient.Choice)?
    var now: () -> Date = Date.init
    /// Bumped when the Router is reset (new conversation, quit, switched off): a call that began before acts on nothing.
    private(set) var epoch = 0
    /// Bumped when a turn ends (its result, or Stop): the turn's unfinished work acts on nothing.
    private(set) var turn = 0
    /// What a call belongs to: the process (`epoch`) and the turn, taken once per request (a batch shares it). Side
    /// effects need a turn of yours (`userTurn`): a session's message never makes the Router act.
    struct Ticket: Equatable {
        var epoch: Int
        var turn: Int
        var userTurn = true
    }

    /// The ticket of a request arriving now.
    func ticket(epoch: Int? = nil) -> Ticket {
        Ticket(epoch: epoch ?? self.epoch, turn: turn, userTurn: turnText != nil)
    }
    /// The text of your message the current turn is about (without Lookout's header lines); nil in a turn a session's
    /// message started. `prepare` and `start_session` take the words from here, never from the Router.
    private(set) var turnText: String?
    /// Haiku and bootstrap runs under way: ended with their turn.
    private var runs: [ObjectIdentifier: OneShot.Handle] = [:]
    /// Called after a target is looked up, before anything is changed (tests hold a call there).
    var afterLookup: (() async -> Void)?
    /// Sends the gate let through, in order, until their tool_use is seen (for receipts).
    private var approved: [(to: String, text: String, prepared: Prepared)] = []

    init(store: Store) {
        self.store = store
    }

    /// The messages `prepare` (and `start_session`) made, by the `to` they're for: the next SendMessage there must carry
    /// exactly that text.
    private(set) var prepared: [String: Prepared] = [:]
    /// Haiku's rephrasing (message, title, project); tests answer for it.
    var rephrase: ((String, String, String) async throws -> Prepared)?
    /// Making a session (folder, title) and waiting for its process; tests answer for it.
    var starter: ((String, String) async throws -> SessionStart.Started)?
    /// Claude Code's bundled binary, as the agent found it.
    var claudePath: () -> String? = { nil }

    /// The process ended: everything of it is void, and its runs are stopped.
    func reset() {
        epoch += 1
        endTurn()
    }

    /// A turn of yours begins (nil: a session's message started it).
    func beginTurn(_ text: String?) {
        turnText = text
    }

    /// The turn ended or was stopped: unused preparations go, runs under way are stopped, late work acts on nothing.
    func endTurn() {
        turn += 1
        turnText = nil
        prepared = [:]
        approved = []
        cancelRuns()
    }

    /// Stops every run under way. They stay listed until their program is confirmed gone (a run returns only then), so
    /// quitting right after still waits for them.
    @discardableResult
    func cancelRuns() -> [OneShot.Handle] {
        let all = Array(runs.values)
        all.forEach { $0.cancel() }
        return all
    }

    /// A run of a program for the current turn, stopped with it; listed from before its program starts.
    private func tracked<T>(_ body: (OneShot.Handle) async throws -> T) async throws -> T {
        let handle = OneShot.Handle()
        let key = ObjectIdentifier(handle)
        runs[key] = handle
        defer { runs[key] = nil }
        return try await body(handle)
    }

    /// The same text byte for byte (UTF-8), not just equal as Swift strings are (which treats canonically equivalent Unicode
    /// as the same): the wire text is signed, and only exactly it goes.
    nonisolated static func sameBytes(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }

    /// The send the gate let through for (to, message), once: its receipt says what was prepared.
    func takeApproved(_ to: String, _ message: String) -> Prepared? {
        guard let i = approved.firstIndex(where: { $0.to == to && Self.sameBytes($0.text, message) }) else { return nil }
        return approved.remove(at: i).prepared
    }

    /// Right before a side effect: the call must still belong to the Router and the turn as they are now.
    /// `acting` false: a read (board, route), which a session's turn may do too.
    private func live(_ ticket: Ticket, acting: Bool = true) throws {
        guard ticket.epoch == epoch, !Task.isCancelled else { throw Failure("The Router was reset; nothing was done") }
        guard ticket.turn == turn else { throw Failure("Stopped; nothing was done") }
        guard !acting || (ticket.userTurn && turnText != nil) else { throw Failure("Only the user's messages make the Router act") }
        guard let store, store.router.enabled, store.agents.enabled else { throw Failure("The Router is off; nothing was done") }
    }

    /// `live` as a yes/no, for a check made later (the form writer's, right before it writes).
    private func isLive(_ ticket: Ticket) -> Bool { (try? live(ticket)) != nil }

    static let names = ["board", "route", "prepare", "answer_form", "start_session", "open_session", "mark"]

    static let specs: [[String: Any]] = [
        [
            "name": "board",
            "description": "What needs the user now: open cards (with any pending form's questions and options), working sessions, other recent sessions and project names. Each session has `peer` (the exact `to` for SendMessage) and `reachable` (it has a live process). Call it before acting.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "route",
            "description": "Picks the target of a user message among open cards (answer:<card>), sessions (session:<id>) and projects (new:<folder>), or `unclear`. Returns the top candidates with probabilities and `decision`: act only on \"send\"; on \"ask\", ask the user.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "The user's message, verbatim."],
                    "projects": ["type": "array", "items": ["type": "string"],
                                 "description": "The projects the user tagged (from the [projects: …] header): only their sessions and cards are candidates."],
                ],
                "required": ["message"], "additionalProperties": false,
            ],
        ],
        [
            "name": "prepare",
            "description": "Required before every SendMessage: Lookout takes the user's current message itself and returns `to` and `text`, the part for this session as it must be sent (addressing like \"tell lookout to\" removed, otherwise unchanged). SendMessage exactly `text` to `to`, with no other fields: anything else is refused. On an error, tell the user and don't send.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session": ["type": "string", "description": "The target: its session id from board, or its peer name."],
                ],
                "required": ["session"], "additionalProperties": false,
            ],
        ],
        [
            "name": "answer_form",
            "description": "Answers a session's pending question form, as if the user clicked it. One answer per question: an option's label, labels joined with \", \" (or a list) for multi-select, or the user's own words.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "card": ["type": "string", "description": "The question card's id, from board."],
                    "answers": [
                        "type": "object",
                        "description": "Question text → answer.",
                        "additionalProperties": ["anyOf": [["type": "string"], ["type": "array", "items": ["type": "string"]]]],
                    ],
                ],
                "required": ["card", "answers"], "additionalProperties": false,
            ],
        ],
        [
            "name": "start_session",
            "description": "Starts a new session in a project, only when the user asks for one. Lookout takes the user's current message as its first message, prepared already; it waits until the session runs and returns its `peer` and `text`: SendMessage exactly `text` to `peer` next, with no prepare.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "project": ["type": "string", "description": "A project name from board or the [projects: …] header, or its folder path."],
                    "title": ["type": "string", "description": "A short title for the session, 3 to 6 words."],
                ],
                "required": ["project", "title"], "additionalProperties": false,
            ],
        ],
        [
            "name": "open_session",
            "description": "Opens a session in the Claude app, e.g. one that isn't reachable so it can get a live process.",
            "inputSchema": [
                "type": "object",
                "properties": ["session": ["type": "string", "description": "The session's id from board, or its exact title."]],
                "required": ["session"], "additionalProperties": false,
            ],
        ],
        [
            "name": "mark",
            "description": "Marks a card addressed (done with) or open again, when the user says so.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "card": ["type": "string", "description": "The card's id, from board."],
                    "addressed": ["type": "boolean", "description": "true: addressed; false: open again."],
                ],
                "required": ["card", "addressed"], "additionalProperties": false,
            ],
        ],
    ]

    /// Runs a tool; nil when there is no tool by that name. `epoch`: the Router's when the request came (now by default).
    /// `ticket`: the request's (a batch shares one); now's by default.
    func call(_ name: String, _ args: [String: Any], epoch: Int? = nil, ticket given: Ticket? = nil) async -> RouterRPC.ToolResult? {
        guard let store else { return .error("Lookout isn't ready") }
        let ticket = given ?? self.ticket(epoch: epoch)
        do {
            switch name {
            case "board":
                let text = await board(store)
                try live(ticket, acting: false)
                return RouterRPC.ToolResult(text: text)
            case "route":
                let text = try await route(store, message: Self.string(args, "message"), projects: try Self.strings(args, "projects"))
                try live(ticket, acting: false)
                return RouterRPC.ToolResult(text: text)
            case "answer_form": return RouterRPC.ToolResult(text: try await answerForm(store, args, ticket: ticket))
            case "prepare":
                return RouterRPC.ToolResult(text: try await prepare(store, session: Self.string(args, "session"), ticket: ticket))
            case "start_session":
                return RouterRPC.ToolResult(text: try await startSession(store, project: Self.string(args, "project"),
                                                                         title: Self.string(args, "title"), ticket: ticket))
            case "open_session": return RouterRPC.ToolResult(text: try openSession(store, Self.string(args, "session"), ticket: ticket))
            case "mark": return RouterRPC.ToolResult(text: try mark(store, args, ticket: ticket))
            default: return nil
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] else { throw Failure("Missing `\(key)`") }
        guard let text = value as? String else { throw Failure("`\(key)` must be a string") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure("`\(key)` is empty") }
        return text
    }

    /// An optional list of strings.
    static func strings(_ args: [String: Any], _ key: String) throws -> [String] {
        guard let value = args[key] else { return [] }
        guard let list = value as? [String] else { throw Failure("`\(key)` must be a list of strings") }
        return list
    }

    /// A JSON boolean, not a number that happens to be 0 or 1.
    static func bool(_ args: [String: Any], _ key: String) throws -> Bool {
        guard let value = args[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw Failure("`\(key)` must be true or false")
        }
        return value.boolValue
    }

    // MARK: board

    /// The sessions that live processes have registered, read off the main thread.
    private func peers(_ store: Store) async -> [String: ClaudePeers.Peer] {
        guard let dir = store.routerFiles?.claudeDir.appendingPathComponent("sessions", isDirectory: true) else { return [:] }
        return await Task.detached(priority: .userInitiated) { ClaudePeers.read(dir: dir) }.value
    }

    /// Dates read from disk may be anything: bounded before they're turned into whole seconds.
    private func age(_ date: Date) -> String { AgentRow.duration(Self.bounded(now().timeIntervalSince(date))) }

    private func sessionFields(_ store: Store, _ session: ClaudeSession, _ peers: [String: ClaudePeers.Peer]) -> [String: Any] {
        let peer = peers[session.id]
        return ["session": session.id, "title": session.title, "project": store.folderName(session.folderKey),
                "peer": peer?.name.isEmpty == false ? peer!.name : session.title, "reachable": peer != nil]
    }

    /// The sessions a message could be for: working ones, then the most recent of the rest.
    /// `projects`: only sessions in these folders (applied before the limit, so a tagged project's sessions all count).
    private func candidates(_ store: Store, projects: Set<String>? = nil) -> (working: [ClaudeSession], recent: [ClaudeSession]) {
        let live = store.claudeSessions.values.filter { !$0.isArchived && (projects?.contains($0.folderKey) ?? true) }
            .sorted { $0.lastActivity > $1.lastActivity }
        return (live.filter(\.running), Array(live.filter { !$0.running }.prefix(20)))
    }

    func board(_ store: Store) async -> String {
        let peers = await peers(store)
        var cards: [[String: Any]] = []
        for card in store.openRouterCards {
            var fields: [String: Any] = ["card": card.id, "kind": card.kind.rawValue, "text": card.text,
                                         "age": age(card.createdAt)]
            if let session = store.claudeSessions[card.sessionID] {
                fields.merge(sessionFields(store, session, peers)) { a, _ in a }
            } else {
                fields.merge(["session": card.sessionID, "title": card.title,
                              "project": store.folderName(card.folder ?? ""), "reachable": false]) { a, _ in a }
            }
            if let form = store.pendingForm(for: card) {
                fields["form"] = form.questions.map { q -> [String: Any] in
                    ["question": q.question, "header": q.header, "multiSelect": q.multiSelect,
                     "options": q.options.map { $0.description.isEmpty ? $0.label : "\($0.label) — \($0.description)" }]
                }
            }
            cards.append(fields)
        }
        let (working, recent) = candidates(store)
        let workingRows = working.map { s -> [String: Any] in
            var fields = sessionFields(store, s, peers)
            let activity = store.claudeActivity[s.id]
            fields["doing"] = activity?.text ?? "Working"
            if activity?.waitsForYou == true { fields["waitingForUser"] = true }
            fields["for"] = age(s.lastUserMessage ?? activity?.since ?? s.lastActivity)
            return fields
        }
        let recentRows = recent.map { s -> [String: Any] in
            var fields = sessionFields(store, s, peers)
            fields["lastActivity"] = age(s.lastActivity) + " ago"
            if let summary = s.summary, !summary.detail.isEmpty { fields["summary"] = summary.detail }
            return fields
        }
        let projects = store.knownFolders.filter { !$0.isEmpty }.map { store.folderName($0) }
        return Self.json(["cards": cards, "working": workingRows, "recent": recentRows, "projects": projects])
    }

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: route

    /// A target `route` can name, and what tells it apart.
    struct Target {
        var target: String
        var hint: String
        var title: String
        var project: String
        var sessionID: String?
        /// The project's folder ("" for none), to narrow by the projects you tagged.
        var folder: String? = nil
    }

    /// `send` only when Jev is sure and clearly ahead of the runner-up.
    static func decision(_ ranked: [(target: String, p: Double)]) -> String {
        guard let top = ranked.first, top.target != "unclear" else { return "ask" }
        let second = ranked.dropFirst().first?.p ?? 0
        return top.p >= 0.75 && top.p - second >= 0.3 ? "send" : "ask"
    }

    /// `projects`: folders the user tagged; only their cards, sessions and new-session targets are offered then.
    private func targets(_ store: Store, projects: Set<String>? = nil) -> [Target] {
        // The projects narrow first; the limits apply to what's left.
        var out: [Target] = []
        for card in store.openRouterCards.filter({ projects?.contains($0.folder ?? "") ?? true }).prefix(60) {
            let project = store.folderName(card.folder ?? "")
            out.append(Target(target: "answer:\(card.id)",
                              hint: "Reply to the \(card.kind.rawValue) card of session “\(card.title)” (project \(project)): \(card.text)",
                              title: card.title, project: project, sessionID: card.sessionID, folder: card.folder ?? ""))
        }
        let (working, recent) = candidates(store, projects: projects)
        for s in (working + recent).prefix(80) {
            let project = store.folderName(s.folderKey)
            let about = store.claudeActivity[s.id]?.text ?? s.summary?.detail ?? ""
            out.append(Target(target: "session:\(s.id)",
                              hint: "Session “\(s.title)” in project \(project)\(about.isEmpty ? "" : ": \(about)")",
                              title: s.title, project: project, sessionID: s.id, folder: s.folderKey))
        }
        for folder in store.knownFolders.filter({ !$0.isEmpty && (projects?.contains($0) ?? true) }).prefix(60) {
            let name = store.folderName(folder)
            out.append(Target(target: "new:\(folder)", hint: "Start a new session in project \(name)", title: "", project: name,
                              folder: folder))
        }
        out.append(Target(target: "unclear", hint: "The message doesn't make clear which session, card or project it is for",
                          title: "", project: ""))
        return out
    }

    /// Without Jev: a session whose title the message names, then its project, then shared words. `named` is the one
    /// target the message names outright, if exactly one.
    static func unassisted(_ message: String, _ targets: [Target]) -> (ranked: [(target: String, score: Int)], named: String?) {
        let text = message.lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        func mentions(_ name: String) -> Bool {
            let name = name.lowercased()
            guard name.count >= 3 else { return false }
            return text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
        }
        var ranked: [(String, Int)] = []
        var titled: Set<String> = []
        var byProject: [String: Set<String>] = [:]
        for t in targets where t.target != "unclear" {
            var score = 0
            if !t.title.isEmpty, mentions(t.title) {
                score += 10
                if let id = t.sessionID, t.target.hasPrefix("session:") { titled.insert(id) }
            }
            if !t.project.isEmpty, mentions(t.project) {
                score += 3
                if let id = t.sessionID, t.target.hasPrefix("session:") { byProject[t.project.lowercased(), default: []].insert(id) }
            }
            let titleWords = Set(t.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            score += words.intersection(titleWords).count
            if score > 0 { ranked.append((t.target, score)) }
        }
        ranked.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var named: String?
        if titled.count == 1 {
            named = "session:\(titled.first!)"
        } else if titled.isEmpty, byProject.count == 1, let only = byProject.values.first, only.count == 1 {
            named = "session:\(only.first!)"
        }
        return (ranked, named)
    }

    func route(_ store: Store, message: String, projects: [String] = []) async throws -> String {
        let tagged = try projects.map { try Self.folder($0, folders: store.knownFolders.filter { !$0.isEmpty }, name: store.folderName) }
        let targets = targets(store, projects: tagged.isEmpty ? nil : Set(tagged))
        let byTarget = Dictionary(targets.map { ($0.target, $0) }, uniquingKeysWith: { a, _ in a })
        let peers = await peers(store)
        func row(_ target: String, _ extra: [String: Any]) -> [String: Any] {
            var fields = extra
            fields["target"] = target
            if let t = byTarget[target] {
                if !t.title.isEmpty { fields["title"] = t.title }
                if !t.project.isEmpty { fields["project"] = t.project }
                if let id = t.sessionID, let session = store.claudeSessions[id] {
                    let peer = peers[id]
                    fields["peer"] = peer?.name.isEmpty == false ? peer!.name : session.title
                    fields["reachable"] = peer != nil
                }
            }
            return fields
        }
        let key = store.typesafeKey ?? ""
        let choose = chooser ?? (key.isEmpty ? nil : { options, hints, state, instructions in
            try await JevClient(key: key).choose(options, hints: hints, for: state, instructions: instructions)
        })
        var why = "no TypeSafe key is set"
        if let choose {
            // Plain keys for Jev (card ids and paths have characters it may not take), mapped back after.
            let keys = targets.indices.map { "o\($0)" }
            let hints = Dictionary(uniqueKeysWithValues: zip(keys, targets.map(\.hint)))
            do {
                let pick = try await choose(keys, hints, ["user message": message],
                    "Which of the user's Claude Code sessions, open cards or projects is this message for? Pick unclear unless the message makes it clear.")
                let ranked = pick.probabilities.compactMap { key, p -> (target: String, p: Double)? in
                    guard let i = keys.firstIndex(of: key) else { return nil }
                    return (targets[i].target, p)
                }.sorted { $0.p != $1.p ? $0.p > $1.p : $0.target < $1.target }
                let top = ranked.prefix(4).map { row($0.target, ["p": (($0.p * 100).rounded() / 100)]) }
                return Self.json(["decision": Self.decision(ranked), "assisted": true, "candidates": top])
            } catch {
                why = "TypeSafe failed: \(error.localizedDescription)"
            }
        }
        let (ranked, named) = Self.unassisted(message, targets)
        var top = ranked.prefix(4).map { row($0.target, ["score": $0.score]) }
        if let named {
            // The target the user named leads.
            let score = ranked.first { $0.target == named }?.score ?? 0
            top.removeAll { $0["target"] as? String == named }
            top.insert(row(named, ["score": score]), at: 0)
        }
        return Self.json(["decision": named == nil ? "ask" : "send", "assisted": false, "candidates": top,
                          "note": "Routing is unassisted (\(why)): candidates by matching words; send only to the target the user named."])
    }

    // MARK: actions

    private func card(_ store: Store, _ id: String) throws -> RouterCard {
        guard let card = store.router.cards.first(where: { $0.id == id }) else { throw Failure("No card \(id); call board") }
        return card
    }

    func answerForm(_ store: Store, _ args: [String: Any], ticket: Ticket) async throws -> String {
        let card = try card(store, Self.string(args, "card"))
        guard let raw = args["answers"] as? [String: Any], !raw.isEmpty else { throw Failure("`answers` must be an object of question → answer") }
        guard let form = store.pendingForm(for: card) else {
            throw Failure("“\(card.title)” has no form Lookout can answer (it isn't stopped on a question Lookout's hook holds). Tell the user to answer it on the card or in Claude.")
        }
        var answers: [String: String] = [:]
        for (key, value) in raw {
            // By the question's text, or its short header.
            let question = form.questions.first { $0.question == key }
                ?? form.questions.first { $0.question.lowercased() == key.lowercased() || (!$0.header.isEmpty && $0.header.lowercased() == key.lowercased()) }
            let text: String
            if let s = value as? String {
                text = s
            } else if let list = value as? [String] {
                text = FormBridge.joined(list)
            } else {
                throw Failure("The answer for “\(key)” must be a string or a list of strings")
            }
            answers[question?.question ?? key] = text
        }
        try live(ticket)
        guard let dir = store.formBridge.dir else { throw Failure("Lookout isn't holding forms (the Router is off)") }
        // Still worth writing when its turn comes: the same Router, the card still open, the same form still held.
        let cardID = card.id, formID = form.id
        try await FormWriter.write(form, answers: answers, dir: dir) { [weak self, weak store] in
            guard let self, let store, self.isLive(ticket),
                  let now = store.router.cards.first(where: { $0.id == cardID }), now.isOpen else { return false }
            return store.pendingForm(for: now)?.id == formID
        }
        return "Answered “\(card.title)”: " + form.questions.map { "\($0.question) = \(answers[$0.question] ?? "")" }.joined(separator: "; ")
    }

    /// A project by Lookout's name for it (case-insensitive), its folder's last component, or its path.
    static func folder(_ query: String, folders: [String], name: (String) -> String) throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (q as NSString).expandingTildeInPath
        if let exact = folders.first(where: { $0 == path || $0 == path.trimmingTrailingSlash }) { return exact }
        let lower = q.lowercased()
        let named = folders.filter { name($0).lowercased() == lower }
        if named.count == 1 { return named[0] }
        let last = folders.filter { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == lower }
        if last.count == 1 { return last[0] }
        let all = folders.map(name).sorted().joined(separator: ", ")
        if named.count + last.count > 1 { throw Failure("“\(q)” names more than one project; use one of: \(all)") }
        throw Failure("Unknown project “\(q)”. Projects: \(all.isEmpty ? "none" : all)")
    }

    /// Haiku, through the binary the agent found (or what a test put in), stopped with the turn.
    private func rephrased(_ store: Store, _ message: String, title: String, project: String) async throws -> Prepared {
        if let rephrase { return try await rephrase(message, title, project) }
        guard let binary = claudePath(), let home = store.routerFiles?.routerHome else {
            throw Failure("Claude Code wasn't found, so the message can't be prepared")
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            return try await tracked { handle in
                try await Rephrase.run(binary: binary, cwd: home, message: message, title: title, project: project,
                                       timeout: rephraseTimeout, handle: handle)
            }
        } catch is CancellationError {
            throw Failure("Stopped; nothing was done")
        } catch {
            throw Failure("Couldn't prepare the message (\(error.localizedDescription)); nothing was sent")
        }
    }

    /// Your message of this turn, which only Lookout hands to Haiku.
    private func yourMessage() throws -> String {
        guard let text = turnText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("There's no message of the user's in this turn to send")
        }
        return text
    }

    /// A session by id, peer name or exact title, and the `to` a message to it takes; `cli`: its Claude Code session id by
    /// the registry of live processes (nil when it has none, or more than one).
    private func target(_ store: Store, _ query: String) async throws
        -> (session: ClaudeSession, to: String, reachable: Bool, cli: String?) {
        let dir = store.routerFiles?.claudeDir.appendingPathComponent("sessions", isDirectory: true)
        let (peers, clis) = await Task.detached(priority: .userInitiated) { () -> ([String: ClaudePeers.Peer], [String: Set<String>]) in
            guard let dir else { return ([:], [:]) }
            return (ClaudePeers.read(dir: dir), Self.cliSessions(dir: dir))
        }.value
        let titled = store.claudeSessions.values.filter { !$0.isArchived && $0.title.lowercased() == query.lowercased() }
        guard let session = store.claudeSessions[query]
            ?? RouterAgent.peerSession(query, peers: peers).flatMap({ store.claudeSessions[$0] })
            ?? (titled.count == 1 ? titled[0] : nil) else {
            throw Failure("No session “\(query)”; call board")
        }
        let peer = peers[session.id].flatMap { $0.name.isEmpty ? nil : $0.name }
        let ids = clis[session.id] ?? []
        await afterLookup?()
        return (session, peer ?? session.title, peer != nil, ids.count == 1 ? ids.first : nil)
    }

    /// Claude Code's session ids of the live processes, by desktop session (`hostSessionId` → `sessionId`).
    nonisolated static func cliSessions(dir: URL, alive: (Int32) -> Bool = FormBridge.processAlive) -> [String: Set<String>] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: Set<String>] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let host = obj["hostSessionId"] as? String, !host.isEmpty,
                  let cli = obj["sessionId"] as? String, !cli.isEmpty,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value ?? Int32(url.deletingPathExtension().lastPathComponent),
                  alive(pid) else { continue }
            out[host, default: []].insert(cli)
        }
        return out
    }

    /// The Claude Code sessions Lookout's plugin runs in now, read off the main thread.
    private func pluginSessions(_ store: Store) async -> Set<String> {
        guard let paths = store.routerFiles else { return [] }
        let presence = paths.pluginSessions
        let registry = paths.claudeDir.appendingPathComponent("sessions", isDirectory: true)
        // On a queue of its own: a poll must not wait behind Swift's pool when that is busy. A presence file counts only
        // while Claude Code's registry still has its process for that session (as `Store.sessionsWithPlugin`).
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: ClaudePlugin.sessions(in: presence, registry: ClaudePeers.registry(dir: registry)))
            }
        }
    }

    /// Your words go to a session only as your own: signed for Lookout's plugin running in it. No plugin, no message.
    /// How long a sign waits for the key to be read again (it wasn't cached yet, or the file changed).
    var keyReloadWait: TimeInterval = 2
    /// Reads the key again (the store's, by default); tests hold it.
    var keyReload: (@MainActor () async -> Bool)?

    /// Runs `work`, returning when it's done or at `deadline`, whichever comes first: a stalled `work` is left to finish on
    /// its own (what it does late is only a cache filled for next time), the caller isn't held by it.
    /// True when the deadline came first.
    @discardableResult
    static func race(deadline: TimeInterval, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                await work()
                if once.claim() { done.resume(returning: false) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.bounded(deadline)) {
                if once.claim() { done.resume(returning: true) }
            }
        }
    }

    /// A span of seconds made safe to compute with: finite, not negative, at most a year.
    nonisolated static func bounded(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(max(seconds, 0), 365 * 86_400) : 0
    }

    /// True for the first caller only.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    private func signed(_ store: Store, _ ready: Prepared, title: String, cli: String?, ticket: Ticket) async throws -> Prepared {
        guard store.routerPluginStatus == .installed else {
            throw Failure("Lookout's plugin isn't installed in Claude Code, so nothing can be sent (Settings → Router)")
        }
        guard let cli else { throw Failure("“\(title)” isn't running in the Claude app: open it first (open_session)") }
        guard await pluginSessions(store).contains(cli) else {
            throw Failure("\(title) started before Lookout's plugin was installed: restart it or run /reload-plugins in it")
        }
        var text = store.signRelay(body: ready.text, target: cli)
        if text == nil {
            // Not cached yet, or the file changed: read it again (bounded), and sign once more if this is still the turn.
            let reload = keyReload ?? { [weak store] in await store?.reloadRelayKey() ?? false }
            await Self.race(deadline: keyReloadWait) { _ = await reload() }
            try live(ticket)
            text = store.signRelay(body: ready.text, target: cli)
        }
        guard let text else {
            throw Failure("Lookout couldn't sign the message (its plugin key is missing); nothing was sent")
        }
        var out = ready
        out.body = ready.text
        out.text = text
        return out
    }

    func prepare(_ store: Store, session query: String, ticket: Ticket) async throws -> String {
        let message = try yourMessage()
        let (session, to, _, cli) = try await target(store, query)
        // Still this turn's call (a late one from an earlier turn changes nothing), then: a new preparation replaces the old
        // one, which is void even if this one fails.
        try live(ticket)
        prepared[to] = nil
        let ready = try await rephrased(store, message, title: session.title, project: store.folderName(session.folderKey))
        try live(ticket)
        let sealed = try await signed(store, ready, title: session.title, cli: cli, ticket: ticket)
        try live(ticket)
        prepared[to] = sealed
        return Self.json(["to": to, "text": sealed.text, "rephrased": ready.rephrased])
    }

    /// Claude Code asks before a SendMessage runs (the native permission prompt, answered by the agent over stdin): only the
    /// text prepared for that target in this turn goes, once, with no field of its own added. Nil allows; else why not.
    func approveSend(_ input: [String: String], otherFields: [String]) -> String? {
        guard turnText != nil else { return "Only the user's messages are sent" }
        // Switched off, and the switch not seen by the agent yet: nothing goes, nothing is used up.
        guard let store, store.router.enabled, store.agents.enabled else { return "The Router is off" }
        guard otherFields.isEmpty else { return "Unexpected fields: \(otherFields.joined(separator: ", ")). Send only `to` and `message`" }
        // What Claude Code adds itself (a preview, the kind of recipient) is checked against the message; nothing else.
        let known: Set<String> = ["to", "message", "summary", "content", "type", "recipient", "recipient_kind"]
        let extra = Set(input.keys).subtracting(known).sorted()
        guard extra.isEmpty else { return "Unexpected fields: \(extra.joined(separator: ", ")). Send only `to` and `message`" }
        guard let to = input["to"], let message = input["message"] else { return "Send `to` and `message`" }
        guard let ready = prepared[to] else { return "Not prepared: call prepare for \(to) first" }
        guard Self.sameBytes(ready.text, message) else {
            return "That isn't the prepared text: send exactly the `text` prepare returned"
        }
        guard input["recipient"].map({ $0 == to }) ?? true, input["type"].map({ $0 == "message" }) ?? true,
              input["recipient_kind"].map({ ["name", "session", "main", "agent"].contains($0) }) ?? true,
              input["summary"].map({ Self.preview($0, of: Self.summary(of: message)) }) ?? true,
              input["content"].map({ Self.preview($0, of: message) }) ?? true else {
            return "The call doesn't match the prepared message"
        }
        prepared[to] = nil
        approved.append((to, message, ready))
        return nil
    }

    /// The summary Claude Code derives from a message (2.1.293): the trimmed message's first line, trimmed. It cuts it at
    /// 200 characters with "…", which `preview` allows.
    nonisolated static func summary(of message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `given` is `full`, or its start cut with "…" (how Claude Code shortens a preview): nothing of anyone else's.
    nonisolated static func preview(_ given: String, of full: String) -> Bool {
        if given == full { return true }
        guard given.hasSuffix("…") else { return false }
        let stem = String(given.dropLast())
        return !stem.isEmpty && stem.count < full.count && full.hasPrefix(stem)
    }

    func startSession(_ store: Store, project: String, title: String, ticket: Ticket) async throws -> String {
        let message = try yourMessage()
        let folder = try Self.folder(project, folders: store.knownFolders.filter { !$0.isEmpty }, name: store.folderName)
        let name = store.folderName(folder)
        let title = SessionStart.cleanTitle(title)
        // Nothing to send it without the plugin: said before a session is made.
        guard store.routerPluginStatus == .installed else {
            throw Failure("Lookout's plugin isn't installed in Claude Code, so nothing can be sent (Settings → Router)")
        }
        // Prepared first: if Haiku fails (or you stop), no session is made.
        var ready = try await rephrased(store, message, title: title, project: name)
        try live(ticket)
        let started: SessionStart.Started
        if let starter {
            started = try await starter(folder, title)
        } else {
            started = try await start(store, folder: folder, name: name, title: title, ticket: ticket)
        }
        try live(ticket)
        // Its plugin comes up with it: waited for (bounded), then the prompt is signed for it.
        try await waitForPlugin(store, cli: started.cliID, ticket: ticket)
        ready = try await signed(store, ready, title: title, cli: started.cliID, ticket: ticket)
        try live(ticket)
        ready.newSessionIn = name
        prepared[started.peer] = ready
        return Self.json(["session": started.sessionID, "peer": started.peer, "text": ready.text, "rephrased": ready.rephrased,
                          "next": "SendMessage exactly `text` to `peer` (already prepared)."])
    }

    /// How long Haiku has to answer (tests give a helper that never answers more than they need).
    var rephraseTimeout: TimeInterval = Rephrase.timeout

    /// How long a new session's plugin has to say it runs.
    var pluginWait: TimeInterval = SessionStart.wait

    private func waitForPlugin(_ store: Store, cli: String, ticket: Ticket) async throws {
        let deadline = Date().addingTimeInterval(pluginWait)
        repeat {
            try live(ticket)
            if await pluginSessions(store).contains(cli) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        // One last look: the wait may have been slow, not the plugin.
        try live(ticket)
        if await pluginSessions(store).contains(cli) { return }
        throw Failure("The new session started, but Lookout's plugin didn't come up in it within \(Int(Self.bounded(pluginWait))) s; nothing was sent")
    }

    /// The verified way to make a desktop session: a CLI session with no model call, imported by the app, then its process.
    private func start(_ store: Store, folder: String, name: String, title: String, ticket: Ticket) async throws -> SessionStart.Started {
        guard let binary = claudePath(), let peersDir = store.routerFiles?.claudeDir.appendingPathComponent("sessions") else {
            throw Failure("Claude Code wasn't found, so no session can be started")
        }
        let uuid = UUID().uuidString.lowercased()
        try live(ticket)
        let output: OneShot.Output
        do {
            output = try await tracked { handle in
                try await OneShot.run(binary, SessionStart.bootstrapArguments(uuid: uuid, title: title),
                                      cwd: URL(fileURLWithPath: folder), timeout: SessionStart.wait, handle: handle)
            }
        } catch is CancellationError {
            throw Failure("Stopped; nothing was done")
        }
        _ = try OneShot.result(output)
        guard let url = SessionStart.importURL(uuid: uuid) else { throw Failure("Couldn't make the link") }
        try live(ticket)
        if let intercept = store.interceptOpen { intercept("New Claude session in \(name)") } else { Link.open(url) }
        let peer = try await SessionStart.waitForPeer(uuid: uuid, dir: peersDir) { [weak self] in try self?.live(ticket) }
        return SessionStart.Started(sessionID: "local_\(uuid)", peer: peer)
    }

    func openSession(_ store: Store, _ query: String, ticket: Ticket) throws -> String {
        let session: ClaudeSession
        if let s = store.claudeSessions[query] {
            session = s
        } else {
            let titled = store.claudeSessions.values.filter { !$0.isArchived && $0.title.lowercased() == query.lowercased() }
            guard titled.count == 1 else {
                throw Failure(titled.isEmpty ? "No session “\(query)”; call board" : "More than one session is called “\(query)”; use its id")
            }
            session = titled[0]
        }
        try live(ticket)
        store.openAgent(session.id)
        return "Opened “\(session.title)” in Claude."
    }

    func mark(_ store: Store, _ args: [String: Any], ticket: Ticket) throws -> String {
        let card = try card(store, Self.string(args, "card"))
        let addressed = try Self.bool(args, "addressed")
        try live(ticket)
        store.setCardAddressed(card.id, addressed, now: now())
        return addressed ? "Marked “\(card.title)” addressed." : "Opened “\(card.title)” again."
    }
}

private extension String {
    var trimmingTrailingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}

extension FormWriter {
    /// The answer file, written whole and only if there's none yet (renamed into place with RENAME_EXCL).
    fileprivate static func exclusive(_ form: PendingForm, answers: [String: String], dir: URL) throws {
        let clean = try FormBridge.validate(form, answers)
        let data = try JSONSerialization.data(withJSONObject: ["answers": clean], options: [.sortedKeys])
        let url = FormBridge.answerURL(form.id, in: dir)
        let temp = try PrivateFile.prepare(data, for: url)
        guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            let failure = errno
            unlink(temp.path)
            if failure == EEXIST { throw AlreadyAnswered() }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// Writes a form's answer for the hook, off the main thread: the Router's `answer_form` and the cards' own answers both go
/// through here, one write at a time.
enum FormWriter {
    /// One write at a time (tests hold it to look between the check and the write).
    static let queue = DispatchQueue(label: "lookout.forms.writer", qos: .utility)

    struct Cancelled: LocalizedError {
        var errorDescription: String? { "Not sent: the Router was reset or switched off" }
    }

    /// Another answer for the same form came first (yours on its card, or the Router's): it stands, this one isn't sent.
    struct AlreadyAnswered: LocalizedError {
        var errorDescription: String? { "Already answered: an answer to this form was sent first, and it stands" }
    }

    /// Set once, read from any thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// The forms an answer was written for, by folder and key: touched only on `queue`. Each is answered once.
    nonisolated(unsafe) private static var claimed: [String] = []

    /// Checks the answers at once (throwing `FormBridge.Failure`), then writes `<form.id>.answer.json` in `dir` on a utility
    /// queue. `stillValid` is asked on the main thread right before the write; false (or the task cancelled) throws
    /// `Cancelled` and writes nothing.
    @MainActor
    static func write(_ form: PendingForm, answers: [String: String], dir: URL,
                      stillValid: @escaping @MainActor () -> Bool = { true }) async throws {
        _ = try FormBridge.validate(form, answers)
        guard !Task.isCancelled, stillValid() else { throw Cancelled() }
        // The task's cancellation reaches the queued write: checked right before it commits.
        let cancelled = Flag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async {
                    let valid = !cancelled.isSet && DispatchQueue.main.sync { MainActor.assumeIsolated { stillValid() } }
                    guard valid, !cancelled.isSet else { return done.resume(throwing: Cancelled()) }
                    // First answer wins: one claim per form, and the file is never replaced (a late answer can't overwrite
                    // the one already waiting for the hook).
                    let claim = dir.standardizedFileURL.path + "/" + form.id
                    guard !claimed.contains(claim) else { return done.resume(throwing: AlreadyAnswered()) }
                    do {
                        try exclusive(form, answers: answers, dir: dir)
                        claimed.append(claim)
                        if claimed.count > 1000 { claimed.removeFirst(claimed.count - 1000) }
                        done.resume()
                    } catch {
                        if error is AlreadyAnswered { claimed.append(claim) }
                        done.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }
}
