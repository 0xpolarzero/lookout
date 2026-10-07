import Foundation
import Testing
@testable import Lookout

/// A Keychain of a test's own, in memory.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    var accounts: Set<String> { lock.withLock { Set(items.keys) } }
    func read(_ account: String) -> String? { lock.withLock { items[account] } }
    func write(_ secret: String, _ account: String) -> Bool { lock.withLock { items[account] = secret }; return true }
    func delete(_ account: String) { lock.withLock { items[account] = nil } }
}

/// What reached for the real thing while `body` ran, said by the guard in `UnderTest` instead of stopping the run. These
/// tests only ever name accounts, files and addresses of their own, and stop before anything if the process is not a test run.
private final class Reached: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    var all: [String] { lock.withLock { said } }

    static func during(_ body: () async throws -> Void) async rethrows -> [String] {
        let reached = Reached()
        let before = UnderTest.onReach
        UnderTest.onReach = { what in reached.lock.withLock { reached.said.append(what) } }
        defer { UnderTest.onReach = before }
        try await body()
        return reached.all
    }
}

/// The tests are hermetic: nothing in a test run reaches the user's Keychain, saved state, notifications, login item, `gh`,
/// other apps or the network. The code that would asks `UnderTest` first, and it stops the run unless the test stood
/// something in for it.
@MainActor
@Suite(.serialized) struct Hermetic {
    @Test func aTestRunIsRecognisedWhicheverRunnerStartedIt() {
        #expect(UnderTest.isRunning)
    }

    @Test func theKeychainIsNotReachedUnlessATestStoodSomethingInForIt() async throws {
        try #require(UnderTest.isRunning)
        var read: String?
        var written = true
        let reached = await Reached.during {
            read = Keychain.read("lookout-test-never")
            written = Keychain.write("secret", "lookout-test-never")
            Keychain.delete("lookout-test-never")
        }
        #expect(read == nil && !written)
        #expect(reached.count == 3 && reached.allSatisfy { $0.hasPrefix("the Keychain") })
    }

    @Test func aKeychainOfATestsOwnTakesTheKeysAndTheTokenAndNothingReachesTheRealOne() async throws {
        try #require(UnderTest.isRunning)
        let secrets = MemorySecrets()
        Keychain.backend = secrets
        defer { Keychain.backend = nil }
        let reached = await Reached.during {
            let s = Store()
            s.persists = false
            s.gh.session = StubbedGitHub.session { _ in .init(200, "[]") }
            s.resolveToken = { nil }
            #expect(s.setToken("ghp_test") && secrets.read(Keychain.github) == "ghp_test")
            #expect(Keychain.read() == "ghp_test")
            // Taking a token away removes it, which no test could do before without deleting the real one.
            #expect(s.setToken(nil) && secrets.read(Keychain.github) == nil)
            #expect(s.setTypesafeKey(" sk-test ") && secrets.read(Keychain.typesafe) == "sk-test")
            #expect(s.setTypesafeKey(nil) && secrets.accounts.isEmpty)
        }
        #expect(reached.isEmpty)
    }

    @Test func theUsersSavedStateIsNotReachedByAStoreWithoutAFileOfItsOwn() async throws {
        try #require(UnderTest.isRunning)
        let reached = await Reached.during {
            let s = Store()
            s.repos = [RepoConfig(fullName: "a/one")]
            s.save()
        }
        #expect(reached.count == 1 && reached[0].contains("state.json"))
    }

    @Test func aStoreWithAFileOfItsOwnSavesThereAndOnlyThere() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let reached = try await Reached.during {
            let s = Store()
            s.stateFile = file
            s.repos = [RepoConfig(fullName: "a/one")]
            s.save()
            s.flushSave()
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let saved = try dec.decode(PersistedState.self, from: Data(contentsOf: file))
            #expect(saved.repos.map(\.fullName) == ["a/one"])
        }
        #expect(reached.isEmpty)
    }

    @Test func theTokenLookupAndGhAreNotReachedFromATest() async throws {
        try #require(UnderTest.isRunning)
        var found: (String, TokenSource)?
        let reached = await Reached.during { found = TokenProvider.resolve() }
        #expect(found == nil && reached.count == 1 && reached[0].contains("token lookup"))
    }

    @Test func theLoginItemAndOtherAppsAreNotReachedFromATest() async throws {
        try #require(UnderTest.isRunning)
        let reached = await Reached.during {
            try? LaunchAtLogin.set(true)
            Link.open(URL(string: "https://example.invalid/")!)
        }
        #expect(reached.count == 2 && reached[0].contains("login item") && reached[1].contains("example.invalid"))
    }

    @Test func theNetworkIsNotReachedFromATestButAFileOnThisDiskIsNotTheNetwork() async throws {
        try #require(UnderTest.isRunning)
        var failure: Error?
        let reached = await Reached.during {
            do { _ = try await Network.session.data(from: URL(string: "https://example.invalid/")!) } catch { failure = error }
        }
        #expect(reached.count == 1 && reached[0].contains("example.invalid") && (failure as? URLError)?.code == .notConnectedToInternet)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-test-\(UUID().uuidString)")
        try Data("ok".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (data, _) = try await Network.session.data(from: file)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
    }
}
