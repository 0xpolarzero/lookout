import Foundation
import Observation
import Testing
@testable import Lookout

@MainActor
@Suite struct SnoozeExpiry {
    @Test func aSnoozeEndsForWhatReadsItAtItsDeadline() async throws {
        let store = Store()
        store.persists = false
        store.settings.snoozeUntil = Date().addingTimeInterval(0.3)
        let flag = Flag()
        withObservationTracking { _ = store.isSnoozed } onChange: { flag.set() }
        #expect(store.isSnoozed)
        try await Task.sleep(for: .seconds(0.9))
        // Other suites keep the main actor busy for a while, which is when the expiry gets to run.
        for _ in 0..<500 where !flag.value { try await Task.sleep(for: .milliseconds(10)) }
        // The banner and the Notifications row, which read it, are told once the time has passed.
        #expect(flag.value && !store.isSnoozed)
    }

    @Test func resumingEarlyLeavesNothingToFire() async throws {
        let store = Store()
        store.persists = false
        store.settings.snoozeUntil = Date().addingTimeInterval(0.3)
        store.snooze(for: nil)
        let revision = store.snoozeRevision
        try await Task.sleep(for: .seconds(0.7))
        #expect(store.snoozeRevision == revision)
    }
}

private final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
