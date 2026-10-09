import Foundation
import Testing
@testable import Lookout

/// The Router's process as far as it can be tested without running it: finding Claude Code, its arguments, and what its
/// stream-json output turns into in the chat.
@MainActor
@Suite struct RouterAgentTests {
    private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    // MARK: Finding Claude Code

    @Test func theNewestBundledCopyIsUsed() throws {
        let dir = TempDir()
        func install(_ version: String, _ hash: String, executable: Bool = true) {
            let bin = dir.url.appendingPathComponent("\(version)/\(hash)/claude.app/Contents/MacOS")
            try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent("claude")
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        }
        #expect(RouterAgent.find(in: dir.url) == nil)
        install("2.1.29", "aaa")
        install("2.1.293", "bbb")
        install("2.1.3", "ccc")
        install("2.2.0", "ddd", executable: false)
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("3.0.0"), withIntermediateDirectories: true)
        let found = try #require(RouterAgent.find(in: dir.url))
        #expect(found.version == "2.1.293")
        #expect(found.path == dir.url.appendingPathComponent("2.1.293/bbb/claude.app/Contents/MacOS/claude").path)
        #expect(RouterAgent.compare("2.1.293", "2.1.29") == .orderedDescending)
        #expect(RouterAgent.compare("2.1", "2.1.0") == .orderedSame)
        #expect(RouterAgent.compare("1.9.9", "2.0") == .orderedAscending)
    }

    @Test func itRunsWithOnlyItsToolsAndResumesItsConversation() {
        let args = RouterAgent.arguments(config: "/r/mcp.json", settings: "/r/settings.json", resume: nil)
        #expect(Array(args.prefix(6)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        func value(_ flag: String, _ args: [String]) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value("--tools", args) == "ListAgents,SendMessage")
        // SendMessage isn't pre-allowed: Lookout's gate (the PreToolUse hook in --settings) decides each one.
        #expect(value("--allowedTools", args) == "ListAgents,mcp__lookout")
        #expect(value("--settings", args) == "/r/settings.json")
        #expect(value("--name", args) == "Lookout" && value("--setting-sources", args) == "")
        // Permission prompts come to Lookout over stdin (the native path, which fails closed).
        #expect(value("--permission-mode", args) == "manual" && value("--permission-prompt-tool", args) == "stdio")
        #expect(!args.contains("--permission-prompts"))
        #expect(value("--mcp-config", args) == "/r/mcp.json" && args.contains("--strict-mcp-config"))
        #expect(value("--append-system-prompt", args) == RouterPrompt.role)
        #expect(!args.contains("--resume"))
        #expect(value("--resume", RouterAgent.arguments(config: "/r/mcp.json", settings: "/s", resume: "abc")) == "abc")
    }

    @Test func everySendMessageAsksAndTheAnswerGoesBackOnStdin() throws {
        let settings = try #require(try JSONSerialization.jsonObject(with: RouterAgent.gateSettings()) as? [String: Any])
        #expect((settings["permissions"] as? [String: Any])?["ask"] as? [String] == ["SendMessage"])
        let request = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": "r-1", "request": [
            "subtype": "can_use_tool", "tool_name": "SendMessage",
            "input": ["to": "a", "message": "hi", "notify_when_idle": true]]])
        #expect(RouterStream.parse(request) == [.permission(id: "r-1", tool: "SendMessage", input: ["to": "a", "message": "hi"],
                                                            otherFields: ["notify_when_idle"])])
        let allow = try #require(try JSONSerialization.jsonObject(with: RouterStream.permissionLine(id: "r-1", allow: ["to": "a", "message": "hi"])) as? [String: Any])
        let response = try #require(allow["response"] as? [String: Any])
        #expect(allow["type"] as? String == "control_response" && response["request_id"] as? String == "r-1")
        #expect(response["response"] as? NSDictionary == ["behavior": "allow", "updatedInput": ["to": "a", "message": "hi"]] as NSDictionary)
        let deny = try #require(try JSONSerialization.jsonObject(with: RouterStream.permissionLine(id: "r-2", allow: nil, deny: "No")) as? [String: Any])
        #expect((deny["response"] as? [String: Any])?["response"] as? [String: String] == ["behavior": "deny", "message": "No"])
    }

    // MARK: stream-json

    @Test func stdinLinesAreOneJSONObjectEach() throws {
        let user = RouterStream.userLine("hi \"there\"\nsecond line")
        #expect(user.last == 0x0A && user.dropLast().firstIndex(of: 0x0A) == nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: user) as? [String: Any])
        #expect(obj["type"] as? String == "user")
        #expect((obj["message"] as? [String: Any])?["content"] as? String == "hi \"there\"\nsecond line")
        let stop = try #require(try JSONSerialization.jsonObject(with: RouterStream.interruptLine(id: "r1")) as? [String: Any])
        #expect(stop["type"] as? String == "control_request" && stop["request_id"] as? String == "r1")
        #expect((stop["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
    }

    @Test func outputIsCutIntoLines() {
        var buffer = Data("{\"a\":1}\n\n{\"b\"".utf8)
        #expect(RouterStream.lines(&buffer) == [Data("{\"a\":1}".utf8)])
        #expect(buffer == Data("{\"b\"".utf8))
        buffer.append(Data(":2}\n".utf8))
        #expect(RouterStream.lines(&buffer) == [Data("{\"b\":2}".utf8)] && buffer.isEmpty)
    }

    @Test func eventsAreReadFromTheLinesThatMatter() {
        #expect(RouterStream.parse(line(["type": "system", "subtype": "init", "session_id": "s1", "tools": ["SendMessage"]]))
            == [.started(sessionID: "s1")])
        #expect(RouterStream.parse(line(["type": "system", "subtype": "post_turn_summary", "session_id": "s1"])).isEmpty)
        #expect(RouterStream.parse(line(["type": "rate_limit_event"])).isEmpty)
        #expect(RouterStream.parse(Data("not json".utf8)).isEmpty)
        let assistant = line(["type": "assistant", "message": ["content": [
            ["type": "text", "text": " Sent. \n"],
            ["type": "thinking", "thinking": "hmm"],
            ["type": "tool_use", "id": "t1", "name": "SendMessage", "input": ["to": "lookout", "message": "run the tests", "n": 3]],
            ["type": "tool_use", "id": "t2", "name": "mcp__lookout__mark", "input": ["card": "c1", "addressed": false]],
        ]]])
        #expect(RouterStream.parse(assistant) == [
            .text("Sent."),
            .toolUse(id: "t1", name: "SendMessage", input: ["to": "lookout", "message": "run the tests"]),
            .toolUse(id: "t2", name: "mcp__lookout__mark", input: ["card": "c1", "addressed": "false"]),
        ])
        let results = line(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "Sent", "is_error": false],
            ["type": "tool_result", "tool_use_id": "t2", "content": [["type": "text", "text": "No card c1"]], "is_error": true],
            ["type": "text", "text": "[Request interrupted by user]"],
        ]]])
        #expect(RouterStream.parse(results) == [.toolResult(id: "t1", isError: false, text: "Sent"),
                                                .toolResult(id: "t2", isError: true, text: "No card c1")])
        #expect(RouterStream.parse(line(["type": "result", "subtype": "success", "is_error": false, "result": "Sent."]))
            == [.result(isError: false, text: "Sent.")])
        #expect(RouterStream.parse(line(["type": "result", "subtype": "error_during_execution", "is_error": true,
                                         "errors": ["[ede_diagnostic] result_type=user", "No conversation found"]]))
            == [.result(isError: true, text: "No conversation found")])
    }

    @Test func aSessionWritingBackIsAPeerLine() {
        let text = "<cross-session-message from=\"uds:/tmp/x.sock\" from-name=\"Fix the login bug\">\nTests pass now.\n</cross-session-message>"
        #expect(RouterStream.parse(line(["type": "user", "message": ["role": "user", "content": text]]))
            == [.peer(from: "Fix the login bug", text: "Tests pass now.")])
        #expect(RouterStream.peer("<cross-session-message from=\"abc\">hi</cross-session-message>") == .peer(from: "abc", text: "hi"))
        #expect(RouterStream.peer("plain text") == nil)
    }

    // MARK: The chat

    /// A store with the Router on, its files in `dir`, two sessions and a card each. Peers: `local_a` runs as "Lookout dev"
    /// (not its title), and two processes are both called "Twin".
    private func store(_ dir: TempDir) -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.agents.enabled = true
        s.router.enabled = true
        s.claudeSessions = [
            "local_a": ClaudeSession(id: "local_a", title: "Fix the login bug", folder: "/code/lookout", lastActivity: Date(), running: true),
            "local_b": ClaudeSession(id: "local_b", title: "Docs", folder: "/code/lookout", lastActivity: Date()),
        ]
        s.router.cards = [
            RouterCard(id: "local_a#t1", sessionID: "local_a", kind: .done, title: "Fix the login bug", folder: "/code/lookout",
                       text: "Done", createdAt: Date()),
            RouterCard(id: "local_b#t1", sessionID: "local_b", kind: .done, title: "Docs", folder: nil, text: "Done", createdAt: Date()),
            RouterCard(id: "local_c#t1", sessionID: "local_c", kind: .done, title: "Twin", folder: nil, text: "Done", createdAt: Date()),
        ]
        let sessions = dir.path("claude/sessions")
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        func peer(_ pid: Int32, _ host: String, _ name: String) {
            let data = try! JSONSerialization.data(withJSONObject: ["pid": Int(pid), "hostSessionId": host, "sessionId": "cli-\(host)",
                                                                    "name": name, "status": "idle"])
            try? data.write(to: sessions.appendingPathComponent("\(pid).json"))
        }
        // Lookout's plugin: installed, its key made, running in every session here (and a new one, "new").
        s.routerPluginStatus = .installed
        try? FileManager.default.createDirectory(at: dir.path("support/plugin-sessions"), withIntermediateDirectories: true)
        try? Data("0123456789abcdef0123456789abcdef".utf8).write(to: dir.path("support/relay.key"))
        PluginFixture.useKey(s)
        for cli in ["cli-local_a", "cli-local_c", "cli-local_d", "new"] {
            PluginFixture.live(cli, support: dir.path("support"), claude: dir.path("claude"))
        }
        peer(getpid(), "local_a", "Lookout dev")
        peer(getppid(), "local_c", "Twin")
        peer(1, "local_d", "Twin")
        return s
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<1000 where !until() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func aTurnBecomesChatLinesReceiptsAndAddressedCards() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.tools.rephrase = { message, _, _ in Prepared(text: message, original: message, rephrased: false) }
        agent.tools.beginTurn("Use Postgres\nand ship")
        #expect(await agent.tools.call("prepare", ["session": "Lookout dev"])?.isError == false)
        let sent = sealed(agent, "Lookout dev")
        pass(agent, to: "Lookout dev", message: sent)
        agent.apply([
            .started(sessionID: "cli-router"),
            .toolUse(id: "t0", name: "mcp__lookout__board", input: [:]),
            .toolResult(id: "t0", isError: false, text: "{}"),
            .toolUse(id: "t1", name: "SendMessage", input: ["to": "Lookout dev", "message": sent]),
            .toolResult(id: "t1", isError: false, text: "Sent"),
            .toolUse(id: "t2", name: "mcp__lookout__start_session", input: ["project": "api", "prompt": "Hi"]),
            .toolResult(id: "t2", isError: true, text: "Unknown project “api”. Projects: lookout"),
        ])
        #expect(agent.phase == .working)
        #expect(s.router.claudeSessionID == "cli-router")
        // Lookout writes the receipt; the Router adds nothing of its own (see the role).
        let chat = s.router.chat.map { "\($0.role.rawValue): \($0.text)" }
        #expect(chat == ["receipt: → Lookout dev: Use Postgres", "error: start_session: Unknown project “api”. Projects: lookout"])
        // The peer name isn't the session's title: Claude Code's registry says which session it is.
        await settle { s.router.chat[0].sessionID != nil }
        #expect(s.router.chat[0].sessionID == "local_a")
        #expect(s.router.cards.first { $0.id == "local_a#t1" }?.addressedBy == .router)
        #expect(s.router.cards.first { $0.id == "local_b#t1" }?.isOpen == true)

        agent.apply([.result(isError: false, text: "done")])
        #expect(agent.phase == .idle)
        agent.apply([.result(isError: true, text: "API Error: overloaded")])
        #expect(s.router.chat.last?.role == .error && s.router.chat.last?.text == "API Error: overloaded")
    }

    @Test func aMessageToNoOneOrToSeveralAddressesNothing() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        // "Docs" is a title but no peer's name; "Twin" is two peers.
        agent.apply([
            .toolUse(id: "t1", name: "SendMessage", input: ["to": "Docs", "message": "hi"]),
            .toolResult(id: "t1", isError: false, text: "Sent"),
            .toolUse(id: "t2", name: "SendMessage", input: ["to": "Twin", "message": "hi"]),
            .toolResult(id: "t2", isError: false, text: "Sent"),
        ])
        #expect(s.router.chat.filter { $0.role == .receipt }.map(\.text) == ["→ Docs: hi", "→ Twin: hi"])
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.router.chat.allSatisfy { $0.sessionID == nil })
        #expect(s.router.cards.allSatisfy { $0.isOpen })
        // "name [ref]" tells the twins apart.
        agent.apply([.toolUse(id: "t3", name: "SendMessage", input: ["to": "Twin [local_c]", "message": "hi"]),
                     .toolResult(id: "t3", isError: false, text: "Sent")])
        await settle { s.router.chat.last?.sessionID != nil }
        #expect(s.router.chat.last?.sessionID == "local_c")
        #expect(s.router.cards.first { $0.id == "local_c#t1" }?.addressedBy == .router)
    }

    @Test func peerNamesResolveOnlyWhenCertain() {
        let peers: [String: ClaudePeers.Peer] = [
            "local_a": .init(name: "Lookout dev", status: "idle", pid: 10),
            "local_b": .init(name: "Twin", status: "idle", pid: 11),
            "local_c": .init(name: "Twin", status: "busy", pid: 12),
            "local_d": .init(name: "Odd [x]", status: "idle", pid: 13),
        ]
        #expect(RouterAgent.peerSession("Lookout dev", peers: peers) == "local_a")
        #expect(RouterAgent.peerSession("Lookout dev [10]", peers: peers) == "local_a")
        #expect(RouterAgent.peerSession("Twin", peers: peers) == nil)
        #expect(RouterAgent.peerSession("Twin [12]", peers: peers) == "local_c")
        #expect(RouterAgent.peerSession("Twin [99]", peers: peers) == nil)
        #expect(RouterAgent.peerSession("Odd [x]", peers: peers) == "local_d")
        #expect(RouterAgent.peerSession("lookout dev", peers: peers) == nil)
        #expect(RouterAgent.peerSession("Nobody", peers: peers) == nil)
    }

    @Test func aSessionWritingInIsOneLineAndTheRouterKeepsQuiet() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.apply([.started(sessionID: "cli-router"), .peer(from: "Lookout dev", text: "Tests pass now."),
                     .text("Lookout dev reports the tests pass."), .result(isError: false, text: "")])
        #expect(s.router.chat.map(\.role) == [.peer])
        #expect(agent.phase == .idle)
        await settle { s.router.chat[0].sessionID != nil }
        #expect(s.router.chat[0].sessionID == "local_a" && s.router.chat[0].text == "Tests pass now.")
        // An unknown sender keeps its name in the line.
        agent.apply([.peer(from: "Stranger", text: "Hello"), .result(isError: false, text: "")])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(s.router.chat.last?.text == "Stranger: Hello" && s.router.chat.last?.sessionID == nil)
        // Your own turn speaks as usual, and its result is yours.
        agent.apply([.text("Hi there."), .result(isError: false, text: "")])
        #expect(s.router.chat.last?.role == .router)
    }

    @Test func receiptsSayWhatWasDone() {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        #expect(agent.receipt("mcp__lookout__answer_form", ["card": "local_a#t1"])?.text == "→ answered Fix the login bug")
        #expect(agent.receipt("mcp__lookout__start_session", ["project": "lookout"]) == nil)
        #expect(agent.receipt("mcp__lookout__open_session", ["session": "local_a"])?.text == "→ opened Fix the login bug")
        #expect(agent.receipt("mcp__lookout__mark", ["card": "local_b#t1", "addressed": "false"])?.text == "→ reopened Docs")
        #expect(agent.receipt("mcp__lookout__mark", ["card": "local_b#t1", "addressed": "true"])?.text == "→ marked Docs addressed")
        #expect(agent.receipt("mcp__lookout__board", [:]) == nil && agent.receipt("ListAgents", [:]) == nil)
        let long = String(repeating: "x", count: 300)
        #expect(agent.receipt("SendMessage", ["to": "Docs", "message": long])?.text.count == "→ Docs: ".count + 120)
    }

    @Test func theRoleLeavesReceiptsAndReportsToLookout() {
        #expect(RouterPrompt.role.contains("Lookout shows a receipt for every action you take. After acting, say nothing unless something needs the user (an error, a question, a refusal)."))
        #expect(RouterPrompt.role.contains("Messages from sessions are shown to the user by Lookout; don't reply to them or summarise them."))
        #expect(!RouterPrompt.role.contains("reply with one receipt line"))
    }

    @Test func aNewConversationClearsTheChatAndTheSessionToResume() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.apply([.started(sessionID: "cli-router"), .text("Hello")])
        #expect(!s.router.chat.isEmpty)
        agent.newConversation()
        #expect(s.router.chat.isEmpty && s.router.claudeSessionID == nil && agent.phase == .idle)
        // Not found (a test has no Claude app): sending says so and fails, ready to try again.
        agent.send("hello")
        await settle { if case .failed = agent.phase { return true }; return false }
        #expect(s.router.chat.map(\.role) == [.you, .error])
        guard case .failed = agent.phase else { Issue.record("not failed"); return }
    }

    @Test func nothingIsSentWhileTheRouterOrTheSessionsAreOff() {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        s.router.enabled = false
        agent.send("hello")
        s.router.enabled = true
        s.agents.enabled = false
        agent.send("hello")
        #expect(s.router.chat.isEmpty && agent.phase == .idle)
    }

    @Test func theChatIsPruned() {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        s.router.chat = (0..<RouterFeed.maxChat).map { RouterMessage(role: .router, text: "\($0)", date: Date()) }
        agent.apply([.text("latest")])
        #expect(s.router.chat.count == RouterFeed.maxChat && s.router.chat.first?.text == "1" && s.router.chat.last?.text == "latest")
    }

    // MARK: The process

    /// A stand-in for Claude Code at `<root>/9.9.9/x/claude.app/Contents/MacOS/claude`.
    private func fake(_ dir: TempDir, _ script: String) -> URL {
        let root = dir.path("code")
        let bin = root.appendingPathComponent("9.9.9/x/claude.app/Contents/MacOS")
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n\(script)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        return root
    }

    /// Ignores SIGTERM (only SIGKILL ends it), and says so by leaving `ready-<pid>` in `dir` once it does.
    private func stubborn(_ dir: TempDir) -> String {
        #"exec /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; open(F, ">", "\#(dir.url.path)/ready-$$"); close(F); sleep 1 while 1'"#
    }

    private func ready(_ dir: TempDir, _ pid: Int32) -> Bool {
        FileManager.default.fileExists(atPath: dir.path("ready-\(pid)").path)
    }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// What the agent's processes did, in order, and whether two were ever alive at once.
    private final class Events {
        var log: [String] = []
        var spawned: [Int32] = []
        var overlap = false
    }

    private func follow(_ agent: RouterAgent) -> Events {
        let events = Events()
        agent.onSpawn = { pid in
            if events.spawned.contains(where: { kill($0, 0) == 0 }) { events.overlap = true }
            events.spawned.append(pid)
            events.log.append("spawn \(pid)")
        }
        agent.onExit = { pid in events.log.append("exit \(pid)") }
        return events
    }

    @Test func anEndedProcessIsKilledAndNoSecondOneRunsMeanwhile() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.codeRoot = fake(dir, stubborn(dir))
        agent.killAfter = 0.3
        let events = follow(agent)
        agent.send("one")
        await settle { events.spawned.count == 1 }
        let first = try #require(events.spawned.first)
        // Once it ignores SIGTERM, end it and ask for another.
        await settle { ready(dir, first) }
        agent.newConversation()
        agent.send("two")
        #expect(agent.phase == .starting)
        await settle { events.spawned.count == 2 }
        let second = try #require(events.spawned.last)
        // The first had to be killed and gone before the second started.
        #expect(events.log == ["spawn \(first)", "exit \(first)", "spawn \(second)"])
        #expect(!events.overlap)
        agent.shutdown()
        #expect(!alive(second))
    }

    @Test func resetsInARowNeverRunTwoProcesses() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.codeRoot = fake(dir, stubborn(dir))
        agent.killAfter = 0.1
        let events = follow(agent)
        for i in 0..<5 {
            agent.send("message \(i)")
            await settle { events.spawned.count > i }
            agent.newConversation()
        }
        agent.send("last")
        await settle { events.spawned.count == 6 }
        #expect(events.spawned.count == 6 && !events.overlap)
        // Each one's exit came before the next one's start.
        for (i, pid) in events.spawned.dropLast().enumerated() {
            let exit = events.log.firstIndex(of: "exit \(pid)")
            let next = events.log.firstIndex(of: "spawn \(events.spawned[i + 1])")
            #expect(exit != nil && next != nil && exit! < next!)
        }
        agent.shutdown()
        #expect(events.spawned.allSatisfy { !alive($0) })
    }

    @Test func quittingLeavesNoProcessBehind() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.codeRoot = fake(dir, stubborn(dir))
        agent.killAfter = 60
        agent.quitWait = 5
        let events = follow(agent)
        agent.send("one")
        await settle { events.spawned.count == 1 }
        let pid = try #require(events.spawned.first)
        await settle { ready(dir, pid) }
        // It ignores SIGTERM: quitting kills it, and waits for it to be gone.
        agent.shutdown()
        #expect(!alive(pid))
    }

    @Test func switchingTheRouterOffEndsItsProcess() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.codeRoot = fake(dir, "exec cat > /dev/null")
        let events = follow(agent)
        agent.send("one")
        await settle { events.spawned.count == 1 }
        let pid = try #require(events.spawned.first)
        let epoch = agent.tools.epoch
        s.router.enabled = false
        await settle { events.log.contains("exit \(pid)") }
        #expect(events.log.contains("exit \(pid)") && agent.phase == .idle)
        // Tool calls of the process that was are void.
        #expect(agent.tools.epoch != epoch)
    }

    @Test func stoppingBeforeAnythingWasSentCancelsItForGood() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        let events = follow(agent)
        agent.send("first")
        #expect(agent.phase == .starting)
        agent.stop()
        #expect(agent.phase == .idle)
        #expect(s.router.chat.map { "\($0.role.rawValue): \($0.text)" } == ["you: first", "receipt: Cancelled before sending"])
        // The next message starts it, and only that message is sent.
        agent.send("second")
        await settle { events.spawned.count == 1 }
        await settle { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("second") }
        let sent = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(events.spawned.count == 1 && sent.contains("second") && !sent.contains("first"))
        agent.shutdown()
    }

    @Test func aCancelledStartWritingLateDoesntChangeWhatTheNextLoads() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let loaded = dir.path("loaded.json"), path = dir.path("path.txt")
        agent.codeRoot = fake(dir, """
        while [ $# -gt 0 ]; do
          if [ "$1" = "--mcp-config" ]; then cp "$2" '\(loaded.path)'; printf '%s' "$2" > '\(path.path)'; fi
          shift
        done
        exec cat > /dev/null
        """)
        let events = follow(agent)
        // The first start's write is held until the second has started its process.
        let held = Held()
        agent.beforeConfigWrite = { gen in
            guard held.first(gen) else { return }
            held.wait()
        }
        agent.send("a")
        await settle { held.firstGen != nil }
        agent.stop()
        agent.send("b")
        await settle { events.spawned.count == 1 && FileManager.default.fileExists(atPath: loaded.path) }
        held.release()
        let home = dir.path("support/router")
        let used = URL(fileURLWithPath: (try? String(contentsOf: path, encoding: .utf8)) ?? "")
        // The late write lands in its own file, which is then removed; the file in use is untouched.
        await settle { ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix("mcp") } == [used.lastPathComponent] }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.path))?.filter { $0.hasPrefix("mcp") } == [used.lastPathComponent])
        #expect(used.lastPathComponent != "mcp-\(held.firstGen ?? -1).json")
        #expect(try Data(contentsOf: used) == Data(contentsOf: loaded))
        agent.shutdown()
    }

    @Test func aSessionWritingInDuringYourTurnDoesntSilenceTheReply() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.codeRoot = fake(dir, "exec cat > /dev/null")
        let events = follow(agent)
        agent.send("Tell lookout to ship")
        await settle { events.spawned.count == 1 }
        // A session's message is read in the middle of your turn: the rest of the turn is still yours.
        agent.apply([.started(sessionID: "cli"), .peer(from: "Lookout dev", text: "Shipped."), .text("Sent it."),
                     .result(isError: false, text: "")])
        #expect(s.router.chat.map(\.role) == [.you, .peer, .router])
        #expect(agent.phase == .idle)
        // One when nothing of yours runs: its turn is silent.
        agent.apply([.peer(from: "Lookout dev", text: "Also done."), .text("Noted."), .result(isError: false, text: "")])
        #expect(s.router.chat.map(\.role) == [.you, .peer, .router, .peer])
        agent.shutdown()
    }

    @Test func aLateLookupAfterAResetOrSwitchOffAddressesNothing() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let sent: [RouterStream.Event] = [.toolUse(id: "t1", name: "SendMessage", input: ["to": "Lookout dev", "message": "hi"]),
                                          .toolResult(id: "t1", isError: false, text: "Sent")]
        // Reset before the registry is read: the old message addresses nothing.
        agent.apply(sent)
        agent.newConversation()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.router.cards.first { $0.id == "local_a#t1" }?.isOpen == true)
        // Switched off meanwhile: the same.
        agent.apply(sent)
        s.router.enabled = false
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.router.cards.first { $0.id == "local_a#t1" }?.isOpen == true)
        s.router.enabled = true
        // Marked and reopened while the registry is read: it moved, so it's left open.
        agent.apply(sent)
        s.setCardAddressed("local_a#t1", true)
        s.setCardAddressed("local_a#t1", false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(s.router.cards.first { $0.id == "local_a#t1" }?.isOpen == true)
        // A card made for the session while the registry is read is newer than the message: it stays open.
        agent.apply(sent)
        s.router.cards.append(RouterCard(id: "local_a#t2", sessionID: "local_a", kind: .done, title: "Fix the login bug",
                                         folder: "/code/lookout", text: "Done again", createdAt: Date()))
        await settle { s.router.cards.first { $0.id == "local_a#t1" }?.isOpen == false }
        #expect(s.router.cards.first { $0.id == "local_a#t1" }?.addressedBy == .router)
        #expect(s.router.cards.first { $0.id == "local_a#t2" }?.isOpen == true)
    }

    // MARK: One turn at a time

    private func written(_ log: URL) -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    @Test func aMessageSentMidTurnWaitsForTheTurnToEnd() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        let events = follow(agent)
        agent.send("one")
        await settle { written(log).contains("one") }
        agent.send("two")
        // In the chat at once, but not written while the turn of "one" runs.
        #expect(s.router.chat.filter { $0.role == .you }.map(\.text) == ["one", "two"])
        #expect(agent.queuedCount == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!written(log).contains("two"))
        agent.apply([.started(sessionID: "cli"), .text("Done."), .result(isError: false, text: "")])
        // The turn ended: "two" goes, and its own turn runs (one result each, never one for both).
        #expect(agent.phase == .working && agent.queuedCount == 0)
        await settle { written(log).contains("two") }
        #expect(written(log).contains("two"))
        agent.apply([.result(isError: false, text: "")])
        #expect(agent.phase == .idle)
        #expect(events.spawned.count == 1)
        agent.shutdown()
    }

    @Test func aMessageSentDuringASessionsTurnWaitsToo() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        agent.send("one")
        await settle { written(log).contains("one") }
        agent.apply([.result(isError: false, text: "")])
        // A session writes in while nothing of yours runs; you write during its turn.
        agent.apply([.peer(from: "Lookout dev", text: "Done.")])
        agent.send("two")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!written(log).contains("two"))
        agent.apply([.text("Noted."), .result(isError: false, text: "")])
        await settle { written(log).contains("two") }
        #expect(written(log).contains("two") && agent.phase == .working)
        #expect(!s.router.chat.contains { $0.text == "Noted." })
        agent.apply([.text("Hi."), .result(isError: false, text: "")])
        #expect(s.router.chat.last?.text == "Hi." && agent.phase == .idle)
        agent.shutdown()
    }

    @Test func stoppingDropsWhatWaits() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        agent.send("one")
        await settle { written(log).contains("one") }
        agent.send("two")
        agent.send("three")
        agent.stop()
        #expect(agent.queuedCount == 0)
        #expect(s.router.chat.last?.role == .receipt && s.router.chat.last?.text == "Cancelled 2 queued messages")
        await settle { written(log).contains("interrupt") }
        agent.apply([.result(isError: true, text: "")])
        #expect(agent.phase == .idle && s.router.chat.last?.text == "Stopped")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(written(log).contains("interrupt") && !written(log).contains("two") && !written(log).contains("three"))
        agent.shutdown()
    }

    @Test func nothingMoreGoesOutOnceSwitchedOff() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        agent.send("one")
        await settle { written(log).contains("one") }
        agent.send("two")
        // Off, and the turn's result comes in before the switch is seen.
        s.router.enabled = false
        agent.apply([.result(isError: false, text: "")])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!written(log).contains("two"))
        agent.shutdown()
    }

    /// Lines of the log as "<pid> <message text>", in order.
    private func lines(_ log: URL) -> [(pid: String, text: String)] {
        written(log).split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            let text = ["one", "two", "three"].first { parts.count > 1 && parts[1].contains("\"\($0)\"") } ?? "?"
            return (String(parts[0]), text)
        }
    }

    @Test func whatWaitsGoesToTheNextProcessAfterACrash() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        // Reads one message, then dies.
        agent.codeRoot = fake(dir, "read -r line; printf '%s %s\\n' \"$$\" \"$line\" >> '\(log.path)'; exit 3")
        let events = follow(agent)
        var queued: [Int] = []
        agent.onSpawn = { [onSpawn = agent.onSpawn] pid in
            onSpawn?(pid)
            queued.append(agent.queuedCount)
        }
        agent.send("one")
        agent.send("two")
        agent.send("three")
        #expect(agent.queuedCount == 3)
        await settle { lines(log).count == 3 && events.log.filter { $0.hasPrefix("exit") }.count == 3 }
        let got = lines(log)
        // One message per process, in order, each process gone before the next.
        #expect(got.map(\.text) == ["one", "two", "three"])
        #expect(Set(got.map(\.pid)).count == 3 && events.spawned.count == 3 && !events.overlap)
        #expect(queued == [3, 2, 1])
        await settle { if case .failed = agent.phase { return true }; return false }
        guard case .failed = agent.phase else { Issue.record("not failed"); return }
        #expect(s.router.chat.filter { $0.role == .error }.count == 3 && agent.queuedCount == 0)
    }

    @Test func aFailedResumeSendsTheSameMessagesInOrderToAFreshOne() async throws {
        let dir = TempDir()
        let s = store(dir)
        s.router.claudeSessionID = "gone"
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        let result = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: gone"]}"#
        agent.codeRoot = fake(dir, """
        for a in "$@"; do
          if [ "$a" = "--resume" ]; then echo '\(result)'; echo 'No conversation found with session ID: gone' >&2; exit 1; fi
        done
        while read -r line; do printf '%s %s\\n' "$$" "$line" >> '\(log.path)'; done
        """)
        let events = follow(agent)
        agent.send("one")
        agent.send("two")
        // The fresh process gets "one" again, first; "two" waits for its turn.
        await settle { events.spawned.count == 2 && lines(log).count == 1 }
        #expect(lines(log).map(\.text) == ["one"] && agent.queuedCount == 1)
        #expect(s.router.claudeSessionID == nil && !events.overlap)
        #expect(s.router.chat.contains { $0.role == .error && $0.text.contains("Couldn't resume") })
        #expect(events.log.firstIndex(of: "exit \(events.spawned[0])")! < events.log.firstIndex(of: "spawn \(events.spawned[1])")!)
        agent.apply([.started(sessionID: "fresh"), .result(isError: false, text: "")])
        await settle { lines(log).count == 2 }
        #expect(lines(log).map(\.text) == ["one", "two"] && agent.queuedCount == 0)
        #expect(Set(lines(log).map(\.pid)) == [String(events.spawned[1])])
        agent.shutdown()
    }

    // MARK: Prepared messages and context

    /// The hook asking the gate, as Claude Code does before the SendMessage runs.
    @discardableResult
    private func pass(_ agent: RouterAgent, to: String, message: String) -> Bool {
        agent.tools.approveSend(["to": to, "message": message], otherFields: []) == nil
    }

    /// What prepare made for `to`: the body signed for its session's plugin.
    private func sealed(_ agent: RouterAgent, _ to: String) -> String { agent.tools.prepared[to]?.text ?? "" }

    @Test func aReceiptSaysWhatThePreparationWas() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.tools.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        agent.tools.beginTurn("tell it to bump the version")
        _ = await agent.tools.call("prepare", ["session": "Lookout dev"])
        let first = sealed(agent, "Lookout dev")
        #expect(first.hasPrefix("⟦lookout v1 cli-local_a ") && pass(agent, to: "Lookout dev", message: first))
        agent.apply([.toolUse(id: "t1", name: "SendMessage", input: ["to": "Lookout dev", "message": first]),
                     .toolResult(id: "t1", isError: false, text: "Sent")])
        // The receipt says the body only, never the line that signs it.
        let receipt = s.router.chat.last
        #expect(s.router.chat.count == 1 && receipt?.role == .receipt)
        #expect(receipt?.text == "→ Lookout dev: Bump the version." && receipt?.original == "tell it to bump the version")
        #expect(!s.router.chat.contains { $0.text.contains("⟦lookout") })
        // Refused by the gate: the tool's error is the line.
        agent.apply([.toolUse(id: "t2", name: "SendMessage", input: ["to": "Lookout dev", "message": "Please bump it."]),
                     .toolResult(id: "t2", isError: true, text: "That isn't the prepared text")])
        #expect(s.router.chat.last?.role == .error && s.router.chat.last?.text == "SendMessage: That isn't the prepared text")
        // Let through but not delivered (no such peer): an error, not a receipt.
        agent.tools.beginTurn("tell it to bump the version")
        _ = await agent.tools.call("prepare", ["session": "Lookout dev"])
        let second = sealed(agent, "Lookout dev")
        #expect(pass(agent, to: "Lookout dev", message: second))
        agent.apply([.toolUse(id: "t5", name: "SendMessage", input: ["to": "Lookout dev", "message": second]),
                     .toolResult(id: "t5", isError: false,
                                 text: #"{"success":false,"message":"No agent named 'Lookout dev' is reachable.\nUse ListAgents."}"#)])
        #expect(s.router.chat.last?.role == .error && s.router.chat.last?.text == "SendMessage: No agent named 'Lookout dev' is reachable.")
        #expect(RouterAgent.undelivered(#"{"success":true}"#) == nil && RouterAgent.undelivered("Sent") == nil)
        // Ran without the gate's yes: said; its receipt still shows no header.
        agent.apply([.toolUse(id: "t3", name: "SendMessage", input: ["to": "Lookout dev", "message": second]),
                     .toolResult(id: "t3", isError: false, text: "Sent")])
        #expect(s.router.chat.contains { $0.role == .error && $0.text == "The message to Lookout dev went without Lookout's check" })
        #expect(s.router.chat.last?.text == "→ Lookout dev: Bump the version.")
        // The Router quoting it in its own words: the line is left out too.
        agent.apply([.text("Sent:\n" + second)])
        #expect(s.router.chat.last?.text == "Sent:\nBump the version.")
        #expect(!s.router.chat.contains { $0.text.contains("⟦lookout") })
    }

    @Test func aNewSessionsFirstMessageIsItsReceipt() async {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        agent.tools.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        agent.tools.starter = { _, title in SessionStart.Started(sessionID: "local_new", peer: title) }
        agent.tools.beginTurn("start a session in lookout to bump the version")
        _ = await agent.tools.call("start_session", ["project": "lookout", "title": "Bump the version"])
        let text = sealed(agent, "Bump the version")
        #expect(text.hasPrefix("⟦lookout v1 new ") && pass(agent, to: "Bump the version", message: text))
        agent.apply([.toolUse(id: "s1", name: "mcp__lookout__start_session", input: ["project": "lookout"]),
                     .toolResult(id: "s1", isError: false, text: "{}"),
                     .toolUse(id: "t1", name: "SendMessage", input: ["to": "Bump the version", "message": text]),
                     .toolResult(id: "t1", isError: false, text: "Sent")])
        #expect(s.router.chat.map(\.text) == ["→ new session in lookout: Bump the version."])
        #expect(s.router.chat.last?.original == "start a session in lookout to bump the version")
    }

    @Test func aReplyAndTagsGoInTheHeaderAndOnYourLine() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        agent.send("ship it", context: RouterContext(replyTo: "local_a#t1", projects: ["/code/lookout", "/code/lookout"]))
        let mine = try #require(s.router.chat.last)
        #expect(mine.role == .you && mine.text == "ship it" && mine.replyTo == "local_a#t1" && mine.projects == ["/code/lookout"])
        await settle { written(log).contains("ship it") }
        let line = try #require(written(log).split(separator: "\n").first)
        let content = try #require(((try JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["message"] as? [String: Any])
        #expect(content["content"] as? String == """
        [reply to: card local_a#t1 · session "Fix the login bug" (lookout) · peer "Lookout dev"]
        [projects: lookout = /code/lookout]
        ship it
        """)
        // Plain: no header, no fields.
        agent.apply([.result(isError: false, text: "")])
        agent.send("hello")
        #expect(s.router.chat.last?.replyTo == nil && s.router.chat.last?.projects == nil)
        await settle { written(log).contains("hello") }
        #expect(written(log).contains(#""content":"hello""#))
        agent.shutdown()
    }

    @Test func quittingStopsAHaikuRunUnderWay() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let file = stubbornHaiku(dir, agent)
        agent.tools.beginTurn("tell lookout to ship")
        agent.quitWait = 4
        let preparing = Task { await agent.tools.call("prepare", ["session": "Lookout dev"]) }
        await settle { FileManager.default.fileExists(atPath: file.path) }
        let helper = pid(file)
        #expect(alive(helper))
        agent.shutdown()
        #expect(!alive(helper))
        #expect(await preparing.value?.isError == true)
    }

    @Test func theAgentAnswersEachPermissionRequestOnStdin() async throws {
        let dir = TempDir()
        let s = store(dir)
        let agent = RouterAgent(store: s)
        let log = dir.path("stdin.log")
        agent.codeRoot = fake(dir, "exec cat >> '\(log.path)'")
        agent.send("tell it to bump the version")
        await settle { written(log).contains("bump the version") }
        agent.tools.rephrase = { message, _, _ in Prepared(text: "Bump the version.", original: message, rephrased: true) }
        _ = await agent.tools.call("prepare", ["session": "Lookout dev"])
        let text = sealed(agent, "Lookout dev")
        let input = ["to": "Lookout dev", "message": text, "summary": RouterTools.summary(of: text), "type": "message",
                     "recipient": "Lookout dev", "recipient_kind": "name", "content": String(text.prefix(49)) + "…"]
        agent.apply([.permission(id: "p1", tool: "SendMessage", input: input, otherFields: []),
                     .permission(id: "p2", tool: "SendMessage", input: input, otherFields: []),
                     .permission(id: "p3", tool: "Bash", input: ["command": "ls"], otherFields: [])])
        await settle { written(log).contains("p3") }
        let answers = written(log).split(separator: "\n").compactMap { line -> [String: Any]? in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["response"] as? [String: Any]
        }
        func decision(_ id: String) -> [String: Any]? { answers.first { $0["request_id"] as? String == id }?["response"] as? [String: Any] }
        // Allowed once, with exactly the input asked about; the same again, or another tool, refused.
        #expect(decision("p1")?["behavior"] as? String == "allow" && decision("p1")?["updatedInput"] as? [String: String] == input)
        #expect(decision("p2")?["behavior"] as? String == "deny")
        #expect(decision("p3")?["behavior"] as? String == "deny" && (decision("p3")?["message"] as? String)?.contains("Bash") == true)
        agent.shutdown()
    }

    /// A Haiku that ignores SIGTERM and never answers. It writes its pid to `dir/haiku.pid` only once it ignores SIGTERM
    /// (so the file means it's ready), and its run is given far longer than any test takes (only the shutdown ends it).
    private func stubbornHaiku(_ dir: TempDir, _ agent: RouterAgent) -> URL {
        let haiku = dir.path("haiku")
        let file = dir.path("haiku.pid")
        FileManager.default.createFile(atPath: haiku.path, contents: Data(#"""
        #!/bin/sh
        exec /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; open(F, ">", "\#(file.path).tmp"); print F $$; close(F); rename("\#(file.path).tmp", "\#(file.path)"); sleep 1 while 1'
        """#.utf8), attributes: [.posixPermissions: 0o755])
        agent.tools.claudePath = { haiku.path }
        agent.tools.rephraseTimeout = 3600
        return file
    }

    private func pid(_ file: URL) -> Int32 {
        Int32(((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @Test func stopOrResetThenQuitLeavesNoHelperBehind() async throws {
        for reset in [false, true] {
            let dir = TempDir()
            let s = store(dir)
            let agent = RouterAgent(store: s)
            let file = stubbornHaiku(dir, agent)
            agent.quitWait = 4
            agent.tools.beginTurn("tell lookout to ship")
            let preparing = Task { await agent.tools.call("prepare", ["session": "Lookout dev"]) }
            await settle { FileManager.default.fileExists(atPath: file.path) }
            let helper = pid(file)
            #expect(alive(helper))
            // Stopped (or reset), then quit at once: the helper, still dying, is waited for and gone.
            if reset { agent.newConversation() } else { agent.tools.endTurn() }
            agent.shutdown()
            #expect(!alive(helper), "reset: \(reset)")
            #expect(await preparing.value?.isError == true)
        }
    }
}

/// Holds the first config write a test sees until it lets it go.
private final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var _first: Int?

    var firstGen: Int? { lock.withLock { _first } }

    /// True for the first generation seen (that one is held).
    func first(_ gen: Int) -> Bool {
        lock.withLock {
            if _first == nil { _first = gen; return true }
            return false
        }
    }

    func wait() { gate.wait() }
    func release() { gate.signal() }
}
