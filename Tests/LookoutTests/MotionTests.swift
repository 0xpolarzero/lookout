import SwiftUI
import Testing
@testable import Lookout

/// Reduce Motion (DESIGN.md 3.6): fades shorten, anything spatial is instant, and a list's rows moving is spatial.
@Suite struct ReduceMotion {
    @Test func fadesShortenAndSpringsAreInstant() {
        #expect(Theme.Motion.resolve(Theme.Motion.fade, reduce: false) == Theme.Motion.fade)
        #expect(Theme.Motion.resolve(Theme.Motion.fade, reduce: true) == Theme.Motion.reduced)
        #expect(Theme.Motion.resolve(Theme.Motion.move, reduce: true) == nil)
    }

    @Test func aListChangingItsRowsIsInstantNotACrossFade() {
        #expect(Theme.Motion.resolveList(Theme.Motion.fade, reduce: false) == Theme.Motion.fade)
        #expect(Theme.Motion.resolveList(Theme.Motion.fade, reduce: true) == nil)
    }
}
