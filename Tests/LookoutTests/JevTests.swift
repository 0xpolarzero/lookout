import AppKit
import Foundation
import Testing
@testable import Lookout

/// Answers every request with a canned response and remembers the last request body.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var lastAuth: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            body = data
        }
        Self.lastBody = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.lastAuth = request.value(forHTTPHeaderField: "Authorization")
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct Jev {
    private func client() -> JevClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return JevClient(key: "ts-test", session: URLSession(configuration: config))
    }

    @Test func sendsTheDocumentedShapeAndMapsTheAnswerBack() async throws {
        StubProtocol.status = 200
        StubProtocol.response = Data(#"{"model":"jev-1.13.0","answers":{"pick":{"type":"choice","choice":"chart_bar","probabilities":{"chart_bar":0.9,"ladybug":0.1},"confidence":0.82}},"usage":{"input_tokens":312,"output_tokens":0}}"#.utf8)
        let pick = try await client().choose(["chart.bar", "ladybug"], for: ["session title": "Usage dashboard"], instructions: "Pick one")
        #expect(pick.choice == "chart.bar")
        #expect(pick.confidence == 0.82)
        let body = try #require(StubProtocol.lastBody)
        #expect(body["model"] as? String == "jev-latest")
        #expect((body["state"] as? [String: String])?["session title"] == "Usage dashboard")
        let question = try #require((body["questions"] as? [String: Any])?["pick"] as? [String: Any])
        #expect(question["type"] as? String == "choice")
        #expect(question["instructions"] as? String == "Pick one")
        let criteria = try #require(question["criteria"] as? [String: Any])
        #expect(Set(criteria.keys) == ["chart_bar", "ladybug"])
        #expect(criteria["ladybug"] is NSNull)
        #expect(StubProtocol.lastAuth == "Bearer ts-test")
    }

    @Test func rejectedKeyAndOddAnswersAreErrors() async {
        StubProtocol.status = 401
        StubProtocol.response = Data("{}".utf8)
        await #expect(throws: JevClient.Failure.self) { try await client().choose(["key"], for: [:], instructions: "") }
        StubProtocol.status = 200
        StubProtocol.response = Data(#"{"answers":{"pick":{"choice":"not_offered"}}}"#.utf8)
        await #expect(throws: JevClient.Failure.self) { try await client().choose(["key"], for: [:], instructions: "") }
    }

    @Test func sendsHintsAndReadsProbabilities() async throws {
        StubProtocol.status = 200
        StubProtocol.response = Data(#"{"answers":{"pick":{"choice":"debug","probabilities":{"debug":0.7,"code":0.3},"confidence":0.6}}}"#.utf8)
        let pick = try await client().choose(["code", "debug"], hints: ["debug": "Bugs and tests"], for: [:], instructions: "")
        #expect(pick.probabilities == ["debug": 0.7, "code": 0.3])
        let question = try #require((StubProtocol.lastBody?["questions"] as? [String: Any])?["pick"] as? [String: Any])
        let criteria = try #require(question["criteria"] as? [String: Any])
        #expect(criteria["debug"] as? String == "Bugs and tests")
        #expect(criteria["code"] is NSNull)
        // No probabilities in the answer: the choice gets them all.
        StubProtocol.response = Data(#"{"answers":{"pick":{"choice":"code"}}}"#.utf8)
        #expect(try await client().choose(["code", "debug"], for: [:], instructions: "").probabilities == ["code": 1])
    }

    @Test func iconCategoriesFitJev() {
        let all = SessionIcons.categories.flatMap(\.icons)
        #expect(all.count > 600)
        #expect(Set(all).count == all.count, "an icon is in two categories")
        #expect(Set(SessionIcons.categories.map(\.key)).count == SessionIcons.categories.count)
        #expect(SessionIcons.categories.count <= SessionIcons.maxOptions)
        // Any two categories fit in one question (the runner-up joins the best one when Jev is torn).
        let sizes = SessionIcons.categories.map(\.icons.count).sorted(by: >)
        #expect(sizes[0] + sizes[1] <= SessionIcons.maxOptions)
        // Keys stay distinct once dots become underscores.
        #expect(Set(all.map(JevClient.key)).count == all.count)
        #expect(Set(SessionIcons.hints.keys).isSubset(of: all))
        // Only a few symbols are newer than macOS 14; everything exists on a current macOS.
        let missing = all.filter { !SessionIcons.drawable.contains($0) }
        #expect(missing.count < 30, "missing symbols: \(missing)")
    }

    /// Apple's own symbol metadata (private, so only checked when it's there): no restricted symbols, and no two
    /// names for the same glyph (Apple renamed many symbols and keeps the old names working).
    @Test func iconsAreAllowedAndDistinct() throws {
        let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        func plist(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: resources.appendingPathComponent(name)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        }
        guard let restricted = plist("symbol_restrictions.strings"), let aliases = plist("name_aliases.strings") as? [String: String] else { return }
        let all = SessionIcons.categories.flatMap(\.icons)
        #expect(all.filter { restricted[$0] != nil || restricted[aliases[$0] ?? ""] != nil } == [])
        let glyphs = Dictionary(grouping: all) { aliases[$0] ?? $0 }
        #expect(glyphs.values.filter { $0.count > 1 } == [])
    }

    @Test func iconsFromAnOlderListArePickedAgain() throws {
        let old = #"{"entries":[{"id":"a","kept":true,"unread":false,"seen":"","label":"AB","icon":"hammer","rejectedIcons":["ant"]}]}"#
        let state = try JSONDecoder().decode(AgentsState.self, from: Data(old.utf8))
        #expect(state.entries[0].icon == nil && state.entries[0].rejectedIcons == nil)
        #expect(state.entries[0].label == "AB")
        let saved = try JSONDecoder().decode(AgentsState.self, from: JSONEncoder().encode(state))
        #expect(saved.iconsVersion == AgentsState.icons)
        var picked = saved
        picked.entries[0].icon = "ladybug"
        #expect(try JSONDecoder().decode(AgentsState.self, from: JSONEncoder().encode(picked)).entries[0].icon == "ladybug")
    }

    @Test func shortlistAddsTheRunnerUpOnlyWhenClose() {
        let open = SessionIcons.open(excluding: [])
        func keys(_ icons: [String]) -> Set<String> {
            Set(open.filter { !Set($0.icons).isDisjoint(with: icons) }.map(\.category.key))
        }
        #expect(keys(SessionIcons.shortlist(open, probabilities: ["debug": 0.8, "code": 0.15])) == ["debug"])
        #expect(keys(SessionIcons.shortlist(open, probabilities: ["debug": 0.5, "code": 0.3])) == ["debug", "code"])
        // Icons on screen are never offered, and a category with none left is gone.
        let debug = SessionIcons.categories.first { $0.key == "debug" }!
        let rest = SessionIcons.open(excluding: Set(debug.icons))
        #expect(!rest.contains { $0.category.key == "debug" })
        #expect(SessionIcons.shortlist(rest, probabilities: ["debug": 1]).count <= SessionIcons.maxOptions)
    }

    @Test func firstMessageSkipsCommandsAndNotes() {
        func line(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! }
        let head = [
            line(["type": "system"]),
            line(["type": "user", "isMeta": true, "message": ["content": "Caveat: …"]]),
            line(["type": "user", "message": ["content": "<command-name>/clear</command-name>"]]),
            line(["type": "user", "message": ["content": [["type": "text", "text": "  Fix the flaky CI on main  "]]]]),
            line(["type": "user", "message": ["content": "second message"]]),
        ].joined(separator: "\n")
        #expect(Claude.firstMessage(head: Data(head.utf8)) == "Fix the flaky CI on main")
    }
}
