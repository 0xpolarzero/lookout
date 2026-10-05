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

    @Test func iconListFitsJevAndExists() {
        #expect(SessionIcons.available.count > 200)
        #expect(SessionIcons.available.count <= 255)
        #expect(Set(SessionIcons.available).count == SessionIcons.available.count)
        let missing = SessionIcons.candidates.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        #expect(missing.count < 10, "missing symbols: \(missing)")
        // Keys stay distinct once dots become underscores.
        #expect(Set(SessionIcons.available.map(JevClient.key)).count == SessionIcons.available.count)
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
