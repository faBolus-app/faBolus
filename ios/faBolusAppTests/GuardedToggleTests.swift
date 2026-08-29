import Testing
@testable import faBolus

/// 09.3-01 (D-05/SC3): behavior contract for the reusable `guardedToggle(get:set:skipConfirmIf:
/// requestConfirm:)` factory — the ONE guarded-enable idiom every confirm-gated Bool toggle in the
/// settings surface routes through. Spy closures pin exactly which callback fires (and how many times)
/// for each row of the contract; this is what proves the "snap-back on cancel" behavior without a live
/// SwiftUI view (Cancel never calls `set`, so a re-read of `get` returns the still-false backing).
@Suite struct GuardedToggleTests {

    /// Records every call so each test asserts both invocation count and, where relevant, order.
    private final class Spy {
        var backing = false
        var setCalls: [Bool] = []
        var requestConfirmCalls = 0
        var skipConfirmIfCalls = 0
        var skipConfirmIfResult = false

        func get() -> Bool { backing }
        func set(_ v: Bool) {
            setCalls.append(v)
            backing = v
        }
        func skipConfirmIf() -> Bool {
            skipConfirmIfCalls += 1
            return skipConfirmIfResult
        }
        func requestConfirm() { requestConfirmCalls += 1 }
    }

    @Test func getAlwaysReflectsTheRealBackingValueNeverAStagedOne() {
        let spy = Spy()
        let binding = guardedToggle(get: spy.get, set: spy.set, requestConfirm: spy.requestConfirm)
        #expect(binding.wrappedValue == false)
        spy.backing = true
        #expect(binding.wrappedValue == true)
    }

    @Test func enablingWithoutSkipConfirmRequestsConfirmAndDoesNotWriteYet() {
        let spy = Spy()
        let binding = guardedToggle(get: spy.get, set: spy.set, requestConfirm: spy.requestConfirm)
        binding.wrappedValue = true
        #expect(spy.requestConfirmCalls == 1)
        #expect(spy.setCalls.isEmpty)
        #expect(spy.backing == false)  // snap-back: set was never invoked, backing is still false
    }

    @Test func cancelSnapsBackBecauseSetWasNeverCalledOnTheConfirmPath() {
        let spy = Spy()
        let binding = guardedToggle(get: spy.get, set: spy.set, requestConfirm: spy.requestConfirm)
        binding.wrappedValue = true  // user flips on -> requestConfirm fires
        // Simulate Cancel: no confirm action ever calls spy.set(true). A re-read must show false.
        #expect(binding.wrappedValue == false)
        #expect(spy.setCalls.isEmpty)
    }

    @Test func enablingWithSkipConfirmTrueWritesImmediatelyAndNeverRequestsConfirm() {
        let spy = Spy()
        spy.skipConfirmIfResult = true
        let binding = guardedToggle(
            get: spy.get, set: spy.set,
            skipConfirmIf: spy.skipConfirmIf, requestConfirm: spy.requestConfirm)
        binding.wrappedValue = true
        #expect(spy.setCalls == [true])
        #expect(spy.requestConfirmCalls == 0)
        #expect(binding.wrappedValue == true)
    }

    @Test func turningOffIsAlwaysImmediateAndNeverConfirmed() {
        let spy = Spy()
        spy.backing = true
        let binding = guardedToggle(get: spy.get, set: spy.set, requestConfirm: spy.requestConfirm)
        binding.wrappedValue = false
        #expect(spy.setCalls == [false])
        #expect(spy.requestConfirmCalls == 0)
        #expect(binding.wrappedValue == false)
    }

    @Test func skipConfirmIfDefaultsToFalseSoOmittingItAlwaysConfirmsOnEnable() {
        let spy = Spy()
        // No skipConfirmIf argument supplied — must default to always-confirm.
        let binding = guardedToggle(get: spy.get, set: spy.set, requestConfirm: spy.requestConfirm)
        binding.wrappedValue = true
        #expect(spy.requestConfirmCalls == 1)
        #expect(spy.setCalls.isEmpty)
    }
}
