import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that `TandemBackend.sendControl` awaits and inspects the pump's ack instead of firing-and-
/// forgetting: an accepted ack applies its snapshot side effect, a refused (non-zero status) ack throws
/// and never claims success, and a dropped/timed-out reply is a distinct "unconfirmed" outcome — never
/// collapsed with a definite refusal.
@Suite(.serialized) @MainActor
struct ControlWriteAckTests {

    /// A `TandemBackend` identified as a Mobi (satisfies the `supportsAnyAdvancedControl` capability the
    /// `AppModel`-level suspend/resume gate requires) over a fresh `FakePumpTransport`.
    private func mobiBackend(_ fake: FakePumpTransport) -> TandemBackend {
        let b = TandemBackend(testTransport: fake)
        b.setPumpModelIdentityForTesting(pumpModelName: "Mobi", isMobi: true)
        return b
    }

    // MARK: - Accepted: side effect applied, no throw

    @Test func acceptedSuspendSetsDeliverySuspendedAndDoesNotThrow() async throws {
        let fake = FakePumpTransport()
        let b = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SuspendPumpingResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: SuspendPumpingResponse.props.opCode, cargo: [0], signed: true)))

        try await b.suspendDelivery()

        #expect(b.snapshot.deliverySuspended, "an accepted suspend ack must set deliverySuspended")
        #expect(
            fake.sent.contains { $0.opCode == SuspendPumpingRequest.props.opCode },
            "the suspend request must reach the wire")
        #expect(
            fake.awaited.contains(SuspendPumpingResponse.props.opCode),
            "the write must be AWAITED via the coordinator, not fire-and-forget")
    }

    @Test func acceptedResumeClearsDeliverySuspended() async throws {
        let fake = FakePumpTransport()
        let b = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SuspendPumpingResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: SuspendPumpingResponse.props.opCode, cargo: [0], signed: true)))
        try await b.suspendDelivery()
        #expect(b.snapshot.deliverySuspended, "sanity: the suspend baseline must be set before testing resume")

        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            ResumePumpingResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: ResumePumpingResponse.props.opCode, cargo: [0], signed: true)))
        try await b.resumeDelivery()

        #expect(!b.snapshot.deliverySuspended, "an accepted resume ack must clear deliverySuspended")
    }

    // MARK: - Refused (definite): throws, no side effect

    @Test func refusedSuspendThrowsPumpRejectedAndLeavesDeliverySuspendedUnchanged() async {
        let fake = FakePumpTransport()
        let b = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SuspendPumpingResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: SuspendPumpingResponse.props.opCode, cargo: [1], signed: true)))

        do {
            try await b.suspendDelivery()
            Issue.record("a refused suspend must throw, never report success")
        } catch let ControlWriteError.rejected(message) {
            #expect(message.contains("suspend"), "the refusal message should name the rejected write")
        } catch {
            Issue.record("expected ControlWriteError.rejected, got \(error)")
        }
        #expect(!b.snapshot.deliverySuspended, "a refused suspend must never set deliverySuspended")
    }

    // MARK: - Indeterminate (dropped/timed-out): a DISTINCT thrown type, never collapsed with a refusal

    @Test func droppedSuspendReplyThrowsATxErrorDistinctFromPumpRejected() async {
        let fake = FakePumpTransport()
        let b = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SuspendPumpingResponse.props.opCode,
            .tx(.timedOut(characteristic: .control, opCode: SuspendPumpingResponse.props.opCode)))

        do {
            try await b.suspendDelivery()
            Issue.record("a dropped ack must throw, never report success")
        } catch is PumpTransactionCoordinator.TxError {
            // Expected: the coordinator's own timeout/disconnect error, propagated unchanged — distinct
            // from a definite `BolusError.pumpRejected` refusal.
        } catch {
            Issue.record("expected a PumpTransactionCoordinator.TxError, got \(error)")
        }
        #expect(!b.snapshot.deliverySuspended, "an unconfirmed write must never optimistically apply its side effect")
    }

    // MARK: - Surfaces end-to-end through AppModel.lastError

    @Test func refusedSuspendSurfacesThroughAppModelAsANonNilLastError() async {
        let fake = FakePumpTransport()
        let backend = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SuspendPumpingResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: SuspendPumpingResponse.props.opCode, cargo: [1], signed: true)))

        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, adv = s.advancedControlEnabled
        let mode = s.appMode
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.advancedControlEnabled = true
        s.appMode = .advanced
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.advancedControlEnabled = adv
            s.appMode = mode
        }

        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)

        await model.suspendDelivery()

        #expect(
            model.lastError != nil,
            "a refused control write must surface via AppModel.lastError — the pre-fix fire-and-forget funnel reported success (lastError == nil) for exactly this case"
        )
    }

    // MARK: - Sleep-schedule write: the bespoke error chain is closed by deletion, the funnel's own
    // refusal message stays as specific as the retired one.

    @Test func refusedSleepScheduleWriteSurfacesTheSpecificLastErrorThroughTheFunnel() async {
        let fake = FakePumpTransport()
        let backend = mobiBackend(fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            SetSleepScheduleResponse.props.opCode,
            .frame(FakePumpTransport.frame(opCode: SetSleepScheduleResponse.props.opCode, cargo: [1], signed: true)))

        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled, adv = s.advancedControlEnabled
        let mode = s.appMode
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.advancedControlEnabled = true
        s.appMode = .advanced
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.advancedControlEnabled = adv
            s.appMode = mode
        }

        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        model.acknowledgeUnverifiedTherapy()

        await model.setSleepSchedule(slot: 0, enabled: true, activeDays: 0x7F, startMinute: 0, endMinute: 60)

        #expect(
            model.lastError == "The pump rejected the sleep-schedule change (status 1).",
            "a rejected sleep-schedule write must surface a message as specific as the retired bespoke one; got: \(model.lastError ?? "nil")"
        )
    }
}
