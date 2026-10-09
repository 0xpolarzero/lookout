import Foundation
import Testing
@testable import Lookout

/// A folder of a test's own, removed after.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

func mode(_ url: URL) -> Int? {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
}

let sampleInput: [String: Any] = ["questions": [
    ["question": "Which database?", "header": "DB", "multiSelect": false,
     "options": [["label": "Postgres", "description": "Relational"], ["label": "SQLite", "description": "A file"]]],
    ["question": "Which features?", "header": "Features", "multiSelect": true,
     "options": [["label": "Auth", "description": ""], ["label": "Billing", "description": ""]]],
]]

/// What the hook leaves in the forms folder, and how Lookout answers it.
@Suite struct Forms {
    private func pendingFile(_ key: String, session: String = "cli-1", created: Int64 = 1000, pid: Int32 = getpid()) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "key": key, "session_id": session, "transcript_path": "/tmp/t.jsonl", "cwd": "/code/app",
            "tool_input": sampleInput, "created_at": created, "pid": Int(pid),
        ] as [String: Any])
    }

    @Test func aPendingFileIsReadIntoItsQuestions() throws {
        let form = try #require(PendingForm.decode(pendingFile("k1")))
        #expect(form.id == "k1" && form.cliSessionID == "cli-1" && form.transcriptPath == "/tmp/t.jsonl" && form.pid == getpid())
        #expect(form.questions.map(\.question) == ["Which database?", "Which features?"])
        #expect(form.questions[0].options == [.init(label: "Postgres", description: "Relational"), .init(label: "SQLite", description: "A file")])
        #expect(form.questions[1].multiSelect && form.questions[0].header == "DB")
        #expect(form.createdAt == Date(timeIntervalSince1970: 1))
        #expect(PendingForm.decode(Data("{}".utf8)) == nil)
    }

    @Test func theFolderListsTheNewestFormOfEachLiveSessionAndClearsDeadOnes() throws {
        let dir = TempDir()
        try pendingFile("old", created: 1000).write(to: dir.path("old.json"))
        try pendingFile("new", created: 2000).write(to: dir.path("new.json"))
        try pendingFile("other", session: "cli-2").write(to: dir.path("other.json"))
        try pendingFile("dead", session: "cli-3", pid: 99_999).write(to: dir.path("dead.json"))
        try Data("{}".utf8).write(to: dir.path("dead.answer.json"))
        try Data("{}".utf8).write(to: dir.path("new.answer.json"))
        let forms = FormBridge.read(dir: dir.url) { $0 != 99_999 }
        #expect(forms.mapValues(\.id) == ["cli-1": "new", "cli-2": "other"])
        #expect(!FileManager.default.fileExists(atPath: dir.path("dead.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.path("dead.answer.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.path("old.json").path))
    }

    @Test func anAnswerNeedsEveryQuestionAndTakesAnyText() throws {
        let form = try #require(PendingForm.decode(pendingFile("k")))
        #expect(throws: FormBridge.Failure.unanswered("Which features?")) {
            try FormBridge.validate(form, ["Which database?": "Postgres"])
        }
        #expect(throws: FormBridge.Failure.empty("Which features?")) {
            try FormBridge.validate(form, ["Which database?": "Postgres", "Which features?": "  "])
        }
        #expect(throws: FormBridge.Failure.unknown("Color?")) {
            try FormBridge.validate(form, ["Which database?": "Postgres", "Which features?": "Auth", "Color?": "Red"])
        }
        // Your own words count: the form always has "Other".
        let ok = try FormBridge.validate(form, ["Which database?": " MySQL ", "Which features?": FormBridge.joined(["Auth", "Billing"])])
        #expect(ok == ["Which database?": "MySQL", "Which features?": "Auth, Billing"])
    }

    @Test func theAnswerIsWrittenPrivatelyForTheHook() throws {
        let dir = TempDir()
        let form = try #require(PendingForm.decode(pendingFile("k")))
        try FormBridge.answer(form, answers: ["Which database?": "SQLite", "Which features?": "Auth"], in: dir.url)
        let url = FormBridge.answerURL("k", in: dir.url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: String]]
        #expect(obj?["answers"] == ["Which database?": "SQLite", "Which features?": "Auth"])
        #expect(mode(url) == 0o600)
        // Nothing half-written is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["k.answer.json"])
    }

    @Test func theMarkerFollowsTheSwitch() throws {
        let dir = TempDir()
        let forms = dir.path("forms")
        try FormBridge.setEnabled(true, dir: forms)
        #expect(FileManager.default.fileExists(atPath: forms.appendingPathComponent(".enabled").path))
        #expect(mode(forms) == 0o700)
        try FormBridge.setEnabled(false, dir: forms)
        try FormBridge.setEnabled(false, dir: forms)
        #expect(!FileManager.default.fileExists(atPath: forms.appendingPathComponent(".enabled").path))
    }

    @Test func peersAreTheLiveProcessesByDesktopSession() throws {
        let dir = TempDir()
        func write(_ pid: Int32, _ obj: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: obj).write(to: dir.path("\(pid).json"))
        }
        try write(getpid(), ["pid": Int(getpid()), "sessionId": "cli-1", "hostSessionId": "local_a", "name": "Fix the bar", "status": "idle"])
        try write(99_999, ["pid": 99_999, "sessionId": "cli-2", "hostSessionId": "local_b", "name": "Gone", "status": "busy"])
        try write(4242, ["pid": 4242, "sessionId": "cli-3", "name": "Not a desktop session"])
        try Data("nope".utf8).write(to: dir.path("1.json"))
        let peers = ClaudePeers.read(dir: dir.url) { $0 == getpid() || $0 == 4242 }
        #expect(peers == ["local_a": .init(name: "Fix the bar", status: "idle", pid: getpid())])
        #expect(FormBridge.processAlive(getpid()) && !FormBridge.processAlive(0))
    }
}
