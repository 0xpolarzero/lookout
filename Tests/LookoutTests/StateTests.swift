import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct State {
    private func item(_ id: String, state: ItemState = .unread) -> InboxItem {
        inboxItem(id, at: Date(timeIntervalSince1970: 1000), state: state)
    }

    private func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// A state file as an older version wrote it: the JSON with the given keys taken out of every object.
    private func old(_ state: PersistedState, without keys: Set<String>) throws -> Data {
        func strip(_ any: Any) -> Any {
            if let dict = any as? [String: Any] { return dict.filter { !keys.contains($0.key) }.mapValues(strip) }
            if let array = any as? [Any] { return array.map(strip) }
            return any
        }
        let json = try JSONSerialization.jsonObject(with: encoder().encode(state))
        return try JSONSerialization.data(withJSONObject: strip(json))
    }

    @Test func leavingTheInboxStampsWhenAndComingBackClearsIt() {
        var open = item("1")
        #expect(open.clearedAt == nil)
        open.state = .read
        #expect(open.clearedAt == nil)
        open.state = .discarded
        #expect(open.clearedAt != nil)
        let stamp = open.clearedAt
        open.state = .resolved  // still out: the first stamp stands
        #expect(open.clearedAt == stamp)
        open.state = .read
        #expect(open.clearedAt == nil)
    }

    @Test func storeStampsDiscardedItemsAndClearsRestoredOnes() {
        let s = Store.unsaved()
        s.items = [item("1")]
        s.discard(s.items[0])
        #expect(s.items[0].clearedAt != nil)
        s.restore(s.items[0])
        #expect(s.items[0].clearedAt == nil)
    }

    @Test func newFieldsRoundTrip() throws {
        var cleared = item("1")
        cleared.state = .discarded
        cleared.clearedAt = Date(timeIntervalSince1970: 2000)  // whole seconds: the file keeps no more
        let state = PersistedState(repos: [], items: [cleared], ci: [:], settings: AppSettings(), agents: nil,
                                   mutedCI: ["a/b": "abc123"])
        let back = try decoder().decode(PersistedState.self, from: encoder().encode(state))
        #expect(back.mutedCI == ["a/b": "abc123"])
        #expect(back.items[0].clearedAt == cleared.clearedAt)
    }

    @Test func stateFilesFromBeforeTheNewFieldsStillLoad() throws {
        var cleared = item("1")
        cleared.state = .discarded
        let state = PersistedState(repos: [], items: [cleared], ci: [:], settings: AppSettings(), agents: AgentsState(),
                                   mutedCI: ["a/b": "abc123"])
        let data = try old(state, without: ["mutedCI", "clearedAt"])
        let back = try decoder().decode(PersistedState.self, from: data)
        #expect(back.mutedCI == nil)
        #expect(back.items.count == 1)
        #expect(back.items[0].clearedAt == nil)
        #expect(back.items[0].state == .discarded)
    }

    @Test func paletteHasFourColoursAndOldIndicesAreRemappedNotDropped() throws {
        #expect(Theme.projectColors.count == 4)
        #expect(Theme.projectColorNames == ["Violet", "Pink", "Cyan", "Silver"])
        var agents = AgentsState()
        agents.folderColors = ["/a": 0, "/b": 1, "/c": 2, "/d": 3, "/e": 4, "/f": 5]
        agents.paletteVersion = 2
        // Written by the previous version: palette 2.
        var json = try #require(JSONSerialization.jsonObject(with: encoder().encode(agents)) as? [String: Any])
        json["paletteVersion"] = 2
        let back = try decoder().decode(AgentsState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.folderColors.count == 6)
        #expect(back.folderColors.values.allSatisfy { Theme.projectColors.indices.contains($0) })
        // Violet, pink, cyan and silver keep their colour (their index moved).
        #expect(back.folderColors["/b"] == 0)
        #expect(back.folderColors["/c"] == 1)
        #expect(back.folderColors["/d"] == 2)
        #expect(back.folderColors["/f"] == 3)
        #expect(back.paletteVersion == AgentsState.palette)
    }

    @Test func currentPaletteIsKeptAsIs() throws {
        var agents = AgentsState()
        agents.folderColors = ["/a": 3, "/b": 0]
        let back = try decoder().decode(AgentsState.self, from: encoder().encode(agents))
        #expect(back.folderColors == ["/a": 3, "/b": 0])
    }

    @Test func aPaletteWeDontKnowIsPickedAgain() throws {
        var json = try #require(JSONSerialization.jsonObject(with: encoder().encode(AgentsState())) as? [String: Any])
        json["folderColors"] = ["/a": 1]
        json.removeValue(forKey: "paletteVersion")
        let back = try decoder().decode(AgentsState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.folderColors.isEmpty)
    }

    @Test func removingARepoForgetsItsMute() {
        let s = Store.unsaved()
        s.repos = [RepoConfig(fullName: "a/one")]
        s.mutedCI = ["a/one": "abc", "a/two": "def"]
        s.removeRepo(s.repos[0])
        #expect(s.mutedCI == ["a/two": "def"])
    }
}
