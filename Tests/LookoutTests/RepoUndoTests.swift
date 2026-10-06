import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct RepoUndoTests {
    private func undo(lifetime: Duration = .seconds(60)) -> RepoUndo {
        let undo = RepoUndo()
        undo.announce = { _ in }
        undo.lifetime = lifetime
        return undo
    }

    @Test func theLineGoingAwayKeepsTheUndo() async throws {
        let undo = undo(lifetime: .milliseconds(30))
        var reverted = false
        undo.push("Stopped watching a/one") { reverted = true }
        #expect(undo.visible?.message == "Stopped watching a/one")
        try await Task.sleep(for: .milliseconds(200))
        #expect(undo.visible == nil)
        #expect(undo.entries.count == 1)
        #expect(undo.undo())
        #expect(reverted)
    }

    @Test func anUndoLapsesAfterThirtySeconds() {
        let undo = undo()
        let start = Date()
        var reverted = false
        undo.push("Stopped watching a/one", now: start) { reverted = true }
        #expect(!undo.undo(now: start.addingTimeInterval(RepoUndo.validFor + 1)))
        #expect(!reverted)
        undo.push("Stopped watching a/one", now: start) { reverted = true }
        #expect(undo.undo(now: start.addingTimeInterval(RepoUndo.validFor - 1)))
        #expect(reverted)
    }

    @Test func undoTakesBackTheNewestFirstAndHidesTheLine() {
        let undo = undo()
        var order: [String] = []
        undo.push("one") { order.append("one") }
        undo.push("two") { order.append("two") }
        #expect(undo.visible?.message == "two")
        undo.undo()
        #expect(undo.visible == nil)
        undo.undo()
        #expect(order == ["two", "one"])
        #expect(!undo.undo())
    }

    @Test func stoppingWatchingOffersUndoFromAnywhere() {
        let s = Store()
        s.persists = false
        s.repoUndo.announce = { _ in }
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two")]
        s.stopWatching(s.repos[0])
        #expect(s.repoUndo.visible?.message == "Stopped watching a/one")
        s.repoUndo.dismiss()
        #expect(s.repos.map(\.fullName) == ["a/two"])
        #expect(s.repoUndo.undo())
        #expect(s.repos.map(\.fullName) == ["a/one", "a/two"])
    }
}

@MainActor
@Suite struct EscapeRouteTests {
    @Test func theNewestRegistrationAnswersAndNothingMeansEscNavigates() {
        let first = UUID(), second = UUID()
        var ran: [String] = []
        #expect(!EscapeRoute.run())
        EscapeRoute.register(first) { ran.append("first") }
        EscapeRoute.register(second) { ran.append("second") }
        #expect(EscapeRoute.run())
        EscapeRoute.unregister(second)
        #expect(EscapeRoute.run())
        EscapeRoute.unregister(first)
        #expect(!EscapeRoute.run())
        #expect(ran == ["second", "first"])
    }
}
