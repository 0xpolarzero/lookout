import Foundation

// MARK: - Off the main thread

/// Blocking work (reading files, a hook a test holds) on a dispatch queue, never on Swift's small shared pool of threads:
/// a held or slow read there would hold up every other task in the app.
enum OffMain {
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            let box = UncheckedBox(work)
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: box.value()) }
        }
    }

    private struct UncheckedBox<T>: @unchecked Sendable {
        let value: () -> T
        init(_ value: @escaping () -> T) { self.value = value }
    }
}

// MARK: - Running a CLI once

/// Runs a program to its end, off the main thread: stdin given, stdout and the exit status back. One deadline covers it
/// all (writing stdin, the run, reading the output), and a cancelled caller ends it: SIGTERM, then SIGKILL, and its exit is
/// waited for, so nothing is left running.
enum OneShot {
    struct Output: Sendable {
        var stdout: Data
        var stderr: Data
        var status: Int32
    }

    struct TimedOut: LocalizedError {
        var seconds: TimeInterval
        var errorDescription: String? { "No answer in \(Int(RouterTools.bounded(seconds))) s" }
    }

    /// Ends a run from outside (Stop, a reset, quitting); Swift task cancellation does the same.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        /// Woken by the program's exit or by `cancel`.
        fileprivate let wake = DispatchSemaphore(value: 0)
        private(set) var pid: Int32 = 0
        private var gone = false

        init() {}

        private var done = false

        /// Its program was started and hasn't been seen to exit.
        var isRunning: Bool { lock.withLock { pid > 0 && !gone } }
        /// Not over yet: about to start, running, or being stopped. A run ends only once its program is confirmed gone.
        var isActive: Bool { lock.withLock { !done } }

        fileprivate func finish() { lock.withLock { done = true } }

        fileprivate func exited() { lock.withLock { gone = true } }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
            wake.signal()
        }

        fileprivate func started(_ pid: Int32) { lock.withLock { self.pid = pid } }
    }

    /// How long a stopped program has after SIGTERM, and how long its output may trail its exit (a child it left behind
    /// may hold the pipes open: they're not waited for past this).
    static let grace: TimeInterval = 1

    static func run(_ path: String, _ arguments: [String], cwd: URL, input: Data = Data(), timeout: TimeInterval,
                    handle: Handle = Handle()) async throws -> Output {
        try await withTaskCancellationHandler {
            // On a plain thread: the waits block it, which Swift's own pool of threads must not be.
            try await withCheckedThrowingContinuation { (finished: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    finished.resume(with: Result { try blocking(path, arguments, cwd: cwd, input: input, timeout: timeout, handle) })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func blocking(_ path: String, _ arguments: [String], cwd: URL, input: Data, timeout: TimeInterval,
                                 _ handle: Handle) throws -> Output {
        // Bounded: a huge or odd timeout must not trap when it's turned into nanoseconds.
        let deadline = DispatchTime.now() + RouterTools.bounded(timeout)
        defer { handle.finish() }
        guard !handle.isCancelled else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in handle.wake.signal() }
        // Both pipes are drained as they fill (a chatty program never blocks on a full pipe); their ends are counted.
        let out = Collector(), err = Collector()
        let ended = DispatchSemaphore(value: 0)
        for (pipe, into) in [(stdout, out), (stderr, err)] {
            pipe.fileHandleForReading.readabilityHandler = { file in
                let chunk = file.availableData
                if chunk.isEmpty {
                    file.readabilityHandler = nil
                    ended.signal()
                } else {
                    into.add(chunk)
                }
            }
        }
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        handle.started(process.processIdentifier)
        defer { if !process.isRunning { handle.exited() } }
        // Written on its own thread: a program that doesn't read its input can't hold this one.
        let writer = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        while process.isRunning {
            if handle.isCancelled {
                stop(process)
                throw CancellationError()
            }
            if handle.wake.wait(timeout: deadline) == .timedOut, process.isRunning {
                stop(process)
                throw TimedOut(seconds: timeout)
            }
        }
        // The output may trail the exit a moment; a child holding the pipes isn't waited for beyond the grace.
        let tail = min(deadline, .now() + grace)
        var open = 2
        while open > 0, ended.wait(timeout: tail) == .success { open -= 1 }
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
        return Output(stdout: out.data, stderr: err.data, status: process.terminationStatus)
    }

    /// SIGTERM, SIGKILL after the grace, and its exit confirmed.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let until = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < until { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killed = Date().addingTimeInterval(5)
        while process.isRunning, Date() < killed { usleep(10_000) }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        var data: Data { lock.withLock { buffer } }
        func add(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }
    }

    /// `--output-format json`'s `result` text, or why the run failed.
    static func result(_ output: Output) throws -> String {
        let obj = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any]
        if let obj, obj["is_error"] as? Bool != true, let text = obj["result"] as? String { return text }
        let errors = (obj?["errors"] as? [String])?.joined(separator: "; ")
        let stderr = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init)
        throw RouterTools.Failure(errors ?? (obj?["result"] as? String) ?? stderr ?? "Claude Code exited (\(output.status))")
    }
}

// MARK: - Preparing a message

/// What a message to a session becomes before it is sent: the user's words, or, when they address the session or the
/// Router, the same words said to the session directly.
struct Prepared: Equatable, Sendable {
    var text: String
    var original: String
    var rephrased: Bool
    /// The project a new session was started in (`start_session`): its receipt says so.
    var newSessionIn: String? = nil
    /// What the session gets as your words, when `text` is that signed for its plugin (the chat shows this, never the
    /// header).
    var body: String? = nil
}

/// Haiku, run once per message, decides whether a message needs rephrasing for its target, and how. It only ever removes
/// addressing: the rules forbid anything else.
enum Rephrase {
    static let model = "claude-haiku-5-5"
    static let timeout: TimeInterval = 20

    static let rules = """
    You prepare a message a user wrote to one of their Claude Code sessions, before it is delivered to that session.
    Return the message to deliver. Keep it EXACTLY as written unless one of these applies:
    (a) It addresses the target session or a router ("tell lookout to …", "ask the api session whether …", "@lookout …", \
    "for lookout: …"): drop the addressing and say it to the session directly ("tell lookout to bump the version" → \
    "Bump the version.").
    (b) It is indirect speech about the session ("ask it if the tests pass" → "Do the tests pass?").
    (c) It holds parts for several sessions or projects ("lookout: add a badge; api: rotate the keys"): keep only the part \
    meant for the target (by its title or project), verbatim, without its addressing, and drop every other part \
    (for a target in project lookout → "Add a badge").
    Never add, summarise, translate, fix typos or change the style. Keep code, paths, names and the language as they are.
    Answer with JSON only: {"rephrased": true|false, "text": "…"}. When nothing applies: {"rephrased": false, "text": \
    <the message unchanged>}.
    """

    static func arguments() -> [String] {
        ["-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
         "--output-format", "json", "--system-prompt", rules]
    }

    /// What Haiku reads: the target, then the message.
    static func input(message: String, title: String, project: String) -> String {
        "Target session: \"\(title)\" (project \(project))\n\nMessage:\n\(message)"
    }

    /// Haiku's answer, held to the rules Lookout can check: an unchanged message is the original, byte for byte.
    static func parse(_ answer: String, original: String) throws -> Prepared {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end { text = String(text[start...end]) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let rephrased = obj["rephrased"] as? Bool, let out = obj["text"] as? String else {
            throw RouterTools.Failure("Couldn't read Haiku's answer")
        }
        guard rephrased, out != original else { return Prepared(text: original, original: original, rephrased: false) }
        // Kept as given (whitespace in code matters); nothing left of the message is no message.
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouterTools.Failure("Haiku left nothing of the message")
        }
        return Prepared(text: out, original: original, rephrased: true)
    }

    /// One Haiku call with Claude Code's bundled binary.
    static func run(binary: String, cwd: URL, message: String, title: String, project: String,
                    timeout: TimeInterval = timeout, handle: OneShot.Handle = OneShot.Handle()) async throws -> Prepared {
        let output = try await OneShot.run(binary, arguments(), cwd: cwd,
                                           input: Data(input(message: message, title: title, project: project).utf8),
                                           timeout: timeout, handle: handle)
        return try parse(try OneShot.result(output), original: message)
    }
}

// MARK: - Starting a session

/// A new desktop session made directly, with no draft for the user to send: a CLI session is created in the folder with no
/// model call (its only line renames it), the app imports it (`claude://resume`) and starts its process, which then
/// registers as a peer the Router can message.
enum SessionStart {
    struct Started: Equatable, Sendable {
        /// The desktop app's id, `local_<uuid>`.
        var sessionID: String
        var peer: String
        /// Claude Code's own session id: the bootstrap's uuid.
        var cliID: String { sessionID.hasPrefix("local_") ? String(sessionID.dropFirst(6)) : sessionID }
    }

    static let wait: TimeInterval = 20

    /// The CLI session: no model call, and the least left in it (the rename, which is also its title). Its permission mode
    /// isn't set here: the app gives an imported session the one in your settings (`permissions.defaultMode`).
    static func bootstrapArguments(uuid: String, title: String) -> [String] {
        ["-p", "/rename \(title)", "--session-id", uuid, "--output-format", "json", "--setting-sources", ""]
    }

    static func importURL(uuid: String) -> URL? {
        var components = URLComponents(string: "claude://resume")
        components?.queryItems = [URLQueryItem(name: "session", value: uuid)]
        return components?.url
    }

    /// One line, a few words: what the app shows as the title.
    static func cleanTitle(_ title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(80))
    }

    /// Waits (polling the registry off the main thread) for the app's process of `local_<uuid>`; its peer name.
    /// `check` is asked between polls (Stop, a reset): it throws to end the wait.
    static func waitForPeer(uuid: String, dir: URL, timeout: TimeInterval = wait,
                            check: @MainActor () throws -> Void = {}) async throws -> String {
        let host = "local_\(uuid)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await check()
            let peers = await OffMain.run { ClaudePeers.read(dir: dir) }
            if let peer = peers[host] { return peer.name }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RouterTools.Failure("The new session didn't start in \(Int(RouterTools.bounded(timeout))) s; it may be waiting in the Claude app")
    }
}
