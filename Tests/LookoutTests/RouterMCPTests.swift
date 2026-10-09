import Foundation
import Testing
@testable import Lookout

/// The Router's MCP server without a socket: HTTP framing, the JSON-RPC it speaks, and its tools on a store of the test's own.
@MainActor
@Suite struct RouterMCP {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func json(_ data: Data?) -> Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } }

    private func rpc(_ object: Any, call: ((String, [String: Any]) async -> RouterRPC.ToolResult?)? = nil) async -> RouterRPC.Reply {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return await RouterRPC.handle(body, tools: RouterTools.specs, version: "9") { name, args in
            await call?(name, args) ?? nil
        }
    }

    // MARK: HTTP

    @Test func theHeadIsReadOnItsOwnBeforeTheBody() throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc\r\nContent-Length: 4\r\n\r\n"
        #expect(MiniHTTP.parseHead(Data("POST /mcp HTTP/1.1\r\nHost".utf8)) == .incomplete)
        // The head is whole without any of the body.
        guard case .head(let parsed, let consumed) = MiniHTTP.parseHead(Data(head.utf8)) else { Issue.record("not parsed"); return }
        #expect(parsed.method == "POST" && parsed.path == "/mcp" && parsed.contentLength == 4 && parsed.keepAlive)
        #expect(parsed.headers["authorization"] == "Bearer abc" && consumed == head.utf8.count)
        #expect(MiniHTTP.parseHead(Data("nonsense\r\n\r\n".utf8)) == .invalid(400))
        #expect(MiniHTTP.parseHead(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid(411))
        #expect(MiniHTTP.parseHead(Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid(400))
        guard case .head(let closing, _) = MiniHTTP.parseHead(Data("GET /mcp HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)) else {
            Issue.record("not parsed"); return
        }
        #expect(!closing.keepAlive)
    }

    @Test func anOversizedHeadIsRefusedWithOrWithoutItsEnd() {
        let big = "POST /mcp HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: MiniHTTP.maxHeader) + "\r\n"
        #expect(MiniHTTP.parseHead(Data(big.utf8)) == .invalid(431))
        #expect(MiniHTTP.parseHead(Data((big + "\r\n").utf8)) == .invalid(431))
    }

    @Test func aResponseSaysItsLength() {
        let text = String(decoding: MiniHTTP.response(200, body: Data("{}".utf8), keepAlive: true), as: UTF8.self)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}")
        let empty = String(decoding: MiniHTTP.response(202, keepAlive: false), as: UTF8.self)
        #expect(empty == "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    @Test func onlyTheTokenHolderPostingASmallBodyToMcpGetsThrough() {
        func head(_ method: String, _ path: String, _ auth: String?, length: Int = 1) -> MiniHTTP.Head {
            MiniHTTP.Head(method: method, path: path, headers: auth.map { ["authorization": $0] } ?? [:], contentLength: length)
        }
        #expect(RouterMCPServer.route(head("POST", "/mcp", "Bearer tok"), token: "tok") == .accept)
        #expect(RouterMCPServer.route(head("POST", "/mcp", nil), token: "tok") == .reply(401, allow: false))
        #expect(RouterMCPServer.route(head("POST", "/mcp", "Bearer tox"), token: "tok") == .reply(401, allow: false))
        #expect(RouterMCPServer.route(head("POST", "/other", "Bearer tok"), token: "tok") == .reply(404, allow: false))
        #expect(RouterMCPServer.route(head("GET", "/mcp", "Bearer tok"), token: "tok") == .reply(405, allow: true))
        #expect(RouterMCPServer.route(head("POST", "/mcp?x=1", "Bearer tok"), token: "tok") == .accept)
        // The token is checked first: a stranger learns nothing, not even that the body is too big.
        #expect(RouterMCPServer.route(head("POST", "/mcp", nil, length: 50_000_000), token: "tok") == .reply(401, allow: false))
        #expect(RouterMCPServer.route(head("POST", "/mcp", "Bearer tok", length: MiniHTTP.maxBody + 1), token: "tok") == .reply(413, allow: false))
    }

    @Test func theConfigPointsAtTheServerWithItsToken() throws {
        let server = RouterMCPServer { _ in RouterRPC.Reply(status: 202, body: nil) }
        #expect(server.token.count == 64)
        let config = try #require(json(server.config(port: 4321)) as? [String: Any])
        let lookout = try #require((config["mcpServers"] as? [String: Any])?["lookout"] as? [String: Any])
        #expect(lookout["type"] as? String == "http" && lookout["url"] as? String == "http://127.0.0.1:4321/mcp")
        #expect((lookout["headers"] as? [String: String])?["Authorization"] == "Bearer \(server.token)")
    }

    // MARK: JSON-RPC

    @Test func theHandshakeGoesAsClaudeCodeDoesIt() async throws {
        // Newer clients ask `server/discover` first; "method not found" makes them fall back to `initialize`.
        let discover = try #require(json(await rpc(["jsonrpc": "2.0", "id": 0, "method": "server/discover"]).body) as? [String: Any])
        #expect((discover["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(discover["id"] as? Int == 0)

        let reply = await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                               "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "claude-code"]]])
        #expect(reply.status == 200)
        let result = try #require((json(reply.body) as? [String: Any])?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "lookout")

        let note = await rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(note.status == 202 && note.body == nil)

        let list = try #require((json(await rpc(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]).body) as? [String: Any])?["result"] as? [String: Any])
        let tools = try #require(list["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["board", "route", "prepare", "answer_form", "start_session", "open_session", "mark"])
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && $0["description"] is String })

        let ping = try #require(json(await rpc(["jsonrpc": "2.0", "id": 2, "method": "ping"]).body) as? [String: Any])
        #expect(ping["result"] is [String: Any])
        let other = try #require(json(await rpc(["jsonrpc": "2.0", "id": 3, "method": "resources/list"]).body) as? [String: Any])
        #expect((other["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func aToolCallGivesTextAndSaysWhenItFailed() async throws {
        let call: (String, [String: Any]) async -> RouterRPC.ToolResult? = { name, args in
            switch name {
            case "board": return RouterRPC.ToolResult(text: "cards: \(args.count)")
            case "mark": return .error("No card x")
            default: return nil
            }
        }
        let ok = try #require((json(await rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                               "params": ["name": "board", "arguments": [:]]], call: call).body) as? [String: Any])?["result"] as? [String: Any])
        #expect((ok["content"] as? [[String: Any]])?.first?["text"] as? String == "cards: 0")
        #expect(ok["isError"] as? Bool == false)
        let failed = try #require((json(await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                   "params": ["name": "mark", "arguments": ["card": "x"]]], call: call).body) as? [String: Any])?["result"] as? [String: Any])
        #expect(failed["isError"] as? Bool == true)
        let unknown = try #require(json(await rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                   "params": ["name": "rm"]], call: call).body) as? [String: Any])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func batchesAndBadBodies() async throws {
        let batch = await rpc([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/initialized"],
                               ["jsonrpc": "2.0", "id": 2, "method": "nope"]])
        let replies = try #require(json(batch.body) as? [[String: Any]])
        #expect(batch.status == 200 && replies.count == 2)
        #expect(await rpc([["jsonrpc": "2.0", "method": "notifications/initialized"]]).status == 202)
        // A response from the client (to nothing we asked) gets nothing back.
        #expect(await rpc(["jsonrpc": "2.0", "id": 9, "result": [:]]).status == 202)
        let garbage = await RouterRPC.handle(Data("{not json".utf8), tools: []) { _, _ in nil }
        #expect(garbage.status == 400)
        #expect(((json(garbage.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    // MARK: Tools

    private func session(_ id: String, _ title: String, folder: String?, running: Bool = false, minutes: Double = -5) -> ClaudeSession {
        ClaudeSession(id: id, title: title, folder: folder, completedTurns: 1, lastActivity: now.addingTimeInterval(minutes * 60),
                      lastUserMessage: now.addingTimeInterval(-600), summary: .init(blocked: false, detail: "Tests pass"),
                      running: running, cliID: "cli-\(id)")
    }

    /// Sessions in two projects, one open question card with a form, the Router's files in `dir`.
    private func store(_ dir: TempDir) async -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Lookout.app/Contents/MacOS/Lookout"
        s.agents.enabled = true
        s.claudeSessions = [
            "local_a": session("local_a", "Fix the login bug", folder: "/code/lookout", running: true),
            "local_b": session("local_b", "Write the README", folder: "/code/api"),
        ]
        // Stopped on a question since 0.5 s after the epoch: its card is `local_a#w500`.
        s.claudeActivity = ["local_a": ClaudeActivity(text: "Which database?", since: Date(timeIntervalSince1970: 0.5),
                                                      waitsForYou: true, tool: "AskUserQuestion")]
        s.setRouterEnabled(true, now: now)
        await s.routerHookWork?.value
        s.router.cards = [RouterCard(id: "local_a#w500", sessionID: "local_a", kind: .question, title: "Fix the login bug",
                                     folder: "/code/lookout", text: "Which database?", createdAt: now.addingTimeInterval(-60),
                                     toolUseID: "toolu_a")]
        s.router.waits["local_a"] = 500
        // The form as the hook leaves it, read by the bridge (which replaces whatever is set by hand).
        let pending = try! JSONSerialization.data(withJSONObject: [
            "key": "cli-local_a-1-1", "session_id": "cli-local_a", "transcript_path": "/tmp/t.jsonl", "cwd": "/code/lookout",
            "tool_input": ["questions": [["question": "Which database?", "header": "DB", "multiSelect": false,
                                          "options": [["label": "Postgres", "description": "Relational"], ["label": "SQLite", "description": ""]]]]],
            "created_at": 1000, "pid": Int(getpid()), "tool_use_id": "toolu_a",
        ] as [String: Any])
        try? pending.write(to: dir.path("support/forms/cli-local_a-1-1.json"))
        s.formBridge.refresh()
        await waitUntil(within: 120) { !s.pendingForms.isEmpty }
        #expect(!s.pendingForms.isEmpty, "the bridge never read the form")
        // A live process for one of them.
        let sessions = dir.path("claude/sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let peer = try! JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "hostSessionId": "local_a", "sessionId": "cli-local_a",
                                                                "name": "Fix the login bug", "status": "busy"])
        try? peer.write(to: sessions.appendingPathComponent("\(getpid()).json"))
        // Lookout's plugin: installed, its key made, and running in local_a.
        s.routerPluginStatus = .installed
        try? Data("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".utf8).write(to: dir.path("support/relay.key"))
        PluginFixture.useKey(s)
        let presence = dir.path("support/plugin-sessions")
        try? FileManager.default.createDirectory(at: presence, withIntermediateDirectories: true)
        PluginFixture.live("cli-local_a", support: dir.path("support"), claude: dir.path("claude"))
        // A session started by start_session (local_new → its CLI id "new") comes up with the plugin too.
        PluginFixture.live("new", support: dir.path("support"), claude: dir.path("claude"))
        return s
    }

    private func route(_ t: RouterTools, _ args: [String: Any]) async throws -> [String: Any] {
        let out = try #require(await t.call("route", args))
        return try #require(json(Data(out.text.utf8)) as? [String: Any])
    }

    /// Tools in a turn of the user's (side effects need one).
    private func tools(_ s: Store, turn: String? = "do it") -> RouterTools {
        let tools = RouterTools(store: s)
        tools.now = { now }
        tools.beginTurn(turn)
        return tools
    }

    @Test func theBoardListsCardsFormsSessionsAndProjects() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let out = try #require(await tools(s).call("board", [:]))
        #expect(!out.isError)
        let board = try #require(json(Data(out.text.utf8)) as? [String: Any])
        let card = try #require((board["cards"] as? [[String: Any]])?.first)
        #expect(card["card"] as? String == "local_a#w500" && card["kind"] as? String == "question" && card["project"] as? String == "lookout")
        #expect(card["peer"] as? String == "Fix the login bug" && card["reachable"] as? Bool == true && card["age"] as? String == "1m")
        let form = try #require((card["form"] as? [[String: Any]])?.first)
        #expect(form["options"] as? [String] == ["Postgres — Relational", "SQLite"])
        let working = try #require((board["working"] as? [[String: Any]])?.first)
        #expect(working["doing"] as? String == "Which database?" && working["for"] as? String == "10m")
        #expect(working["waitingForUser"] as? Bool == true)
        let recent = try #require((board["recent"] as? [[String: Any]])?.first)
        #expect(recent["title"] as? String == "Write the README" && recent["reachable"] as? Bool == false)
        #expect(Set(board["projects"] as? [String] ?? []) == ["lookout", "api"])
    }

    @Test func argumentsAreChecked() async throws {
        let dir = TempDir()
        let store = await store(dir)
        let s = tools(store)
        #expect(await s.call("route", [:])?.text == "Missing `message`")
        #expect(await s.call("route", ["message": 3])?.text == "`message` must be a string")
        #expect(await s.call("start_session", ["project": "lookout", "title": "  "])?.text == "`title` is empty")
        #expect(await s.call("mark", ["card": "local_a#w500"])?.text == "`addressed` must be true or false")
        #expect(await s.call("mark", ["card": "nope", "addressed": true])?.isError == true)
        #expect(await s.call("answer_form", ["card": "local_a#w500"])?.isError == true)
        #expect(await s.call("open_session", ["session": "Nobody"])?.isError == true)
        #expect(await s.call("rm", [:]) == nil)
    }

    @Test func aFormIsAnsweredThroughTheBridge() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        let bad = try #require(await t.call("answer_form", ["card": "local_a#w500", "answers": ["Which colour?": "Red"]]))
        #expect(bad.isError && bad.text.contains("no question"))
        let out = try #require(await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]]))
        #expect(!out.isError, "\(out.text)")
        let file = FormBridge.answerURL("cli-local_a-1-1", in: dir.path("support").appendingPathComponent("forms"))
        let written = try #require(json(try Data(contentsOf: file)) as? [String: Any])
        #expect(written["answers"] as? [String: String] == ["Which database?": "SQLite"])
        // A card without a form held by the hook can't be answered here.
        s.pendingForms = [:]
        let none = try #require(await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]]))
        #expect(none.isError && none.text.contains("no form"))
    }

    @Test func aNewSessionStartsInAKnownProjectOnly() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var started: [String] = []
        t.rephrase = { message, _, _ in Prepared(text: message, original: message, rephrased: false) }
        t.starter = { folder, title in
            started.append("\(folder) · \(title)")
            return SessionStart.Started(sessionID: "local_new", peer: title)
        }
        t.beginTurn("Add a test")
        let out = try #require(await t.call("start_session", ["project": "LOOKOUT", "title": "Add a test"]))
        #expect(!out.isError && started == ["/code/lookout · Add a test"])
        let unknown = try #require(await t.call("start_session", ["project": "web", "title": "Hi there"]))
        #expect(unknown.isError && unknown.text.contains("api") && unknown.text.contains("lookout"))
        #expect(started.count == 1)
        #expect(try RouterTools.folder("/code/api/", folders: ["/code/api"], name: { $0 }) == "/code/api")
        #expect(throws: RouterTools.Failure.self) {
            try RouterTools.folder("app", folders: ["/a/app", "/b/app"], name: { $0 })
        }
    }

    @Test func openingAndMarking() async throws {
        let dir = TempDir()
        let s = await store(dir)
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        let t = tools(s)
        #expect(await t.call("open_session", ["session": "write the readme"])?.isError == false)
        #expect(opened == ["Open in Claude · Write the README"])
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": true])?.isError == false)
        #expect(s.router.cards[0].addressedBy == .you)
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": false])?.isError == false)
        #expect(s.router.cards[0].isOpen)
    }

    // MARK: route

    @Test func routeSendsOnlyWhenSureAndClearlyAhead() {
        #expect(RouterTools.decision([("session:a", 0.8), ("session:b", 0.1)]) == "send")
        #expect(RouterTools.decision([("session:a", 0.75), ("session:b", 0.45)]) == "send")
        #expect(RouterTools.decision([("session:a", 0.74), ("session:b", 0.01)]) == "ask")
        #expect(RouterTools.decision([("session:a", 0.8), ("session:b", 0.55)]) == "ask")
        #expect(RouterTools.decision([("unclear", 0.95)]) == "ask")
        #expect(RouterTools.decision([("session:a", 1)]) == "send")
        #expect(RouterTools.decision([]) == "ask")
    }

    @Test func routeAsksJevAndMapsItsPickBack() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var asked: [String] = []
        var hints: [String: String] = [:]
        t.chooser = { options, h, state, _ in
            asked = options
            hints = h
            #expect(state == ["user message": "use sqlite"])
            // The card's option first: answer it.
            return JevClient.Choice(choice: options[0], confidence: 0.9, probabilities: [options[0]: 0.9, options[1]: 0.05, options.last!: 0.05])
        }
        let out = try await route(t, ["message": "use sqlite"])
        #expect(asked.count == 6)
        #expect(hints[asked[0]]?.contains("question card") == true)
        #expect(out["decision"] as? String == "send" && out["assisted"] as? Bool == true)
        let top = try #require((out["candidates"] as? [[String: Any]])?.first)
        #expect(top["target"] as? String == "answer:local_a#w500" && top["peer"] as? String == "Fix the login bug")
    }

    @Test func withoutJevRouteMatchesWordsAndAsks() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        // No key, no chooser: unassisted.
        let vague = try await route(t, ["message": "how is the login going?"])
        #expect(vague["decision"] as? String == "ask" && vague["assisted"] as? Bool == false)
        #expect((vague["note"] as? String)?.contains("no TypeSafe key") == true)
        #expect((vague["candidates"] as? [[String: Any]])?.first?["target"] as? String == "answer:local_a#w500")
        let named = try await route(t, ["message": "tell Write the README to add badges"])
        #expect(named["decision"] as? String == "send")
        #expect((named["candidates"] as? [[String: Any]])?.first?["target"] as? String == "session:local_b")

        // A failing Jev falls back the same way, and says why.
        t.chooser = { _, _, _, _ in throw JevClient.Failure(message: "TypeSafe is busy") }
        let failed = try await route(t, ["message": "api: add badges"])
        #expect((failed["note"] as? String)?.contains("TypeSafe is busy") == true)
        // The project names one session only: that one.
        #expect(failed["decision"] as? String == "send")
        #expect((failed["candidates"] as? [[String: Any]])?.first?["target"] as? String == "session:local_b")
    }

    @Test func unassistedScoring() {
        let targets = [
            RouterTools.Target(target: "session:a", hint: "", title: "Fix login", project: "web", sessionID: "a"),
            RouterTools.Target(target: "session:b", hint: "", title: "Docs", project: "web", sessionID: "b"),
            RouterTools.Target(target: "new:/code/web", hint: "", title: "", project: "web"),
        ]
        let byProject = RouterTools.unassisted("web: ship it", targets)
        #expect(byProject.named == nil)
        #expect(Set(byProject.ranked.map(\.target)) == ["session:a", "session:b", "new:/code/web"])
        let byTitle = RouterTools.unassisted("fix login now", targets)
        #expect(byTitle.named == "session:a" && byTitle.ranked.first?.target == "session:a")
        #expect(RouterTools.unassisted("hello", targets).ranked.isEmpty)
    }

    // MARK: Review fixes

    @Test func markTakesOnlyARealBoolean() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        let one = try #require(await t.call("mark", ["card": "local_a#w500", "addressed": NSNumber(value: 1)]))
        #expect(one.isError && one.text == "`addressed` must be true or false")
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": "true"])?.isError == true)
        #expect(s.router.cards[0].isOpen)
        // As JSON gives it.
        let args = try #require(json(Data(#"{"card":"local_a#w500","addressed":true}"#.utf8)) as? [String: Any])
        #expect(await t.call("mark", args)?.isError == false)
        #expect(!s.router.cards[0].isOpen)
    }

    @Test func aCallFromBeforeAResetChangesNothing() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        let gate = RouterGate()
        t.chooser = { options, _, _, _ in
            await gate.wait()
            return JevClient.Choice(choice: options[0], confidence: 1, probabilities: [options[0]: 1])
        }
        let epoch = t.epoch
        let routing = Task { await t.call("route", ["message": "use sqlite"], epoch: epoch) }
        while !gate.waiting { await Task.yield() }
        // Reset while route waits on Jev; then the call goes on, and the same request tries to act.
        t.reset()
        gate.open()
        let routed = await routing.value
        #expect(routed?.isError == true && routed?.text.contains("reset") == true)
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": true], epoch: epoch)?.isError == true)
        #expect(await t.call("start_session", ["project": "lookout", "title": "Hi"], epoch: epoch)?.isError == true)
        #expect(await t.call("open_session", ["session": "local_b"], epoch: epoch)?.isError == true)
        #expect(await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]], epoch: epoch)?.isError == true)
        #expect(s.router.cards[0].isOpen && opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: FormBridge.answerURL("cli-local_a-1-1", in: dir.path("support/forms")).path))
        // A call of the Router as it is now (a new turn of yours) still works.
        t.beginTurn("mark it")
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": true])?.isError == false)
    }

    @Test func jevWithoutADistributionFallsBackToUnassisted() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        func answering(_ body: String) -> ([String], [String: String], [String: String], String) async throws -> JevClient.Choice {
            { options, _, _, _ in
                let keys = Dictionary(uniqueKeysWithValues: options.map { (JevClient.key(for: $0), $0) })
                return try JevClient.parse(Data(body.replacingOccurrences(of: "FIRST", with: options[0]).utf8), keys: keys)
            }
        }
        // Jev names a pick but gives no probabilities: nothing is made up, the route is unassisted and asks.
        t.chooser = answering(#"{"answers":{"pick":{"choice":"FIRST","confidence":0.99}}}"#)
        let missing = try await route(t, ["message": "use sqlite"])
        #expect(missing["assisted"] as? Bool == false && missing["decision"] as? String == "ask")
        #expect((missing["note"] as? String)?.contains("no probabilities") == true)
        // A full distribution is used as given.
        t.chooser = answering(#"{"answers":{"pick":{"choice":"FIRST","probabilities":{"FIRST":1}}}}"#)
        let sure = try await route(t, ["message": "use sqlite"])
        #expect(sure["assisted"] as? Bool == true && sure["decision"] as? String == "send")
    }

    @Test func switchedOffMeansNoSideEffectEvenForACurrentCall() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var opened: [String] = []
        s.interceptOpen = { opened.append($0) }
        let epoch = t.epoch
        s.router.enabled = false
        let marked = try #require(await t.call("mark", ["card": "local_a#w500", "addressed": true], epoch: epoch))
        #expect(marked.isError && marked.text.contains("off"))
        s.router.enabled = true
        s.agents.enabled = false
        #expect(await t.call("open_session", ["session": "local_b"], epoch: epoch)?.isError == true)
        #expect(s.router.cards[0].isOpen && opened.isEmpty)
    }

    @Test func theFormWriterChecksRightBeforeWriting() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let form = try #require(s.pendingForms["cli-local_a"])
        let forms = dir.path("support/forms")
        let file = FormBridge.answerURL(form.id, in: forms)
        // Bad answers are refused at once.
        await #expect(throws: FormBridge.Failure.self) { try await FormWriter.write(form, answers: [:], dir: forms) }
        // No longer valid when its turn to write comes: nothing written.
        var valid = true
        let writing = Task { try await FormWriter.write(form, answers: ["Which database?": "SQLite"], dir: forms) { valid } }
        valid = false
        await #expect(throws: FormWriter.Cancelled.self) { try await writing.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try await FormWriter.write(form, answers: ["Which database?": "SQLite"], dir: forms)
        #expect((json(try Data(contentsOf: file)) as? [String: Any])?["answers"] as? [String: String] == ["Which database?": "SQLite"])
    }

    @Test func batchesAndRepliesAreBounded() async throws {
        let ping = ["jsonrpc": "2.0", "id": 1, "method": "ping"] as [String: Any]
        let tooMany = await rpc(Array(repeating: ping, count: RouterRPC.maxBatch + 1))
        #expect(tooMany.status == 400)
        #expect(((json(tooMany.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(await rpc(Array(repeating: ping, count: RouterRPC.maxBatch)).status == 200)
        // Each reply is ~150 bytes: with 400 for all, the third no longer fits and says so.
        let calls = (1...3).map { ["jsonrpc": "2.0", "id": $0, "method": "tools/call", "params": ["name": "board"]] as [String: Any] }
        let body = try JSONSerialization.data(withJSONObject: calls)
        let reply = await RouterRPC.handle(body, tools: [], maxResponse: 400) { _, _ in
            RouterRPC.ToolResult(text: String(repeating: "x", count: 80))
        }
        let replies = try #require(json(reply.body) as? [[String: Any]])
        #expect(replies.count == 3)
        #expect(replies[0]["result"] != nil && replies[1]["result"] != nil)
        #expect((replies[2]["error"] as? [String: Any])?["code"] as? Int == -32603 && replies[2]["id"] as? Int == 3)
        // Under the cap, but for the short errors standing in for what didn't fit.
        #expect((reply.body?.count ?? 0) <= 400 + 100)
        let single = await RouterRPC.handle(try JSONSerialization.data(withJSONObject: calls[0]), tools: [], maxResponse: 50) { _, _ in
            RouterRPC.ToolResult(text: String(repeating: "x", count: 80))
        }
        #expect(((json(single.body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32603)
    }

    @Test func anAnswerWaitingToBeWrittenIsDroppedWhenItsCardCloses() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        let file = FormBridge.answerURL("cli-local_a-1-1", in: dir.path("support/forms"))
        // The writer is busy: the answer waits behind it.
        let hold = DispatchSemaphore(value: 0)
        FormWriter.queue.async { hold.wait() }
        let answering = Task { await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        s.setCardAddressed("local_a#w500", true)
        hold.signal()
        let out = try #require(await answering.value)
        #expect(out.isError && out.text.contains("Not sent"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Preparing and starting

    /// What Claude Code asks before a SendMessage runs (the input as 2.1.293 sends it), and Lookout's answer.
    /// `message` is the body: what goes is the text prepare signed for it (else the body itself, unsigned).
    private func gate(_ t: RouterTools, to: String, message: String, extra: [String: String] = [:],
                      others: [String] = []) -> (allow: Bool, reason: String?) {
        var input = claudeInput(to, sealed(t, to, message))
        input.merge(extra) { _, new in new }
        let refusal = t.approveSend(input, otherFields: others)
        return (refusal == nil, refusal)
    }

    @Test func prepareTakesTheUsersOwnMessageNotTheRouters() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var asked: [String] = []
        t.rephrase = { message, title, project in
            asked.append("\(title) · \(project) · \(message)")
            return Prepared(text: "Bump the version.", original: message, rephrased: true)
        }
        // No message of yours in this turn (a session's turn): nothing to prepare.
        t.endTurn()
        #expect(await t.call("prepare", ["session": "local_a"])?.isError == true)
        t.beginTurn("tell it to bump the version")
        // By session id, or by its peer name; any `message` the Router adds is not an input.
        #expect(await t.call("prepare", ["session": "local_a", "message": "something else"])?.isError == false)
        let out = try #require(await t.call("prepare", ["session": "Fix the login bug"]))
        let first = try #require(json(Data(out.text.utf8)) as? [String: Any])
        // What to send is the body signed for the session's plugin (its Claude Code session id from the registry).
        let text = try #require(first["text"] as? String)
        #expect(first["to"] as? String == "Fix the login bug" && first["rephrased"] as? Bool == true)
        #expect(text.hasPrefix("⟦lookout v1 cli-local_a ") && text.hasSuffix("⟧\n" + Data("Bump the version.".utf8).base64EncodedString()))
        #expect(t.prepared["Fix the login bug"]?.body == "Bump the version.")
        #expect(asked == Array(repeating: "Fix the login bug · lookout · tell it to bump the version", count: 2))
        // A session with no process can't get your words: refused.
        let away = try #require(await t.call("prepare", ["session": "Write the README"]))
        #expect(away.isError && away.text.contains("isn't running"))
        #expect(await t.call("prepare", ["session": "nobody"])?.isError == true)
    }

    @Test func theGateLetsThroughOnlyThePreparedTextOnce() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        t.beginTurn("tell lookout to bump the version")
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.").reason?.contains("Not prepared") == true)
        _ = await t.call("prepare", ["session": "local_a"])
        // Another text, a field of its own, a preview that isn't the message: refused, and the preparation stays.
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version!").reason?.contains("isn't the prepared text") == true)
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.", extra: ["notify_when_idle": "true"])
            .reason?.contains("notify_when_idle") == true)
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.", others: ["files"]).reason?.contains("files") == true)
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.", extra: ["summary": "Delete everything"]).allow == false)
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.", extra: ["recipient": "someone else"]).allow == false)
        let signed = sealed(t, "Fix the login bug", "Bump the version.")
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.").allow)
        // Once.
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.").allow == false)
        #expect(t.takeApproved("Fix the login bug", signed)?.original == "tell lookout to bump the version")
        // A preparation of an earlier turn, or stopped, is gone.
        _ = await t.call("prepare", ["session": "local_a"])
        t.endTurn()
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.").allow == false)
    }

    @Test func preparingAgainVoidsTheEarlierOne() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        t.beginTurn("tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        t.rephrase = { _, _, _ in throw RouterTools.Failure("Couldn't prepare the message") }
        #expect(await t.call("prepare", ["session": "local_a"])?.isError == true)
        #expect(gate(t, to: "Fix the login bug", message: "Bump the version.").allow == false)
    }

    @Test func aLongMessagesPreviewsPass() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout: first line of a longer note that goes past sixty characters for sure, yes\nsecond line")
        let text = "first line of a longer note that goes past sixty characters for sure, yes\nsecond line"
        t.rephrase = { message, _, _ in Prepared(text: text, original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        #expect(t.approveSend(claudeInput("Fix the login bug", sealed(t, "Fix the login bug", text)), otherFields: []) == nil)
    }

    @Test func aLatePrepareFromAnEarlierTurnLeavesTheNewOneAlone() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        let held = RouterGate()
        t.afterLookup = { await held.wait() }
        let late = Task { await t.call("prepare", ["session": "local_a"]) }
        while !held.waiting { await Task.yield() }
        // The turn ends; the next one prepares the same target.
        t.endTurn()
        t.beginTurn("tell lookout to tag the release")
        t.afterLookup = nil
        t.rephrase = { message, _, _ in Prepared(text: "Tag the release.", original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        held.open()
        #expect(await late.value?.isError == true)
        #expect(t.prepared["Fix the login bug"]?.body == "Tag the release.")
    }

    @Test func aBatchHasOneTicketSoItsLaterEntriesCantActAfterAStop() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        let held = RouterGate()
        t.chooser = { options, _, _, _ in
            await held.wait()
            return JevClient.Choice(choice: options[0], confidence: 1, probabilities: [options[0]: 1])
        }
        let body = try JSONSerialization.data(withJSONObject: [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "route", "arguments": ["message": "x"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "mark", "arguments": ["card": "local_a#w500", "addressed": true]]],
        ])
        // As the server does: one ticket when the request comes.
        let ticket = t.ticket()
        let answering = Task { await RouterRPC.handle(body, tools: RouterTools.specs) { name, args in await t.call(name, args, ticket: ticket) } }
        while !held.waiting { await Task.yield() }
        t.endTurn()
        t.beginTurn("a new message")
        held.open()
        let replies = try #require(json(await answering.value.body) as? [[String: Any]])
        #expect(replies.allSatisfy { ($0["result"] as? [String: Any])?["isError"] as? Bool == true })
        #expect(s.router.cards[0].isOpen)
    }

    @Test func nothingActsInATurnASessionStarted() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: nil)
        #expect(await t.call("mark", ["card": "local_a#w500", "addressed": true])?.text == "Only the user's messages make the Router act")
        #expect(s.router.cards[0].isOpen)
        #expect(t.approveSend(["to": "Fix the login bug", "message": "x"], otherFields: []) != nil)
        // Reading still works.
        #expect(await t.call("board", [:])?.isError == false)
    }

    @Test func aFailedPrepareSendsNothingAndRemembersNothing() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        t.beginTurn("hi")
        t.rephrase = { _, _, _ in throw RouterTools.Failure("Couldn't prepare the message (No answer in 20 s); nothing was sent") }
        let out = try #require(await t.call("prepare", ["session": "local_a"]))
        #expect(out.isError && out.text.contains("nothing was sent") && t.prepared.isEmpty)
        // Without a binary (a test has none) and without a stand-in, it's an error too.
        t.rephrase = nil
        #expect(await t.call("prepare", ["session": "local_a"])?.text.contains("Claude Code wasn't found") == true)
    }

    @Test func startingPreparesFirstThenStartsAndHandsBackThePeer() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var started = 0
        t.starter = { _, title in
            started += 1
            return SessionStart.Started(sessionID: "local_new", peer: title)
        }
        t.beginTurn("start a session in lookout to bump the version")
        // Haiku fails: no session is made.
        t.rephrase = { _, _, _ in throw RouterTools.Failure("Couldn't prepare the message") }
        #expect(await t.call("start_session", ["project": "lookout", "title": "Bump the version"])?.isError == true)
        #expect(started == 0)
        t.rephrase = { message, title, project in
            #expect(title == "Bump the version" && project == "lookout" && message == "start a session in lookout to bump the version")
            return Prepared(text: "Bump the version.", original: message, rephrased: true)
        }
        let out = try #require(await t.call("start_session", ["project": "lookout", "title": "  Bump the\nversion "]))
        let result = try #require(json(Data(out.text.utf8)) as? [String: Any])
        #expect(result["session"] as? String == "local_new" && result["peer"] as? String == "Bump the version")
        // Signed for the new session (its Claude Code id is the bootstrap's uuid).
        #expect((result["text"] as? String)?.hasPrefix("⟦lookout v1 new ") == true && started == 1)
        #expect(t.prepared["Bump the version"]?.newSessionIn == "lookout")
        #expect(gate(t, to: "Bump the version", message: "Bump the version.").allow)
        #expect(await t.call("start_session", ["project": "lookout"])?.text == "Missing `title`")
    }

    @Test func stoppingVoidsAStartWaitingOnHaiku() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        let held = RouterGate()
        var started = 0
        t.starter = { _, title in
            started += 1
            return SessionStart.Started(sessionID: "local_new", peer: title)
        }
        t.rephrase = { message, _, _ in
            await held.wait()
            return Prepared(text: message, original: message, rephrased: false)
        }
        t.beginTurn("start a session in lookout to bump the version")
        let starting = Task { await t.call("start_session", ["project": "lookout", "title": "Bump"]) }
        while !held.waiting { await Task.yield() }
        t.endTurn()
        held.open()
        let out = await starting.value
        #expect(out?.isError == true && out?.text.contains("Stopped") == true)
        #expect(started == 0 && t.prepared.isEmpty)
    }

    @Test func taggedProjectsNarrowTheRoute() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s)
        var offered: [String: String] = [:]
        t.chooser = { options, hints, _, _ in
            offered = hints
            return JevClient.Choice(choice: options[0], confidence: 1, probabilities: [options[0]: 1])
        }
        _ = try await route(t, ["message": "add badges", "projects": ["/code/api"]])
        #expect(offered.values.allSatisfy { !$0.contains("lookout") })
        #expect(offered.values.contains { $0.contains("Write the README") })
        #expect(await t.call("route", ["message": "x", "projects": ["nowhere"]])?.isError == true)
        #expect(await t.call("route", ["message": "x", "projects": "api"])?.isError == true)
    }

    /// Claude Code's own input for a SendMessage of `message`, as 2.1.293 builds it (captured from the binary).
    private func asked(_ to: String, _ message: String, summary: String, content: String) -> [String: String] {
        ["to": to, "message": message, "summary": summary, "type": "message", "recipient": to, "recipient_kind": "name",
         "content": content]
    }

    /// The same, with its previews derived as Claude Code does.
    private func claudeInput(_ to: String, _ message: String) -> [String: String] {
        asked(to, message, summary: RouterTools.summary(of: message),
              content: message.count > 50 ? String(message.prefix(49)) + "…" : message)
    }

    /// The signed text prepare made for `to` when its body is `body`.
    private func sealed(_ t: RouterTools, _ to: String, _ body: String) -> String {
        guard let ready = t.prepared[to], ready.body == body else { return body }
        return ready.text
    }

    @Test func indentedCodeIsLetThroughWithClaudeCodesOwnPreviews() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let code = "    let x = 1\n    let y = 2"
        let t = tools(s, turn: "tell lookout:\n" + code)
        t.rephrase = { message, _, _ in Prepared(text: code, original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        // Claude Code's previews of the signed text pass; the body, indent and all, is what was prepared.
        let signed = sealed(t, "Fix the login bug", code)
        #expect(signed.hasSuffix("\n" + Data(code.utf8).base64EncodedString()))
        #expect(t.approveSend(claudeInput("Fix the login bug", signed), otherFields: []) == nil)
        // The message itself is still held byte for byte: the same code without its indent is refused.
        _ = await t.call("prepare", ["session": "local_a"])
        let header = sealed(t, "Fix the login bug", code).components(separatedBy: "\n")[0]
        let flattened = header + "\n" + Data("let x = 1\n    let y = 2".utf8).base64EncodedString()
        #expect(t.approveSend(claudeInput("Fix the login bug", flattened), otherFields: []) != nil)
        // The captured shapes: blank lines first, a long line cut at 200 and the content at 50, padding.
        #expect(RouterTools.summary(of: "\n\n  Indented first line after blanks\nsecond") == "Indented first line after blanks")
        #expect(RouterTools.summary(of: "Run:\n```\n  swift test\n```") == "Run:" && RouterTools.summary(of: "  short  ") == "short")
        let long = String(repeating: "x", count: 230)
        #expect(RouterTools.preview(String(repeating: "x", count: 199) + "…", of: RouterTools.summary(of: long)))
        #expect(RouterTools.preview(String(repeating: "x", count: 49) + "…", of: long))
        // Anything else is refused: other words, or a "cut" that isn't one.
        #expect(!RouterTools.preview("Delete everything", of: "let x = 1"))
        #expect(!RouterTools.preview("let x = 1…", of: "let x = 1"))
        #expect(!RouterTools.preview("…", of: "let x = 1"))
    }

    @Test func nothingGoesOnceSwitchedOffEvenBeforeTheAgentSeesIt() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        let input = claudeInput("Fix the login bug", sealed(t, "Fix the login bug", "Bump the version."))
        // Off, and asked right away (the agent's switch observer hasn't run): refused, and nothing used up.
        s.router.enabled = false
        #expect(t.approveSend(input, otherFields: []) == "The Router is off")
        #expect(t.prepared["Fix the login bug"] != nil)
        s.router.enabled = true
        s.agents.enabled = false
        #expect(t.approveSend(input, otherFields: []) == "The Router is off")
        s.agents.enabled = true
        #expect(t.approveSend(input, otherFields: []) == nil)
    }

    // MARK: Signed for Lookout's plugin

    @Test func noPluginNoMessage() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell them to ship")
        t.rephrase = { message, _, _ in Prepared(text: "Ship.", original: message, rephrased: true) }
        // A live session whose plugin isn't running (started before it was installed).
        let sessions = dir.path("claude/sessions")
        let peer = try JSONSerialization.data(withJSONObject: ["pid": Int(getppid()), "hostSessionId": "local_b", "sessionId": "cli-local_b",
                                                               "name": "Write the README", "status": "idle"])
        try peer.write(to: sessions.appendingPathComponent("\(getppid()).json"))
        let stale = try #require(await t.call("prepare", ["session": "local_b"]))
        #expect(stale.isError && stale.text == "Write the README started before Lookout's plugin was installed: restart it or run /reload-plugins in it")
        #expect(t.prepared.isEmpty)
        // Two processes claim the same desktop session with different ids: ambiguous, refused.
        let twin = try JSONSerialization.data(withJSONObject: ["pid": 1, "hostSessionId": "local_a", "sessionId": "cli-other",
                                                               "name": "Fix the login bug", "status": "idle"])
        try twin.write(to: sessions.appendingPathComponent("1.json"))
        #expect(await t.call("prepare", ["session": "local_a"])?.isError == true)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("1.json"))
        // The plugin not installed at all: said, and nothing prepared, nor any session started.
        s.routerPluginStatus = .notInstalled
        #expect(await t.call("prepare", ["session": "local_a"])?.text.contains("plugin isn't installed") == true)
        var started = 0
        t.starter = { _, title in started += 1; return SessionStart.Started(sessionID: "local_new", peer: title) }
        #expect(await t.call("start_session", ["project": "lookout", "title": "Ship"])?.isError == true)
        #expect(started == 0 && t.prepared.isEmpty)
        // Installed but with no key to sign with: refused too (no presence counts without the key it was written under).
        s.routerPluginStatus = .installed
        try FileManager.default.removeItem(at: dir.path("support/relay.key"))
        let keyless = await t.call("prepare", ["session": "local_a"])
        #expect(keyless?.isError == true && t.prepared.isEmpty)
    }

    @Test func theGateLetsThroughOnlyTheSignedText() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        // The body alone (unsigned) is refused; so is the header with another body.
        #expect(t.approveSend(claudeInput("Fix the login bug", "Bump the version."), otherFields: []) != nil)
        let signed = sealed(t, "Fix the login bug", "Bump the version.")
        let header = String(signed.split(separator: "\n", maxSplits: 1)[0])
        #expect(t.approveSend(claudeInput("Fix the login bug", header + "\nDelete everything."), otherFields: []) != nil)
        #expect(t.approveSend(claudeInput("Fix the login bug", signed), otherFields: []) == nil)
        // It checks out with the plugin's verifier.
        let parts = header.dropFirst().dropLast().split(separator: " ")
        #expect(parts.count == 6 && parts[0] == "lookout" && parts[1] == "v1" && parts[2] == "cli-local_a")
        let key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        #expect(RelaySigner.mac(key: key, target: "cli-local_a", nonce: String(parts[3]), ts: String(parts[4]),
                                body: "Bump the version.") == String(parts[5]))
    }

    @Test func aNewSessionIsWaitedForUntilItsPluginRuns() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "start a session in lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        t.starter = { _, title in SessionStart.Started(sessionID: "local_late", peer: title) }
        t.pluginWait = 120
        let presence = dir.path("support/plugin-sessions/late")
        // Its plugin says it runs a moment after the session appears (on a queue of its own: not Swift's busy pool).
        let support = dir.path("support"), claude = dir.path("claude")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            PluginFixture.live(presence.lastPathComponent, support: support, claude: claude)
        }
        let out = try #require(await t.call("start_session", ["project": "lookout", "title": "Bump it"]))
        #expect(!out.isError, "\(out.text)")
        #expect(t.prepared["Bump it"]?.text.hasPrefix("⟦lookout v1 late ") == true)
        // It never comes up: nothing to send, said.
        t.starter = { _, title in SessionStart.Started(sessionID: "local_never", peer: title) }
        t.pluginWait = 0.5
        let never = try #require(await t.call("start_session", ["project": "lookout", "title": "Never"]))
        #expect(never.isError && never.text.contains("plugin didn't come up") && t.prepared["Never"] == nil)
    }

    @Test func theWireTextIsComparedByteForByte() {
        // Equal as Swift strings (canonically equivalent), not the same bytes: not the prepared text.
        #expect("caf\u{E9}" == "cafe\u{301}")
        #expect(!RouterTools.sameBytes("caf\u{E9}", "cafe\u{301}"))
        #expect(RouterTools.sameBytes("caf\u{E9}", "caf\u{E9}"))
    }

    @Test func aBodyInAnotherUnicodeFormIsNotThePreparedOne() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let nfc = "Rename it to caf\u{E9}", nfd = "Rename it to cafe\u{301}"
        let t = tools(s, turn: "tell lookout: " + nfc)
        t.rephrase = { message, _, _ in Prepared(text: nfc, original: message, rephrased: true) }
        _ = await t.call("prepare", ["session": "local_a"])
        let signed = sealed(t, "Fix the login bug", nfc)
        let header = signed.components(separatedBy: "\n")[0]
        // The same words as Swift sees them, other bytes: refused, and the preparation stays for the real one.
        let other = header + "\n" + Data(nfd.utf8).base64EncodedString()
        #expect(t.approveSend(claudeInput("Fix the login bug", other), otherFields: []) != nil)
        #expect(t.approveSend(claudeInput("Fix the login bug", signed), otherFields: []) == nil)
        // Shown as the body, never the wire.
        #expect(RouterAgent.withoutRelayHeader(signed) == nfc)
        #expect(!RouterAgent.withoutRelayHeader("Sent:\n" + signed).contains(Data(nfc.utf8).base64EncodedString()))
    }

    @Test func aKeyNotReadYetOrChangedIsReadAgainBeforeSigning() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        // What's tested is that the key is read again, not how fast: a deadline no loaded machine can miss.
        t.keyReloadWait = 120
        func verifies(_ key: String) -> Bool {
            let signed = sealed(t, "Fix the login bug", "Bump the version.")
            let parts = signed.components(separatedBy: "\n")[0].dropFirst().dropLast().split(separator: " ")
            return parts.count == 6 && RelaySigner.mac(key: key, target: "cli-local_a", nonce: String(parts[3]), ts: String(parts[4]),
                                                       body: "Bump the version.") == String(parts[5])
        }
        // The first prepare: nothing cached yet, read then, and signed.
        s.relayKeyCache = nil
        let first = try #require(await t.call("prepare", ["session": "local_a"]))
        #expect(!first.isError, "\(first.text)")
        #expect(verifies("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"))
        // The key changes on disk: the next prepare reads the new one and signs with it.
        let newKey = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
        try FileManager.default.removeItem(at: dir.path("support/relay.key"))
        try Data(newKey.utf8).write(to: dir.path("support/relay.key"))
        // (The session's plugin takes the new key too.)
        PluginFixture.live("cli-local_a", support: dir.path("support"), claude: dir.path("claude"))
        let second = try #require(await t.call("prepare", ["session": "local_a"]))
        #expect(!second.isError, "\(second.text)")
        #expect(verifies(newKey))
        // No key at all: refused, nothing prepared.
        try FileManager.default.removeItem(at: dir.path("support/relay.key"))
        #expect(await t.call("prepare", ["session": "local_a"])?.isError == true)
        #expect(t.prepared.isEmpty)
    }

    @Test func aStalledKeyReadDoesntHoldThePrepare() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "tell lookout to bump the version")
        t.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        let held = RouterGate()
        t.keyReload = { await held.wait(); return false }
        t.keyReloadWait = 0.05
        s.relayKeyCache = nil
        // The read never finishes, yet the prepare returns (signed if the store's own read got there, else refused).
        let out = try #require(await t.call("prepare", ["session": "local_a"]))
        #expect(out.isError ? out.text.contains("couldn't sign") : t.prepared["Fix the login bug"] != nil)
        // Its reload did start (it may start after the deadline already passed): waited for, then let go.
        await waitUntil(within: 120) { held.waiting }
        #expect(held.waiting)
        // The race itself ends by its deadline, whatever the loser does: it says which side won (no timing measured).
        // Its deadline armed once the work is under way, so this is the deadline beating work that has started.
        let stuck = RouterGate()
        let deadlineWon = await RouterTools.race(deadline: 0.05, armWhenStarted: true) { await stuck.wait() }
        #expect(deadlineWon && stuck.waiting)
        #expect(await RouterTools.race(deadline: 30) {} == false)
        held.open()
        stuck.open()
        // Odd spans are made safe to compute with.
        #expect(RouterTools.bounded(.infinity) == 0 && RouterTools.bounded(-.greatestFiniteMagnitude) == 0)
        #expect(RouterTools.bounded(.greatestFiniteMagnitude) == 365 * 86_400 && RouterTools.bounded(.nan) == 0)
    }

    // MARK: One answer per form

    private func answer(_ dir: TempDir) throws -> [String: String]? {
        let file = FormBridge.answerURL("cli-local_a-1-1", in: dir.path("support/forms"))
        return (json(try Data(contentsOf: file)) as? [String: Any])?["answers"] as? [String: String]
    }

    @Test func yourAnswerOnTheCardStandsAgainstALateRouterAnswer() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "answer sqlite")
        let form = try #require(s.pendingForms["cli-local_a"])
        // You click Postgres on the card; the Router's answer comes after.
        try await FormWriter.write(form, answers: ["Which database?": "Postgres"], dir: dir.path("support/forms"))
        let late = try #require(await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]]))
        #expect(late.isError && late.text.contains("Already answered"))
        #expect(try answer(dir) == ["Which database?": "Postgres"])
    }

    @Test func theRoutersAnswerStandsAgainstALateClickOnTheCard() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let t = tools(s, turn: "answer sqlite")
        let form = try #require(s.pendingForms["cli-local_a"])
        #expect(await t.call("answer_form", ["card": "local_a#w500", "answers": ["db": "SQLite"]])?.isError == false)
        await #expect(throws: FormWriter.AlreadyAnswered.self) {
            try await FormWriter.write(form, answers: ["Which database?": "Postgres"], dir: dir.path("support/forms"))
        }
        #expect(try answer(dir) == ["Which database?": "SQLite"])
    }

    @Test func anAnswerFileAlreadyThereIsNeverReplaced() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let form = try #require(s.pendingForms["cli-local_a"])
        // Written by another path (not through the writer): still not overwritten.
        try FormBridge.answer(form, answers: ["Which database?": "Postgres"], in: dir.path("support/forms"))
        await #expect(throws: FormWriter.AlreadyAnswered.self) {
            try await FormWriter.write(form, answers: ["Which database?": "SQLite"], dir: dir.path("support/forms"))
        }
        #expect(try answer(dir) == ["Which database?": "Postgres"])
        // No temporary file is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path("support/forms").path).filter { $0.hasSuffix(".tmp") }
        #expect(left.isEmpty)
    }

    @Test func aWriteCancelledWhileQueuedWritesNothing() async throws {
        let dir = TempDir()
        let s = await store(dir)
        let form = try #require(s.pendingForms["cli-local_a"])
        let forms = dir.path("support/forms")
        // The writer is busy: this answer waits behind it, still valid, and its task is cancelled meanwhile.
        let hold = DispatchSemaphore(value: 0)
        FormWriter.queue.async { hold.wait() }
        let writing = Task { try await FormWriter.write(form, answers: ["Which database?": "SQLite"], dir: forms) }
        try await Task.sleep(nanoseconds: 100_000_000)
        writing.cancel()
        hold.signal()
        await #expect(throws: FormWriter.Cancelled.self) { try await writing.value }
        #expect(!FileManager.default.fileExists(atPath: FormBridge.answerURL(form.id, in: forms).path))
        // The form is still free for the next answer.
        try await FormWriter.write(form, answers: ["Which database?": "Postgres"], dir: forms)
        #expect(try answer(dir) == ["Which database?": "Postgres"])
    }
}

/// Holds an async call until the test lets it go.
@MainActor final class RouterGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
