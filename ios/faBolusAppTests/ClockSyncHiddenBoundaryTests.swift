import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Boundary test proving `TandemBackend.syncTimeToNow()` — the pump clock-sync WRITE path — still
/// reaches the pump through the real signed-control pipeline with ZERO UI surface present. Mirrors
/// `StackingGuardDeliverInvariantTests`' `FakePumpTransport` + `TandemBackend(testTransport:)` harness.
/// The clock-sync UI (Settings/PumpControlView) is gone and `autoSyncPumpTime` defaults OFF; neither
/// `PumpResponseApplier`'s READ-side time anchor nor `GatedPumpWrite.syncTimeToNow` is touched — both
/// stay byte-identical.
@Suite(.serialized) @MainActor
struct ClockSyncHiddenBoundaryTests {

    /// `TandemBackend(testTransport:)` already defaults to connected + authenticated + a fresh op-115
    /// stamp (see its own doc comment), so only the `TimeSinceResetResponse` that `refreshSigningTimestamp()`
    /// awaits needs scripting.
    private func makeSyncableBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        return (backend, fake)
    }

    /// `syncTimeToNow()` still issues the signed `ChangeTimeDateRequest` (opcode 0xD6) write through the
    /// fake transport with zero UI constructed anywhere in this test — what was removed is the
    /// Settings/PumpControlView surfaces, never the write path itself. `sendControl` now awaits the
    /// ack, so an accepted `ChangeTimeDateResponse` must be scripted for the write to complete.
    @Test func syncTimeToNowStillIssuesTheWriteWithNoUIPresent() async throws {
        let (backend, fake) = makeSyncableBackend()
        fake.script(
            ChangeTimeDateResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: ChangeTimeDateResponse.props.opCode, cargo: [0], signed: true)))
        try await backend.syncTimeToNow()
        #expect(
            fake.lastSent(ChangeTimeDateRequest.props.opCode) != nil,
            "the pump time-sync command must still reach the transport with no UI surface present")
    }

    /// The existing connection precondition is unchanged — what changed is the SETTING default
    /// (`autoSyncPumpTime = false`), never the control-write's own connection guard.
    @Test func syncTimeToNowStillRequiresConnectionWithNoUIPresent() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.disconnected)
        await #expect(throws: (any Error).self) {
            try await backend.syncTimeToNow()
        }
        #expect(fake.lastSent(ChangeTimeDateRequest.props.opCode) == nil)
    }
}
