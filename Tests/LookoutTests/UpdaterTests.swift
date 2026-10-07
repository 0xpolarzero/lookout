import CryptoKit
import Foundation
import Testing
@testable import Lookout

@Suite struct Updates {
    @Test func versionsCompareNumerically() throws {
        #expect(try #require(Version("0.10.0")) > #require(Version("0.9.3")))
        #expect(try #require(Version("v1.2")) == #require(Version("1.2.0")))
        #expect(try #require(Version("1.2.1")) > #require(Version("1.2")))
        #expect(try #require(Version("0.2.0")) < #require(Version("0.2.1")))
        #expect(Version("0.0.0-dev") != nil)
        #expect(Version("latest") == nil)
        #expect(Version("") == nil)
    }

    @MainActor @Test func devBuildsNeverUpdate() {
        // Tests don't run from a release bundle.
        #expect(!Updater().isRelease)
    }

    @MainActor @Test func aReleaseWithoutChecksumIsNeverStaged() async throws {
        let updater = Updater(forceRelease: true)
        updater.preview(.available)
        #expect(updater.release?.checksum == nil)
        updater.download()
        // It fails before fetching anything, so it settles without the network.
        for _ in 0..<100 { if updater.phase != .downloading(0) { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard case .failed(let message) = updater.phase else { Issue.record("phase \(updater.phase)"); return }
        #expect(message.contains("no checksum"))
        #expect(updater.stagedPath == nil)
    }

    @MainActor @Test(arguments: [true, false]) func aChecksumFailureShowsOnEveryCheck(manual: Bool) async throws {
        let updater = Updater(current: "0.0.1", forceRelease: true)
        let page = URL(string: "https://example.com")!
        updater.latest = { Updater.Release(version: "9.9.9", zip: page, checksum: nil, page: page) }
        await updater.update(manual: manual)
        for _ in 0..<100 { if case .downloading = updater.phase { try await Task.sleep(for: .milliseconds(20)) } else { break } }
        guard case .failed(let message) = updater.phase else { Issue.record("phase \(updater.phase)"); return }
        #expect(message.contains("no checksum"))
        // The next check tries again rather than leaving the failure for good.
        await updater.update(manual: manual)
        for _ in 0..<100 { if case .downloading = updater.phase { try await Task.sleep(for: .milliseconds(20)) } else { break } }
        guard case .failed = updater.phase else { Issue.record("phase \(updater.phase)"); return }
    }

    @Test func checksumMustMatchTheZip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-checksum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("Lookout-1.0.0.zip")
        let contents = Data("zip".utf8)
        try contents.write(to: zip)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        func checksum(_ text: String) throws -> URL {
            let file = dir.appendingPathComponent(UUID().uuidString + ".sha256")
            try Data(text.utf8).write(to: file)
            return file
        }
        try await Updater.verifyChecksum(of: zip, against: checksum("\(digest.uppercased())  Lookout-1.0.0.zip\n"))
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: checksum(String(repeating: "0", count: 64))) }
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: checksum("")) }
        await #expect(throws: UpdateError.self) { try await Updater.verifyChecksum(of: zip, against: dir.appendingPathComponent("missing.sha256")) }
    }
}
