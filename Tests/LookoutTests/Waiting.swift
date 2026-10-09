import Foundation

/// Waits for `condition`, which something the test started brings about: returns as soon as it holds. `seconds` is a
/// watchdog, not a guess at how long the work takes: a runner many times slower still gets there, and the assertion
/// after the wait says what didn't happen.
@MainActor func waitUntil(within seconds: TimeInterval = 60, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Waits until `value` reads the same over `turns` consecutive turns of the main actor: what SwiftUI had pending (a
/// layout, an update) has happened, however slowly it ran. Bounded by a watchdog like `waitUntil`.
@MainActor func waitUntilSteady<T: Equatable>(within seconds: TimeInterval = 60, turns: Int = 5, _ value: () -> T) async {
    let deadline = Date().addingTimeInterval(seconds)
    var last = value(), same = 0
    while same < turns, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
        let now = value()
        same = now == last ? same + 1 : 0
        last = now
    }
}

/// `waitUntil` for a test off the main actor: `condition` reads only what is safe to read from any thread.
func waitUntilAnywhere(within seconds: TimeInterval = 60, _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Lets what the main queue has queued run, `hops` times over (what a hop queues runs on the next): ordered, not timed,
/// so a slow machine only makes it later. For work a view defers with `DispatchQueue.main.async` (a focus request, say).
@MainActor func drainMainQueue(hops: Int = 8) async {
    for _ in 0..<hops {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }
}
