import Foundation
import Testing
@testable import Lookout

/// Preparing a message with Haiku (a fake Claude Code stands in), and the pieces of starting a session.
@Suite struct RouterPrepare {
    // MARK: Haiku's answer

    @Test func anAnswerIsHeldToTheRules() throws {
        let original = "tell lookout to bump the version"
        let rephrased = try Rephrase.parse(#"{"rephrased": true, "text": "Bump the version."}"#, original: original)
        #expect(rephrased == Prepared(text: "Bump the version.", original: original, rephrased: true))
        // Fenced, or with words around it: the JSON is found.
        let fenced = try Rephrase.parse("```json\n{\"rephrased\":true,\"text\":\"Bump the version.\"}\n```", original: original)
        #expect(fenced.text == "Bump the version." && fenced.rephrased)
        // Not rephrased: the original, byte for byte, whatever text came back.
        let kept = try Rephrase.parse(#"{"rephrased": false, "text": "Tell lookout to bump the version."}"#, original: original)
        #expect(kept == Prepared(text: original, original: original, rephrased: false))
        // "Rephrased" to the same words: unchanged. To nothing: refused, not replaced by the original.
        #expect(try Rephrase.parse(#"{"rephrased": true, "text": "tell lookout to bump the version"}"#, original: original).rephrased == false)
        #expect(throws: RouterTools.Failure.self) { try Rephrase.parse(#"{"rephrased": true, "text": "  \n"}"#, original: original) }
        // Kept exactly as given: indentation and trailing newlines in code matter.
        let code = try Rephrase.parse(#"{"rephrased": true, "text": "Run:\n    swift test\n"}"#, original: original)
        #expect(code.text == "Run:\n    swift test\n")
        #expect(throws: RouterTools.Failure.self) { try Rephrase.parse("Sure! Here it is: Bump the version.", original: original) }
        #expect(throws: RouterTools.Failure.self) { try Rephrase.parse(#"{"text": "x"}"#, original: original) }
    }

    @Test func haikuRunsAloneWithNoToolsAndTheRules() {
        let args = Rephrase.arguments()
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(args.first == "-p" && value("--model") == "claude-haiku-5-5" && value("--tools") == "")
        #expect(value("--setting-sources") == "" && value("--output-format") == "json" && value("--system-prompt") == Rephrase.rules)
        #expect(args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
        let input = Rephrase.input(message: "ask it if the tests pass", title: "Fix login", project: "lookout")
        #expect(input == "Target session: \"Fix login\" (project lookout)\n\nMessage:\nask it if the tests pass")
        for rule in ["EXACTLY as written", "Never add, summarise, translate", "\"rephrased\""] { #expect(Rephrase.rules.contains(rule)) }
    }

    /// A stand-in for Claude Code: keeps its arguments and stdin, then prints `output`.
    private func fake(_ dir: TempDir, output: String, sleep: Double = 0) -> String {
        let path = dir.path("claude").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(dir.path("args").path)'
        cat > '\(dir.path("stdin").path)'
        sleep \(sleep)
        cat <<'EOF'
        \(output)
        EOF
        """
        FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    @Test func aRunGoesThroughTheBinaryAndBack() async throws {
        let dir = TempDir()
        let answer = #"{"type":"result","subtype":"success","is_error":false,"result":"{\"rephrased\":true,\"text\":\"Bump the version.\"}"}"#
        let binary = fake(dir, output: answer)
        let out = try await Rephrase.run(binary: binary, cwd: dir.url, message: "tell lookout to bump the version",
                                         title: "Release", project: "lookout")
        #expect(out == Prepared(text: "Bump the version.", original: "tell lookout to bump the version", rephrased: true))
        let stdin = try String(contentsOf: dir.path("stdin"), encoding: .utf8)
        #expect(stdin.contains("\"Release\" (project lookout)") && stdin.hasSuffix("tell lookout to bump the version"))
        let args = try String(contentsOf: dir.path("args"), encoding: .utf8)
        #expect(args.contains("claude-haiku-5-5"))
    }

    @Test func aFailedOrSlowRunIsAnError() async throws {
        let dir = TempDir()
        let failed = fake(dir, output: #"{"type":"result","is_error":true,"errors":["Model not available"]}"#)
        await #expect(throws: RouterTools.Failure.self) {
            try await Rephrase.run(binary: failed, cwd: dir.url, message: "hi", title: "t", project: "p")
        }
        let slow = TempDir()
        let binary = fake(slow, output: "{}", sleep: 5)
        let start = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            try await Rephrase.run(binary: binary, cwd: slow.url, message: "hi", title: "t", project: "p", timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    // MARK: Starting a session

    @Test func theBootstrapRenamesAndMakesNoModelCall() throws {
        // No permission mode: the app gives the imported session the one in the user's settings.
        let args = SessionStart.bootstrapArguments(uuid: "u-1", title: "Bump the version")
        #expect(args == ["-p", "/rename Bump the version", "--session-id", "u-1", "--output-format", "json", "--setting-sources", ""])
        #expect(SessionStart.importURL(uuid: "abc")?.absoluteString == "claude://resume?session=abc")
        #expect(SessionStart.cleanTitle("  Bump\nthe   version  ") == "Bump the version")
    }

    @Test func theNewSessionsProcessIsWaitedFor() async throws {
        let dir = TempDir()
        let peers = dir.path("sessions")
        try FileManager.default.createDirectory(at: peers, withIntermediateDirectories: true)
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let data = try? JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "hostSessionId": "local_u-9", "name": "Bump the version"])
            try? data?.write(to: peers.appendingPathComponent("\(getpid()).json"))
        }
        #expect(try await SessionStart.waitForPeer(uuid: "u-9", dir: peers, timeout: 10) == "Bump the version")
        await #expect(throws: RouterTools.Failure.self) { try await SessionStart.waitForPeer(uuid: "other", dir: peers, timeout: 0.5) }
    }

    // MARK: The chat line

    @Test func aChatLineReadsLeniently() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let id = UUID().uuidString
        let full = #"{"id":"\#(id)","role":"you","text":"hi","date":"2026-10-09T10:00:00Z","replyTo":"local_a#t1","projects":["/code/a"]}"#
        let line = try decoder.decode(RouterMessage.self, from: Data(full.utf8))
        #expect(line.replyTo == "local_a#t1" && line.projects == ["/code/a"] && line.original == nil && line.id.uuidString == id)
        let odd = #"{"role":"receipt","text":"→ a: b","date":"2026-10-09T10:00:00Z","projects":"oops","original":"tell a to b"}"#
        let kept = try decoder.decode(RouterMessage.self, from: Data(odd.utf8))
        #expect(kept.projects == nil && kept.original == "tell a to b" && kept.text == "→ a: b")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try decoder.decode(RouterMessage.self, from: encoder.encode(line)) == line)
    }

    @Test func theHeaderSaysTheReplyAndTheProjects() {
        let reply = RouterAgent.Reply(card: "local_a#t1", title: "Fix login", project: "lookout", peer: "Lookout dev")
        #expect(RouterAgent.header("ship it", reply: reply, projects: [("lookout", "/code/lookout"), ("api", "/code/api")]) == """
        [reply to: card local_a#t1 · session "Fix login" (lookout) · peer "Lookout dev"]
        [projects: lookout = /code/lookout, api = /code/api]
        ship it
        """)
        let gone = RouterAgent.Reply(card: "local_a#t1", title: "Fix login", project: "lookout", peer: nil)
        #expect(RouterAgent.header("x", reply: gone, projects: []) == "[reply to: card local_a#t1 · session \"Fix login\" (lookout) · not reachable]\nx")
        #expect(RouterAgent.header("plain", reply: nil, projects: []) == "plain")
    }

    @Test func theRoleExplainsTheHeaderAndPreparing() {
        for part in ["[reply to: card", "[projects:", "call prepare(session)", "SendMessage exactly what prepare returns",
                     "Its `text` is already prepared", "Never write a message yourself",
                     "start_session starts in the tagged project", "If prepare fails, tell the user its reason in one line and don't send"] {
            #expect(RouterPrompt.role.contains(part), "\(part)")
        }
    }

    // MARK: One run, bounded

    private func script(_ dir: TempDir, _ name: String, _ body: String) -> String {
        let path = dir.path(name).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    private func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    @Test func aProgramThatNeverReadsItsInputDoesntHoldTheRun() async throws {
        let dir = TempDir()
        // 4 MB of input it never reads; it answers and exits.
        let path = script(dir, "deaf", "echo done")
        let out = try await OneShot.run(path, [], cwd: dir.url, input: Data(count: 4 << 20), timeout: 10)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "done\n" && out.status == 0)
        // Never reading and never exiting: the deadline ends it, covering the blocked write too.
        let stuck = script(dir, "stuck", "exec sleep 30")
        let handle = OneShot.Handle()
        let start = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            try await OneShot.run(stuck, [], cwd: dir.url, input: Data(count: 4 << 20), timeout: 1, handle: handle)
        }
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(handle.pid > 0 && !handle.isActive && !alive(handle.pid))
    }

    @Test func aChildLeftHoldingTheOutputDoesntHoldTheRun() async throws {
        let dir = TempDir()
        // It exits at once, but leaves a child that keeps its stdout and stderr open for 30 s.
        let path = script(dir, "leaver", "sleep 30 & echo $! > '\(dir.path("child.pid").path)'; echo answer")
        let start = Date()
        let out = try await OneShot.run(path, [], cwd: dir.url, timeout: 10)
        #expect(String(decoding: out.stdout, as: UTF8.self) == "answer\n")
        #expect(Date().timeIntervalSince(start) < 5)
        if let child = Int32((try? String(contentsOf: dir.path("child.pid"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            kill(child, SIGKILL)
        }
    }

    @Test func cancellingEndsTheProgramEvenIfItIgnoresSIGTERM() async throws {
        let dir = TempDir()
        let path = script(dir, "stubborn", #"exec /usr/bin/perl -e '$SIG{TERM} = "IGNORE"; sleep 1 while 1'"#)
        let handle = OneShot.Handle()
        let running = Task { try await OneShot.run(path, [], cwd: dir.url, timeout: 60, handle: handle) }
        while !handle.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = handle.pid
        let start = Date()
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!alive(pid) && !handle.isRunning && Date().timeIntervalSince(start) < 6)
        // Ended before it started: never run.
        let early = OneShot.Handle()
        early.cancel()
        await #expect(throws: CancellationError.self) { try await OneShot.run(path, [], cwd: dir.url, timeout: 60, handle: early) }
        #expect(early.pid == 0)
    }
}

