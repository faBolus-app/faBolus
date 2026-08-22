import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// LOCK-05 boundary test (Phase 8, 08-01, tracer). Proves `TandemBackend.syncTimeToNow()` — the pump
/// clock-sync WRITE path — still reaches the pump through the real signed-control pipeline with ZERO UI
/// surface present. Mirrors `StackingGuardDeliverInvariantTests`' `FakePumpTransport` +
/// `TandemBackend(testTransport:)` harness (lines 9-37 there). This phase removes the Settings/
/// PumpControlView UI + forces `autoSyncPumpTime` OFF by default; it does NOT touch `PumpResponseApplier`'s
/// READ-side time anchor or `GatedPumpWrite.syncTimeToNow` — both stay byte-identical (D-07).
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
    /// fake transport with zero UI constructed anywhere in this test — LOCK-05 removes the Settings/
    /// PumpControlView surfaces, never the write path itself.
    @Test func syncTimeToNowStillIssuesTheWriteWithNoUIPresent() async throws {
        let (backend, fake) = makeSyncableBackend()
        try await backend.syncTimeToNow()
        #expect(fake.lastSent(ChangeTimeDateRequest.props.opCode) != nil,
                "the pump time-sync command must still reach the transport with no UI surface present")
    }

    /// The existing connection precondition is unchanged by this phase — LOCK-05 pins the SETTING
    /// default (`autoSyncPumpTime = false`), never the control-write's own connection guard.
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
