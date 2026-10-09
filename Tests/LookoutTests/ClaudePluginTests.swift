import Foundation
import Testing
@testable import Lookout

/// Claude Code's plugin commands, answered from memory: the marketplaces and plugins added, and every call made. A
/// command can be made to fail, or held until the test lets it go.
final class FakeClaudeCLI: @unchecked Sendable {
    private let lock = NSLock()
    var marketplaces: [String: String] = [:]
    /// id → (folder, version, enabled)
    var plugins: [String: (folder: String, version: String, enabled: Bool)] = [:]
    var calls: [String] = []
    /// The version the folder holds, as `plugin list` reads it.
    var folderVersion = ""
    var failing: String?
    /// Commands starting with this wait for `release()`.
    var holding: String?
    private var held: [CheckedContinuation<Void, Never>] = []
    var isHolding: Bool { lock.withLock { !held.isEmpty } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = nil
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    var runner: ClaudePluginInstaller.Runner {
        { [self] binary, arguments in
            let line = arguments.joined(separator: " ")
            if lock.withLock({ holding.map { line.hasPrefix($0) } ?? false }) {
                await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
            }
            return lock.withLock { answer(binary, arguments) }
        }
    }

    private func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func answer(_ binary: String, _ a: [String]) -> ClaudePluginInstaller.Output {
        let line = a.joined(separator: " ")
        calls.append(line)
        if let failing, line.hasPrefix(failing) { return .init(status: 1, out: "", err: "boom: \(failing)\n") }
        switch Array(a.prefix(3)) {
        case ["plugin", "list", "--json"]:
            return .init(status: 0, out: json(plugins.map { id, p in
                ["id": id, "version": p.version, "scope": "user", "enabled": p.enabled, "readFromFolder": p.folder,
                 "folderVersion": folderVersion] as [String: Any]
            }), err: "")
        case ["plugin", "marketplace", "list"]:
            return .init(status: 0, out: json(marketplaces.map { ["name": $0.key, "source": "directory", "path": $0.value] }), err: "")
        case ["plugin", "marketplace", "add"]:
            marketplaces["lookout"] = a[3]
        case ["plugin", "marketplace", "remove"]:
            marketplaces[a[3]] = nil
        case ["plugin", "install", "lookout@lookout"]:
            guard let folder = marketplaces["lookout"] else { return .init(status: 1, out: "", err: "no marketplace") }
            plugins["lookout@lookout"] = (folder, folderVersion, true)
        case ["plugin", "update", "lookout@lookout"]:
            plugins["lookout@lookout"]?.version = folderVersion
        case ["plugin", "enable", "lookout@lookout"]:
            plugins["lookout@lookout"]?.enabled = true
        case ["plugin", "uninstall", "lookout@lookout"]:
            plugins["lookout@lookout"] = nil
        default:
            return .init(status: 1, out: "", err: "unknown command \(line)")
        }
        return .init(status: 0, out: "ok\n", err: "")
    }

    /// The calls that changed something (the lists left out).
    var changes: [String] { lock.withLock { calls.filter { !$0.contains("list") } } }
}

/// Lookout's plugin running in a session, as a test lays it out: Claude Code's registry lists the process (this test
/// process's pid, alive) for the session, the plugin's presence file names it under the key in `support/relay.key`, and
/// the plugin's config says where the registry and the key are.
enum PluginFixture {
    /// The store signs with the key a test wrote (as a switch-on would have read it, off the main thread).
    @MainActor static func useKey(_ s: Store) {
        guard let paths = s.routerFiles else { return }
        s.relayKeyCache = RelayKeyCache.load(paths.relayKey)
    }

    static func live(_ cli: String, support: URL, claude: URL, pid: Int32 = getpid(), startedAt: Int64 = 1) {
        let fm = FileManager.default
        let registry = claude.appendingPathComponent("sessions", isDirectory: true)
        let presence = support.appendingPathComponent("plugin-sessions", isDirectory: true)
        let plugin = support.appendingPathComponent("claude-plugin", isDirectory: true)
        for dir in [registry, presence, plugin] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        func write(_ obj: [String: Any], _ url: URL) { try? JSONSerialization.data(withJSONObject: obj).write(to: url) }
        write(["pid": Int(pid), "sessionId": cli, "startedAt": startedAt], registry.appendingPathComponent("plugin-\(cli).json"))
        let key = support.appendingPathComponent("relay.key")
        let keyID = ClaudePlugin.key(at: key).map(ClaudePlugin.keyID(of:)) ?? "none"
        write(["state": "live", "sessionId": cli, "pid": Int(pid), "startedAt": startedAt, "keyId": keyID,
               "renewedAt": Int64(ClaudePlugin.leaseNow.timeIntervalSince1970 * 1000), "activation": "test"],
              presence.appendingPathComponent(cli))
        write(["sessionsDir": registry.path, "presenceDir": presence.path, "keyPath": key.path], plugin.appendingPathComponent("config.json"))
    }
}

@Suite struct ClaudePluginFiles {
    /// The repository's copy of the plugin, where `claude plugin test` runs its tests.
    private static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/ClaudePlugin")

    @Test func theEmbeddedSourcesAreTheRepositorysOwn() throws {
        func read(_ path: String) throws -> String { try String(contentsOf: Self.source.appendingPathComponent(path), encoding: .utf8) }
        #expect(try read("hooks/register.ts") == ClaudePlugin.register)
        #expect(try read("hooks/hooks.json") == ClaudePlugin.hooksJSON)
        #expect(try read(".claude-plugin/marketplace.json") == ClaudePlugin.marketplaceJSON)
        let repo = try #require(try JSONSerialization.jsonObject(with: Data(read(".claude-plugin/plugin.json").utf8)) as? NSDictionary)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(ClaudePlugin.pluginJSON(version: "0.0.0-dev").utf8)) as? NSDictionary)
        #expect(written.isEqual(repo))
    }

    @Test func theVersionFollowsTheAppAndTheSources() {
        let release = ClaudePlugin.version(app: "1.4.0"), dev = ClaudePlugin.version(app: "0.0.0-dev")
        #expect(release.hasPrefix("1.4.0-r") && release.count == "1.4.0-r".count + 8)
        #expect(dev.hasPrefix("0.0.0-dev.r"))
        #expect(ClaudePlugin.version(app: "1.4.0") == release && ClaudePlugin.version(app: "1.4.1") != release)
    }

    @Test func theFolderIsWrittenAndTheKeyKeptOutsideIt() throws {
        let dir = TempDir()
        let folder = dir.path("claude-plugin"), presence = dir.path("plugin-sessions"), keyFile = dir.path("relay.key")
        try ClaudePlugin.write(to: folder, version: "1.0.0-rabc", presence: presence, key: keyFile, registry: dir.path("sessions"))
        let fm = FileManager.default
        for path in [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json", "hooks/register.ts", "config.json"] {
            #expect(fm.fileExists(atPath: folder.appendingPathComponent(path).path), "\(path)")
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any]
        #expect(manifest?["version"] as? String == "1.0.0-rabc" && manifest?["name"] as? String == "lookout")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("config.json"))) as? [String: String]
        #expect(config == ["keyPath": keyFile.path, "presenceDir": presence.path, "sessionsDir": dir.path("sessions").path])
        // Writing the folder makes no key; the key is made once, readable by the person alone, never in the folder.
        #expect(ClaudePlugin.key(at: keyFile) == nil)
        let key = try ClaudePlugin.ensureKey(at: keyFile)
        #expect(key.count == 64 && key.allSatisfy(\.isHexDigit) && mode(keyFile) == 0o600 && mode(folder) == 0o700)
        #expect(try ClaudePlugin.ensureKey(at: keyFile) == key)
        for path in (fm.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? [] {
            let text = (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? ""
            #expect(!text.contains(key), "\(path)")
        }
        ClaudePlugin.removeKey(at: keyFile)
        #expect(try ClaudePlugin.ensureKey(at: keyFile) != key)
    }
}

/// Which sessions run the plugin: a presence file counts only while its process lives and Claude Code still registers it
/// for that session, started when the file says.
@Suite struct PluginPresence {
    private let key = "k1"

    private func presence(_ dir: TempDir, _ cli: String, pid: Int32, startedAt: Int64, state: String = "live", keyID: String? = nil,
                          renewedAt: Date = ClaudePlugin.leaseNow) throws {
        let obj: [String: Any] = ["state": state, "sessionId": cli, "pid": Int(pid), "startedAt": startedAt,
                                  "keyId": keyID ?? ClaudePlugin.keyID(of: key), "activation": "a",
                                  "renewedAt": Int64(renewedAt.timeIntervalSince1970 * 1000)]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.path(cli))
    }

    private func entry(_ cli: String, _ startedAt: Int64) -> [ClaudePeers.Registered] {
        [ClaudePeers.Registered(sessionID: cli, startedAt: startedAt)]
    }

    @Test func aLiveProcessRegisteredForTheSessionCounts() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-a"])
        try presence(dir, "cli-a", pid: 100, startedAt: 5, state: "ended")
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
    }

    @Test func aCrashOrAResumeWithoutThePluginDoesNotCount() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        // Crashed: the process is gone (its registry file may linger).
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in false }.isEmpty)
        // Resumed in another process that doesn't run the plugin: the session is registered, under another pid.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [200: entry("cli-a", 9)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        // The pid was reused by a new process.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 9)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        // An old plain-text file says nothing about a process.
        try Data("live\n".utf8).write(to: dir.path("cli-b"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-b", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
    }

    @Test func aClearMovesThePresenceToTheNewSession() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        // /clear: the same process now runs a new session id; until the plugin marks it, neither counts.
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-new", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        try presence(dir, "cli-new", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-new", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-new"])
    }

    @Test func aFileWrittenUnderAnotherKeyDoesNotCount() throws {
        // The same process and session: the plugin was unloaded while the Router was off, so it never said so under the
        // key made when the Router came back on.
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5, keyID: ClaudePlugin.keyID(of: "old key"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true }.isEmpty)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: nil) { _ in true }.isEmpty)
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-a"])
    }

    @Test func aPluginUnloadedWithoutAWordStopsCountingWhenItsLeaseRunsOut() throws {
        // Disabled outside Lookout and reloaded away: no session.end, the same process, session and key. The plugin no
        // longer renews its file.
        let dir = TempDir()
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        try presence(dir, "cli-a", pid: 100, startedAt: 5, renewedAt: t0)
        let registry = [Int32(100): entry("cli-a", 5)], keyID = ClaudePlugin.keyID(of: key)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0.addingTimeInterval(25)) { _ in true } == ["cli-a"])
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0.addingTimeInterval(31)) { _ in true }.isEmpty)
        // A file with no lease at all (an older plugin) never counts.
        try JSONSerialization.data(withJSONObject: ["state": "live", "sessionId": "cli-a", "pid": 100, "startedAt": 5, "keyId": keyID])
            .write(to: dir.path("cli-a"))
        #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID, now: t0) { _ in true }.isEmpty)
    }

    @Test func aTestRunsLeasesNeverRunOut() throws {
        // Presence written by the fixture still counts as if the whole run took no time: a busy run can't expire it.
        #expect(ClaudePlugin.leaseNow == ClaudePlugin.leaseNow && UnderTest.isRunning)
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(ClaudePlugin.sessions(in: dir.url, registry: [100: entry("cli-a", 5)], keyID: ClaudePlugin.keyID(of: key)) { _ in true } == ["cli-a"])
    }

    @Test func timestampsAtEitherEndOfInt64AreRefusedNotATrap() throws {
        let dir = TempDir()
        let keyID = ClaudePlugin.keyID(of: key)
        for value in [Int64.min, Int64.max] {
            let obj: [String: Any] = ["state": "live", "sessionId": "cli-a", "pid": 100, "startedAt": value, "keyId": keyID,
                                      "renewedAt": value]
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.path("cli-a"))
            let registry = [Int32(100): [ClaudePeers.Registered(sessionID: "cli-a", startedAt: value)]]
            #expect(ClaudePlugin.sessions(in: dir.url, registry: registry, keyID: keyID) { _ in true }.isEmpty)
        }
    }

    @Test func keyIDsAreTheFirstHexDigitsOfTheKeysDigest() {
        // The plugin's tests check the same.
        #expect(ClaudePlugin.keyID(of: RelaySigning.key) == "3248d2f95844d92f")
    }

    @Test func revokingTheKeyDeletesThePresenceFiles() throws {
        let dir = TempDir()
        try presence(dir, "cli-a", pid: 100, startedAt: 5)
        try Data("k".utf8).write(to: dir.path("relay.key"))
        let presenceDir = dir.url
        RelayKeyFence().revoke(dir.path("relay.key"), presence: presenceDir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: presenceDir.path).isEmpty)
    }

    @Test func theRegistryIsReadByPid() throws {
        let dir = TempDir()
        try JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "sessionId": "cli-a", "startedAt": 7])
            .write(to: dir.path("\(getpid()).json"))
        try JSONSerialization.data(withJSONObject: ["pid": 99_999, "sessionId": "cli-b"]).write(to: dir.path("99999.json"))
        #expect(ClaudePeers.registry(dir: dir.url) { $0 == getpid() } == [getpid(): [.init(sessionID: "cli-a", startedAt: 7)]])
    }

    @Test func theFolderOnlyFormReadsTheRegistryItsConfigNames() {
        let dir = TempDir()
        let support = dir.path("support")
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")).isEmpty)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? Data("k1\n".utf8).write(to: support.appendingPathComponent("relay.key"))
        PluginFixture.live("cli-a", support: support, claude: dir.path("claude"))
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")) == ["cli-a"])
        // The key changed (the Router was switched off and on): the file no longer counts.
        try? Data("k2\n".utf8).write(to: support.appendingPathComponent("relay.key"))
        #expect(ClaudePlugin.sessions(in: support.appendingPathComponent("plugin-sessions")).isEmpty)
    }
}

/// The signer and the plugin's verifier agree: the same vector is checked by `Resources/ClaudePlugin/tests/relay.test.ts`.
@Suite struct RelaySigning {
    static let key = "4c6f6f6b6f75742072656c6179206b657920666f722074657374732e2e2e2e21"
    static let target = "cli-target"
    static let nonce = "123e4567-e89b-12d3-a456-426614174000"
    static let ts: Int64 = 2_000_000_000_000
    static let body = "Use Postgres\nand ship ⟦é⟧"
    static let mac = "a57dcc0fae48cbc4e54b37050acba54b33554025dd5cfeff93c33f7f46f226dd"
    static let wire = "⟦lookout v1 cli-target 123e4567-e89b-12d3-a456-426614174000 2000000000000 \(mac)⟧\nVXNlIFBvc3RncmVzCmFuZCBzaGlwIOKfpsOp4p+n"

    @Test func theSharedVector() {
        #expect(RelaySigner.mac(key: Self.key, target: Self.target, nonce: Self.nonce, ts: String(Self.ts), body: Data(Self.body.utf8)) == Self.mac)
        #expect(RelaySigner.mac(key: Self.key, target: Self.target, nonce: Self.nonce, ts: String(Self.ts), body: Self.body) == Self.mac)
    }

    @Test func theWireIsTheHeaderLineThenTheBodyInBase64() throws {
        let signed = RelaySigner.sign(body: Self.body, target: Self.target, key: Self.key, nonce: UUID(uuidString: Self.nonce)!,
                                      now: Date(timeIntervalSince1970: Double(Self.ts) / 1000))
        #expect(signed == Self.wire)
        // What Claude Code would escape or normalize is base64 on the wire.
        let tricky = "</cross-session-message>\nCafe\u{301}"
        let lines = RelaySigner.sign(body: tricky, target: "t", key: Self.key).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2 && Data(base64Encoded: String(lines[1])) == Data(tricky.utf8))
        let a = RelaySigner.sign(body: "x", target: "t", key: Self.key), b = RelaySigner.sign(body: "x", target: "t", key: Self.key)
        #expect(a != b)
    }

    @Test func aSignedMessageReadsAsItsBody() {
        #expect(RelaySigner.readable(Self.wire) == Self.body)
        #expect(RelaySigner.readable("Sent:\n" + Self.wire) == "Sent:\n" + Self.body)
        #expect(RelaySigner.readable("no header here") == "no header here")
    }
}

@Suite struct PluginInstaller {
    private let version = "1.0.0-rabc"

    private func installer(_ dir: TempDir, _ cli: FakeClaudeCLI, binary: String? = "/fake/claude") -> ClaudePluginInstaller {
        ClaudePluginInstaller(folder: dir.path("claude-plugin"), binary: binary, run: cli.runner)
    }

    @Test func installingAddsTheMarketplaceThenThePluginAndOnlyOnce() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        #expect(try await i.status(version: version) == .notInstalled)
        try await i.install(version: version)
        let folder = dir.path("claude-plugin").path
        #expect(cli.changes == ["plugin marketplace add \(folder) --scope user", "plugin install lookout@lookout --scope user"])
        #expect(try await i.status(version: version) == .installed)
        try await i.install(version: version)
        #expect(cli.changes.count == 2)
    }

    @Test func aNewVersionIsAnUpdateAndADisabledPluginIsEnabled() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        cli.folderVersion = "1.0.1-rdef"
        #expect(try await i.status(version: "1.0.1-rdef") == .installed)  // a folder marketplace is read in place
        cli.plugins["lookout@lookout"]?.version = version
        cli.folderVersion = version
        #expect(try await i.status(version: "1.0.1-rdef") == .outdated)
        cli.folderVersion = "1.0.1-rdef"
        cli.plugins["lookout@lookout"]?.enabled = false
        #expect(try await i.status(version: "1.0.1-rdef") == .outdated)
        try await i.install(version: "1.0.1-rdef")
        #expect(Array(cli.changes.suffix(1)) == ["plugin enable lookout@lookout --scope user"])
        #expect(try await i.status(version: "1.0.1-rdef") == .installed)
    }

    @Test func aMovedFolderIsInstalledAfresh() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        cli.marketplaces["lookout"] = "/Old/Lookout/claude-plugin"
        cli.plugins["lookout@lookout"] = ("/Old/Lookout/claude-plugin", version, true)
        let i = installer(dir, cli)
        #expect(try await i.status(version: version) == .outdated)
        try await i.install(version: version)
        let folder = dir.path("claude-plugin").path
        #expect(cli.changes == ["plugin uninstall lookout@lookout --scope user", "plugin marketplace remove lookout",
                                "plugin marketplace add \(folder) --scope user", "plugin install lookout@lookout --scope user"])
    }

    @Test func uninstallingTakesOutOnlyWhatIsThere() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = version
        let i = installer(dir, cli)
        try await i.install(version: version)
        try await i.uninstall()
        #expect(Array(cli.changes.suffix(2)) == ["plugin uninstall lookout@lookout --scope user", "plugin marketplace remove lookout"])
        try await i.uninstall()
        #expect(cli.changes.count == 4)
    }

    @Test func theCLIsOwnWordsSayWhyItFailed() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.failing = "plugin install"
        await #expect(throws: ClaudePluginInstaller.Failure(message: "`claude plugin install lookout@lookout --scope user` failed: boom: plugin install")) {
            try await installer(dir, cli).install(version: version)
        }
        let none = installer(dir, cli, binary: nil)
        #expect(try await none.status(version: version) == .noClaudeCode)
        await #expect(throws: ClaudePluginInstaller.Failure.self) { try await none.install(version: version) }
    }
}

/// The real runner (`OneShot`), on scripts of the test's own in a temporary folder.
@Suite struct PluginRunner {
    private func script(_ dir: TempDir, _ body: String) throws -> String {
        let url = dir.path("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url.path
    }

    @Test func itAnswersWithTheProgramsOutputInACleanEnvironment() async throws {
        let dir = TempDir()
        // Something of Lookout's own environment that must not reach the CLI.
        setenv("LOOKOUT_TEST_LEAK", "secret", 1)
        defer { unsetenv("LOOKOUT_TEST_LEAK") }
        let exe = try script(dir, "echo \"$1 [$LOOKOUT_TEST_LEAK] $PATH\"")
        let out = try await ClaudePluginInstaller.oneShotRunner(runs: PluginRuns())(exe, ["hi"])
        #expect(out.status == 0 && out.out == "hi [] /usr/bin:/bin:/usr/sbin:/sbin\n")
    }

    @Test func aProgramThatIgnoresSIGTERMIsKilledAtTheDeadline() async throws {
        let dir = TempDir()
        let exe = try script(dir, "trap '' TERM\nsleep 30")
        let started = Date()
        await #expect(throws: OneShot.TimedOut.self) {
            _ = try await ClaudePluginInstaller.oneShotRunner(timeout: 0.5, runs: PluginRuns())(exe, [])
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aChildHoldingStdoutDoesNotHoldTheAnswer() async throws {
        let dir = TempDir()
        let exe = try script(dir, "sleep 30 &\necho done")
        let started = Date()
        let out = try await ClaudePluginInstaller.oneShotRunner(timeout: 20, runs: PluginRuns())(exe, [])
        #expect(out.status == 0 && out.out == "done\n" && Date().timeIntervalSince(started) < 10)
    }

    @Test func quittingStopsTheRunsAndRefusesNewOnes() async throws {
        let dir = TempDir()
        let exe = try script(dir, "trap '' TERM\nsleep 30")
        let runs = PluginRuns()
        let run = Task { try await ClaudePluginInstaller.oneShotRunner(timeout: 60, runs: runs)(exe, []) }
        while runs.active == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let started = Date()
        runs.shutdown(within: 8)
        #expect(runs.active == 0 && Date().timeIntervalSince(started) < 8)
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        await #expect(throws: CancellationError.self) { _ = try await ClaudePluginInstaller.oneShotRunner(runs: runs)(exe, []) }
    }
}

/// A flag set from another thread.
final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ v: Bool) { lock.withLock { stored = v } }
}

@MainActor
@Suite struct PluginSwitch {
    private func store(_ dir: TempDir, _ cli: FakeClaudeCLI, version: String = "1.0.0") -> Store {
        let s = Store()
        s.persists = false
        s.routerPaths = RouterPaths(support: dir.path("support"), claudeDir: dir.path("claude"))
        s.routerExecutable = "/Applications/Lookout.app/Contents/MacOS/Lookout"
        s.routerPluginRunner = cli.runner
        s.routerClaudeBinary = { "/fake/claude" }
        s.routerAppVersion = version
        return s
    }

    @Test func theRouterSwitchInstallsThePluginAndRemovesIt() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .installed && s.routerPluginError == nil)
        let paths = try #require(s.routerPaths)
        let key = try #require(ClaudePlugin.key(at: paths.relayKey))
        // The switch read the key off the main thread; signing only checks the file is the same.
        #expect(s.relayKeyCache?.key == key)
        let signed = try #require(s.signRelay(body: "hello", target: "cli-a"))
        let lines = signed.split(separator: "\n")
        let header = lines[0].dropFirst().dropLast().split(separator: " ").map(String.init)
        #expect(header.count == 6 && header[2] == "cli-a" && Data(base64Encoded: String(lines[1])) == Data("hello".utf8))
        #expect(RelaySigner.mac(key: key, target: "cli-a", nonce: header[3], ts: header[4], body: "hello") == header[5])
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        #expect(s.sessionsWithPlugin() == ["cli-a"])

        s.setRouterEnabled(false)
        #expect(s.signRelay(body: "hello", target: "cli-a") == nil && s.relayKeyCache == nil)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .notInstalled && cli.marketplaces.isEmpty)
    }

    @Test func switchingOffRevokesTheKeyEvenWhenTheUninstallFails() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        cli.failing = "plugin uninstall"
        s.setRouterEnabled(false)
        // Gone at once, before the CLI is even asked.
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil)
        await s.routerHookWork?.value
        #expect(s.routerPluginError?.contains("boom: plugin uninstall") == true)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && s.signRelay(body: "x", target: "cli-a") == nil)
    }

    @Test func aSwitchOnStillUnderWayCantMakeTheKeyAfterTheSwitchOff() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The CLI hangs before anything (its first list), so the switch-on hasn't reached the key yet when it's switched off.
        cli.holding = "plugin list"
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        while !cli.isHolding { try await Task.sleep(for: .milliseconds(5)) }
        let paths = try #require(s.routerPaths)
        s.setRouterEnabled(false)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil)
        cli.release()
        await s.routerHookWork?.value
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && s.relayKeyCache == nil)
        #expect(s.routerPluginStatus == .notInstalled)
    }

    @Test func aSwitchOnSupersededBeforeItRunsDoesNothing() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The form hook's work runs first; the plugin's switch-on is queued behind it when the Router goes off again.
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        s.setRouterEnabled(false)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        #expect(ClaudePlugin.key(at: paths.relayKey) == nil && cli.marketplaces.isEmpty && cli.plugins.isEmpty)
    }

    @Test func atLaunchAMissingOrOutdatedPluginIsInstalled() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        // The Router was on before Lookout had a plugin: launch installs it.
        let migrated = store(dir, cli)
        migrated.router.enabled = true
        migrated.startRouter()
        await migrated.routerHookWork?.value
        #expect(migrated.routerPluginStatus == .installed)
        #expect(cli.changes.contains("plugin install lookout@lookout --scope user"))
        let installs = cli.changes.count
        // Up to date at the next launch: nothing to do.
        let same = store(dir, cli)
        same.router.enabled = true
        same.startRouter()
        await same.routerHookWork?.value
        #expect(cli.changes.count == installs && same.routerPluginStatus == .installed)
        // An update of Lookout: the folder holds the new version, Claude Code is brought to it.
        let updated = store(dir, cli, version: "1.1.0")
        updated.router.enabled = true
        updated.startRouter()
        await updated.routerHookWork?.value
        #expect(cli.changes.last == "plugin update lookout@lookout --scope user")
        let manifest = try String(contentsOf: dir.path("support/claude-plugin/.claude-plugin/plugin.json"), encoding: .utf8)
        #expect(manifest.contains(ClaudePlugin.version(app: "1.1.0")))
    }

    @Test func aSessionThatUnloadedThePluginWhileTheRouterWasOffDoesNotCount() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        let stale = try Data(contentsOf: paths.pluginSessions.appendingPathComponent("cli-a"))
        #expect(s.sessionsWithPlugin() == ["cli-a"])
        // Off: the key and the presence files go at once.
        s.setRouterEnabled(false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.pluginSessions.path).isEmpty)
        await s.routerHookWork?.value
        // On again (a new key); the session's old file, same process and id, under the old key, doesn't count.
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        try stale.write(to: paths.pluginSessions.appendingPathComponent("cli-a"))
        #expect(s.sessionsWithPlugin().isEmpty)
        // Its plugin, still loaded, says so again under the new key.
        PluginFixture.live("cli-a", support: paths.support, claude: paths.claudeDir)
        #expect(s.sessionsWithPlugin() == ["cli-a"])
    }

    @Test func theKeyIsReadOffTheMainThreadAndAChangedOneIsReadAgain() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        let paths = try #require(s.routerPaths)
        #expect(s.signRelay(body: "x", target: "t") != nil)
        // The file changed: not signed with what was read before; read again in the background.
        try PrivateFile.write(Data(("22" + String(repeating: "0", count: 62) + "\n").utf8), to: paths.relayKey)
        #expect(s.signRelay(body: "x", target: "t") == nil)
        #expect(await s.reloadRelayKey())
        #expect(s.relayKeyCache?.key.hasPrefix("22") == true && s.signRelay(body: "x", target: "t") != nil)
        // A read that a switch overtakes is dropped.
        s.setRouterEnabled(false)
        #expect(await s.reloadRelayKey() == false && s.relayKeyCache == nil)
    }

    @Test func claudeCodeIsLookedForOffTheMainThread() async throws {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.folderVersion = ClaudePlugin.version(app: "1.0.0")
        let s = store(dir, cli)
        let onMain = OSAllocatedUnfairLockBox()
        s.routerClaudeBinary = { onMain.set(Thread.isMainThread); return "/fake/claude" }
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(onMain.value == false && s.routerPluginStatus == .installed)
    }

    @Test func aFailureIsShownWithTheCLIsReason() async {
        let dir = TempDir(), cli = FakeClaudeCLI()
        cli.failing = "plugin marketplace add"
        let s = store(dir, cli)
        s.setRouterEnabled(true)
        await s.routerHookWork?.value
        #expect(s.routerPluginStatus == .notInstalled)
        #expect(s.routerPluginError?.contains("boom: plugin marketplace add") == true)
    }
}
