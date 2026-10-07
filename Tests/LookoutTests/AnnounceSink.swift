import Testing
@testable import Lookout

/// `Announce.sink` is one per process, and a test that installs it may wait (a poll, a sign-in) while others run on the main
/// actor. Every test that installs it does so here, one at a time, so none resets or fills another's.
@MainActor
enum Announced {
    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with `Announce.sink` to itself, and leaves it as it found it: unset.
    static func exclusively(_ body: () async -> Void) async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        }
        busy = true
        Announce.reset()
        await body()
        Announce.reset()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
