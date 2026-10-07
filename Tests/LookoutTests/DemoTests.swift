import Foundation
import Testing
@testable import Lookout

@MainActor
@Suite struct DemoScenarios {
    private func populated(_ scenario: Demo.Scenario) -> Store {
        let store = Store()
        Demo.populate(store, scenario)
        return store
    }

    @Test func everyScenarioFillsAStoreThatSavesNothing() {
        for scenario in Demo.Scenario.allCases {
            let store = populated(scenario)
            #expect(!store.persists, "\(scenario)")
        }
    }

    @Test func theDemoFlagTakesEachScenarioByItsName() {
        #expect(Set(Demo.Scenario.allCases.map(\.rawValue)).count == Demo.Scenario.allCases.count)
        for scenario in Demo.Scenario.allCases { #expect(Demo.Scenario(rawValue: scenario.rawValue) == scenario) }
    }

    @Test func theCausesThatEmptyAListLeaveItEmptyAndTheRestFull() {
        let store = populated(.signedOut)
        #expect(store.me == nil && store.authError != nil && store.lastSync == nil)
        #expect(populated(.reposFailed).repoErrors.count == 2)
        #expect(populated(.rateLimited).rateRemaining == 0)
        let first = populated(.firstSync)
        #expect(first.isSyncing && first.items.isEmpty && first.ci.isEmpty)
        #expect(populated(.empty).repos.isEmpty)
        #expect(populated(.botsEmpty).items.filter { $0.state.isOpen }.allSatisfy { !populated(.botsEmpty).isLowPriority($0) })
        #expect(populated(.doneEmpty).items.allSatisfy { $0.state.isOpen })
        let caught = populated(.needsYouEmpty)
        #expect(caught.list(.needsYou).isEmpty && !caught.list(.bots).isEmpty)
    }

    @Test func ciScenariosHoldWhatTheirNamesSay() {
        #expect(populated(.noCI).ci.isEmpty)
        #expect(populated(.allPassing).ci.values.allSatisfy { $0.state == .success })
        let many = populated(.manyCI)
        #expect(many.ci.count == 15 && many.ci.values.filter { $0.state == .failure }.count == 2)
        let running = populated(.ciRunning).ci.values
        #expect(running.contains { $0.state == .pending } && !running.contains { $0.state == .failure })
    }

    @Test func sessionScenariosHoldWhatTheirNamesSay() {
        #expect(populated(.sessionsNone).claudeSessions.isEmpty)
        #expect(populated(.sessions12).claudeSessions.count == 12)
        let waiting = populated(.sessionsWaiting10)
        #expect(waiting.claudeSessions.values.filter { $0.summary?.blocked == true }.count == 10)
        let many = populated(.sessionsManyNew)
        #expect(many.agents.entries.filter { !$0.kept }.count == 11)
        #expect(populated(.sessionsNewActivity).agents.entries.contains { !$0.kept })
    }

    @Test func theUpdateScenariosPutTheUpdaterInEachPhase() {
        #expect(populated(.updateAvailable).updater.phase == .available)
        let downloading = populated(.updateDownloading).updater
        #expect(downloading.phase == .downloading && downloading.fraction == 0.42)
        #expect(populated(.updateReady).updater.phase == .ready)
    }
}
