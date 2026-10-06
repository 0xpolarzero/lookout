import Foundation
import Testing
@testable import Lookout

/// Which clock ticks, and how fast, for the labels on screen (DESIGN.md 8: seconds only for a label that counts them).
@MainActor
@Suite struct ClockPeriod {
    @Test func aMinuteLabelNeverStartsTheSecondsTimer() {
        #expect(Clock.tick(for: [.minute: 1]) == 30)
        #expect(Clock.tick(for: [.minute: 2, .second: 0, .slow: 0]) == 30)
    }

    @Test func theTimerRunsAsFastAsTheQuickestLabelNeeds() {
        #expect(Clock.tick(for: [.minute: 1, .slow: 1]) == 5)
        #expect(Clock.tick(for: [.minute: 1, .slow: 1, .second: 1]) == 1)
        #expect(Clock.tick(for: [.second: 1]) == 1)
    }

    @Test func noLabelsNoTimer() {
        #expect(Clock.tick(for: [:]) == nil)
        #expect(Clock.tick(for: [.second: 0, .minute: 0]) == nil)
    }
}
