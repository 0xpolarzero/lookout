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

        private var inputDone = false
        /// The program's input was written whole or given up, and its pipe closed.
        var isInputClosed: Bool { lock.withLock { inputDone } }
        fileprivate func inputClosed() { lock.withLock { inputDone = true } }

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
        // One reader per pipe, each the only one ever to touch its descriptor: checked read(2), never a FileHandle
        // callback (which can't be stopped while one is under way). Stopped and waited for before the pipe is closed.
        let out = PipeReader(stdout.fileHandleForReading), err = PipeReader(stderr.fileHandleForReading)
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        handle.started(process.processIdentifier)
        defer { if !process.isRunning { handle.exited() } }
        out.start()
        err.start()
        defer {
            // Quiesced first (the reader finishes its read and its bounded last drain), then closed.
            for reader in [out, err] { reader.stop() }
            for reader in [out, err] { reader.waitDone() }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        // Written on its own thread, without blocking, and stopped with the run: a program (or a descendant holding its
        // stdin) that never reads can't keep a thread, the descriptor or the input alive after it.
        let writer = PipeWriter(stdin.fileHandleForWriting, input) { handle.inputClosed() }
        writer.start()
        defer {
            writer.stop()
            writer.waitDone()
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
        _ = out.waitEOF(until: tail)
        _ = err.waitEOF(until: tail)
        for reader in [out, err] { reader.stop() }
        for reader in [out, err] { reader.waitDone() }
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

    /// Writes a program's input on a thread of its own: non-blocking writes when the pipe takes them (poll), EINTR and
    /// EAGAIN retried, stopped when asked; the pipe is closed when it's done either way.
    final class PipeWriter: @unchecked Sendable {
        private let file: FileHandle
        private let data: Data
        private let closed: @Sendable () -> Void
        private let lock = NSLock()
        private var stopping = false
        private let done = DispatchSemaphore(value: 0)

        init(_ file: FileHandle, _ data: Data, closed: @escaping @Sendable () -> Void) {
            self.file = file
            self.data = data
            self.closed = closed
        }

        func start() {
            let thread = Thread { [self] in loop() }
            thread.qualityOfService = .utility
            thread.start()
        }

        func stop() { lock.withLock { stopping = true } }

        func waitDone() {
            done.wait()
            done.signal()
        }

        private var isStopping: Bool { lock.withLock { stopping } }

        private func loop() {
            let fd = file.fileDescriptor
            defer {
                try? file.close()
                closed()
                done.signal()
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var offset = 0
            data.withUnsafeBytes { bytes in
                while offset < bytes.count, !isStopping {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&poller, 1, 50)
                    if ready < 0 { if errno == EINTR { continue } else { return } }
                    if ready == 0 { continue }
                    if poller.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                    let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR || errno == EAGAIN { continue }
                    return
                }
            }
        }
    }

    /// Reads one pipe on a thread of its own: polls, reads what's there (EINTR and EAGAIN retried), stops at its end or
    /// when asked. Asked to stop, it drains what's already in the pipe, bounded in bytes and time (a descendant still
    /// feeding it can't keep it going), then says it's done.
    final class PipeReader: @unchecked Sendable {
        static let maxBytes = 8 << 20
        static let drainBytes = 1 << 20
        static let drainTime: TimeInterval = 0.2

        private let fd: Int32
        private let lock = NSLock()
        private var buffer = Data()
        private var stopping = false
        private let ended = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)
        private var reachedEnd = false
        /// Called around each read (tests hold a read in flight to see the stop wait for it).
        var aroundRead: (() -> Void)?

        init(_ file: FileHandle) { fd = file.fileDescriptor }

        var data: Data { lock.withLock { buffer } }

        func start() {
            let thread = Thread { [self] in loop() }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() { lock.withLock { stopping = true } }

        /// The pipe's end was reached by `until`.
        func waitEOF(until: DispatchTime) -> Bool {
            if lock.withLock({ reachedEnd }) { return true }
            guard ended.wait(timeout: until) == .success else { return false }
            ended.signal()
            return true
        }

        /// Blocks until the reader has finished (its read under way and its last drain included).
        func waitDone() {
            done.wait()
            done.signal()
        }

        private var isStopping: Bool { lock.withLock { stopping } }

        private func append(_ bytes: UnsafeMutableRawBufferPointer, _ n: Int) {
            lock.withLock {
                guard buffer.count < Self.maxBytes else { return }
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<min(n, Self.maxBytes - buffer.count)]))
            }
        }

        /// One read: bytes read, 0 at the end, nil when there's nothing now (or an error).
        private func readOnce(_ chunk: UnsafeMutableRawBufferPointer) -> Int? {
            while true {
                aroundRead?()
                let n = read(fd, chunk.baseAddress, chunk.count)
                if n >= 0 { return n }
                if errno == EINTR { continue }
                return nil
            }
        }

        private func loop() {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 1)
            defer {
                chunk.deallocate()
                done.signal()
            }
            while !isStopping {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, 50)
                if ready < 0 { if errno == EINTR { continue } else { break } }
                if ready == 0 { continue }
                guard let n = readOnce(chunk) else { continue }
                if n == 0 {
                    lock.withLock { reachedEnd = true }
                    ended.signal()
                    return
                }
                append(chunk, n)
            }
            // Stopping: what's already there, within the bounds.
            let started = Date()
            var total = 0
            while total < Self.drainBytes, Date().timeIntervalSince(started) < Self.drainTime,
                  let n = readOnce(chunk), n > 0 {
                append(chunk, n)
                total += n
            }
        }
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
