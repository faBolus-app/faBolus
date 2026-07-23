import Testing
@testable import faBolus

/// The blocking "untested feature" gate that stands in front of the app's unverified actions
/// (CGM high/low alert, IDP create/segment, experimental CGM source). Verifies the arm → present →
/// proceed/cancel state machine so an unverified action can only run after an explicit acknowledgement.
@Suite(.serialized)
@MainActor
struct UnverifiedFeatureGateTests {

    @Test func requestArmsAndPresents() {
        let gate = UnverifiedFeatureGate()
        #expect(!gate.isPresented)
        gate.request("Test feature") {}
        #expect(gate.isPresented)
        #expect(gate.feature == "Test feature")
    }

    @Test func proceedRunsActionOnce() {
        let gate = UnverifiedFeatureGate()
        var ran = 0
        gate.request("X") { ran += 1 }
        gate.proceed()
        #expect(ran == 1)
        gate.proceed()          // pending was cleared — no double-run
        #expect(ran == 1)
    }

    @Test func cancelDiscardsActionWithoutRunning() {
        let gate = UnverifiedFeatureGate()
        var ran = false
        gate.request("X") { ran = true }
        gate.cancel()
        #expect(!ran)
        gate.proceed()          // nothing pending after cancel
        #expect(!ran)
    }
}
