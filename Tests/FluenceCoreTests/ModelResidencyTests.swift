import Foundation
import Testing

@testable import FluenceCore

/// FLU-31: Parakeet leaves memory when idle or under pressure, never while in use.
struct ModelResidencyTests {
    private let limit = ModelResidency.idleLimit

    @Test func theLimitFitsTheFifteenMinuteBudget() {
        #expect(limit <= 15 * 60)
        #expect(limit >= 5 * 60)
    }

    @Test func unloadsAfterTheIdleLimit() {
        let state = ModelResidency.State(isLoaded: true, idleSeconds: limit)
        #expect(ModelResidency.shouldUnload(state, trigger: .idle))
    }

    @Test func staysBeforeTheIdleLimit() {
        let state = ModelResidency.State(isLoaded: true, idleSeconds: limit - 1)
        #expect(!ModelResidency.shouldUnload(state, trigger: .idle))
    }

    @Test func neverWhileInUse() {
        let state = ModelResidency.State(isLoaded: true, usersInFlight: 1, idleSeconds: limit * 10)
        #expect(!ModelResidency.shouldUnload(state, trigger: .idle))
        #expect(!ModelResidency.shouldUnload(state, trigger: .memoryPressure))
    }

    @Test func neverDuringALoad() {
        let state = ModelResidency.State(isLoaded: true, isLoading: true, idleSeconds: limit * 10)
        #expect(!ModelResidency.shouldUnload(state, trigger: .memoryPressure))
    }

    @Test func nothingToUnloadWhenNotLoaded() {
        let state = ModelResidency.State(isLoaded: false, idleSeconds: limit * 10)
        #expect(!ModelResidency.shouldUnload(state, trigger: .idle))
        #expect(!ModelResidency.shouldUnload(state, trigger: .memoryPressure))
        #expect(ModelResidency.nextCheck(state) == nil)
    }

    @Test func memoryPressureUnloadsAtOnce() {
        let state = ModelResidency.State(isLoaded: true, idleSeconds: 1)
        #expect(ModelResidency.shouldUnload(state, trigger: .memoryPressure))
    }

    /// A prewarm at launch loads the model without anyone using it.
    @Test func loadedButNeverUsedIsIdle() {
        let state = ModelResidency.State(isLoaded: true, idleSeconds: nil)
        #expect(ModelResidency.shouldUnload(state, trigger: .idle))
    }

    @Test func nextCheckCountsDownTheRemainingTime() {
        #expect(ModelResidency.nextCheck(.init(isLoaded: true, idleSeconds: 0)) == limit)
        #expect(ModelResidency.nextCheck(.init(isLoaded: true, idleSeconds: 60)) == limit - 60)
        #expect(ModelResidency.nextCheck(.init(isLoaded: true, idleSeconds: limit * 2)) == 0)
    }

    @Test func noTimerWhileInUse() {
        #expect(ModelResidency.nextCheck(.init(isLoaded: true, usersInFlight: 2, idleSeconds: 0)) == nil)
    }
}
