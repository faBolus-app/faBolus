import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that a transient ErrorResponse on the unthrottled alert-read burst never durably blacklists those
/// opcodes. A permanent skip would silence the CGM-alert mirror (and its burst-mates) after a one-shot buffer, CRC, or txId mismatch.
@Suite(.serialized) @MainActor
struct PumpBadOpcodeReprobeTests {

    private var cgmAlertOpcode: UInt8 { CGMAlertStatusRequest.props.opCode }  // op74
    private var alertOpcode: UInt8 { AlertStatusRequest.props.opCode }
    private var alarmOpcode: UInt8 { AlarmStatusRequest.props.opCode }
    private var reminderOpcode: UInt8 { ReminderStatusRequest.props.opCode }
    private var malfunctionOpcode: UInt8 { MalfunctionStatusRequest.props.opCode }

    /// A `PumpBadOpcodeStore` backed by a throwaway `UserDefaults` suite, so no test touches `.standard`
    /// (mirrors `PumpLearnedOpcodePersistenceTests.isolatedStore()`).
    private func isolatedStore() -> (store: PumpBadOpcodeStore, suite: String, defaults: UserDefaults) {
        let suite = "pboc-cxf04-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PumpBadOpcodeStore(defaults: defaults, storageKey: "learnedBadOpcodesByPump.test"), suite, defaults)
    }

    /// Drive the REAL `alertRead()` burst out via `startPolling()`'s `asyncAfter`-scheduled
    /// `scheduleAlertRead()` (near-zero delay via the test seam), then wait for it to land — mirrors
    /// `ReadCascadeMembershipGuardTests`' pattern for exercising the alert-read tier without a live Timer.
    private func driveAlertReadBurst(on b: TandemBackend) async {
        b.alertReadDelaySecForTesting = 0.001
        b.startPollingForTesting()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    /// Fire the recurring 15s tick (synchronously, via the test seam) WITHOUT restarting the connection
    /// cycle, so a second alert-read burst lands within the SAME session/generation, then wait for it.
    private func driveAnotherAlertReadBurstThisSession(on b: TandemBackend) async {
        b.firePollTimerTickForTesting()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: - Test 1 (self-heal): op74 is never durably persisted; startPolling re-hydration re-probes it

    @Test func op74TransientErrorIsNeverDurablyPersistedAndSelfHealsNextConnection() async {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "pump-cxf04-\(UUID().uuidString)"

        // Connection 1: op74 goes out in the alert-read burst; the pump answers a transient, opcode-less
        // op77 (correlated by the echoed txId — the same mechanism `resolveErrorResponse` uses for every
        // currentStatus read, regardless of the real error code).
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)
        await driveAlertReadBurst(on: b)
        guard let txId = b.outstandingReadsForTesting.first(where: { $0.opcode == cgmAlertOpcode })?.txId else {
            Issue.record("op74 CGMAlertStatusRequest must be outstanding after the alert-read burst")
            return
        }
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: txId))

        #expect(
            b.badOpcodesForTesting.contains(cgmAlertOpcode),
            "op74 is skipped for the rest of THIS session after a transient op77 correlates to it")
        #expect(
            !store.learnedOpcodes(for: key).contains(cgmAlertOpcode),
            "op74 must NEVER reach the durable per-pump store — a transient error must not permanently silence the CGM-alert mirror"
        )

        // Connection 2 (a reconnect): startPolling's hydration must leave op74 eligible for re-probe — it
        // must be dropped from the carried-over in-memory `badOpcodes` and actually RE-SENT.
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        await driveAlertReadBurst(on: b)
        #expect(
            !b.badOpcodesForTesting.contains(cgmAlertOpcode),
            "op74 must be dropped from badOpcodes on the next connection — re-probed, never durably skipped")
        #expect(dispatched.contains(cgmAlertOpcode), "op74 must be RE-SENT on the next connection cycle")
    }

    /// Burst-mates share the same unthrottled-burst exposure, so they must also never reach the durable store.
    @Test func alertReadFamilyBurstMatesAreNeverDurablyPersisted() {
        let (store, suite, defaults) = isolatedStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for opcode in [alertOpcode, alarmOpcode, cgmAlertOpcode, reminderOpcode, malfunctionOpcode] {
            store.record(opcode, for: "A", firmware: "3.4")
        }
        #expect(
            store.learnedOpcodes(for: "A").isEmpty,
            "none of the alert-read burst's 5 opcodes may ever be durably persisted")
    }

    // MARK: - Test 2 (in-memory skip): op74 is skipped for the rest of THIS session, not re-thrashed

    @Test func op74IsSkippedInMemoryForRestOfSessionAfterTransientError() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        await driveAlertReadBurst(on: b)
        guard let txId = b.outstandingReadsForTesting.first(where: { $0.opcode == cgmAlertOpcode })?.txId else {
            Issue.record("op74 must be outstanding after the alert-read burst")
            return
        }
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: txId))
        #expect(b.badOpcodesForTesting.contains(cgmAlertOpcode))

        // A LATER alert-read burst in the SAME session/connection must SKIP op74, not re-send it.
        var skipped: [UInt8] = []
        var dispatched: [UInt8] = []
        b.onReadSkippedForTesting = { _, op in skipped.append(op) }
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        await driveAnotherAlertReadBurstThisSession(on: b)
        #expect(
            skipped.contains(cgmAlertOpcode),
            "op74 must be SKIPPED by the never-resend guard for the rest of this connection")
        #expect(
            !dispatched.contains(cgmAlertOpcode),
            "op74 must not be re-dispatched again this connection-lifetime")
    }

    // MARK: - Dose-input allowlist is unaffected by the alert-read never-blacklist

    @Test func doseInputReadOpcodesRemainUnchangedByTheAlertReadOpcodesAddition() {
        let iob = ControlIQIOBRequest.props.opCode  // op108
        let therapy = BolusCalcDataSnapshotRequest.props.opCode  // op115
        #expect(
            PumpReadCatalog.doseInputReadOpcodes == [iob, therapy],
            "the dose-input allowlist must be untouched by the alert-read allowlist")
        #expect(
            PumpReadCatalog.alertReadOpcodes.isDisjoint(with: PumpReadCatalog.doseInputReadOpcodes),
            "the two never-durably-blacklist allowlists must not overlap — distinct mechanisms, distinct opcodes")
    }

    @Test func aDoseInputReadOp77dThisConnectionStillSelfHealsAfterTheAlertReadOpcodesAddition() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let iob = ControlIQIOBRequest.props.opCode
        b.startPollingForTesting()
        guard let iobTxId = b.outstandingReadsForTesting.first(where: { $0.opcode == iob })?.txId else {
            Issue.record("op108 must be outstanding after the post-pair burst")
            return
        }
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: iobTxId))
        #expect(b.badOpcodesForTesting.contains(iob), "op108 still skips in-memory for the rest of this session")

        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        #expect(
            !b.badOpcodesForTesting.contains(iob),
            "op108 must still be dropped from badOpcodes on the next connection")
        #expect(dispatched.contains(iob), "op108 must still be RE-SENT on the next connection cycle")
    }

    // MARK: - A current-session op74 skip is disclosed via safetyDegradedNotes

    @Test func aSkippedOp74IsDisclosedInSafetyDegradedNotes() {
        #expect(
            PumpReadCatalog.safetyRelevantReadOpcodes.contains(cgmAlertOpcode),
            "op74 must be added to safetyRelevantReadOpcodes")
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: [cgmAlertOpcode])
        #expect(
            notes.contains { $0.contains("op-74") || $0.contains(PumpReadCatalog.readName(for: cgmAlertOpcode)) },
            "a currently-skipped op74 must surface a user-facing note, not only the Debug menu")
    }
}
