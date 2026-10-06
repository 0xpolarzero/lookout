import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct RepoUndoTests {
    @Test func stoppingWatchingOffersUndoFromAnywhere() {
        let s = Store()
        s.persists = false
        s.undoStack.announce = { _ in }
        s.repos = [RepoConfig(fullName: "a/one"), RepoConfig(fullName: "a/two")]
        s.stopWatching(s.repos[0])
        #expect(s.undoStack.visible(in: .controls)?.message == "Stopped watching a/one")
        s.undoStack.dismiss()
        #expect(s.repos.map(\.fullName) == ["a/two"])
        #expect(s.undoLast())
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
