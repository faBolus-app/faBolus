import Testing
import Foundation
import TandemBLE
import TandemMessages
import faBolusCore
@testable import faBolus

/// Pins the exact ORDER in which `PumpResponseApplier.apply(_:txId:characteristic:)` fires its injected
/// `set*`/`with*`/action closures for the dose-critical response cases. A reorder can leave the final
/// snapshot looking identical while corrupting a dose input: op-115 must seat the BolusCalc snapshot
/// BEFORE waking a coalesced calc-input waiter (else BolusMath reads a half-populated profile), op-109
/// must stamp IOB before waking the same waiter, op-33 must write pump identity before re-wiring the
/// device/send gate, and the alert cases must set the list before merging notifications.
///
/// The applier's injected closures ARE the observation seam — no production `*ForTesting` hook is
/// needed. Each seam is bound to a recorder and the recorded sequence is asserted against the current
/// code. This is a behavioural characterization only; no source-text scan is used or needed.
@Suite(.serialized) @MainActor
struct PumpResponseApplierOrderingCharacterizationTests {

    // MARK: - Call-order recorder

    /// Reference recorder so one helper can bind every seam and each test reads back the ordered steps.
    private final class Recorder { var steps: [String] = [] }

    /// Build an applier whose every mutation/action seam appends its own name to `rec.steps`, in the
    /// order `apply` invokes it. Pure read getters (`detectedIsMobi`, `pumpTimeAnchor`, `viewedProfileId`,
    /// `isBackfillActive`, `historySyncState`) return values that keep the gated branches flowing but are
    /// NOT recorded — only mutations/actions are pinned. `cgmReadingDate` is both a getter and part of the
    /// EGV apply order, so it is recorded AND returns a trustworthy (non-nil) date.
    private func makeApplier(recording rec: Recorder) -> PumpResponseApplier {
        let applier = PumpResponseApplier(
            resolveBadOpcodeForError: { requestCodeId, _, _ in UInt8(truncatingIfNeeded: requestCodeId) })

        // Snapshot / history mutators.
        applier.withSnapshot = { _ in rec.steps.append("withSnapshot") }
        applier.withGlucoseHistory = { _ in rec.steps.append("withGlucoseHistory") }
        applier.withIOBHistory = { _ in rec.steps.append("withIOBHistory") }

        // Chained request routing.
        applier.send = { rec.steps.append("send(\(type(of: $0)))") }

        // Read-scheduler actions.
        applier.noteCalcInputArrived = { rec.steps.append("noteCalcInputArrived(\($0))") }
        applier.completeGlucoseRead = { rec.steps.append("completeGlucoseRead") }
        applier.schedulePredictiveBurst = { _ in rec.steps.append("schedulePredictiveBurst") }
        applier.cgmReadingDate = { _, _ in
            rec.steps.append("cgmReadingDate")
            return Date()  // non-nil ⇒ the reading time is trustworthy, so the history/burst branches run
        }

        // Time / history-status.
        applier.setPumpTimeAnchor = { _ in rec.steps.append("setPumpTimeAnchor") }
        applier.setHistoryStatusRequestedThisConnection = {
            rec.steps.append("setHistoryStatusRequestedThisConnection(\($0))")
        }

        // Dose-calculator snapshot.
        applier.setCalcSnapshot = { _ in rec.steps.append("setCalcSnapshot") }

        // Identity / device-context.
        applier.applyDeviceContext = { _, _, _ in rec.steps.append("applyDeviceContext") }
        applier.noteBootstrapVersionIdentified = { rec.steps.append("noteBootstrapVersionIdentified") }

        // Alert lists + merge.
        applier.setAlertList = { _ in rec.steps.append("setAlertList") }
        applier.noteAlert = { _, _ in rec.steps.append("noteAlert") }
        applier.mergeNotifications = { rec.steps.append("mergeNotifications") }

        // Read getters that gate the branches under test (not recorded).
        applier.detectedIsMobi = { nil }
        applier.viewedProfileId = { -1 }
        applier.isBackfillActive = { false }
        applier.historyStatusRequestedThisConnection = { false }  // ⇒ op-70's status-request block runs

        return applier
    }

    // MARK: - Message fixtures (valid cargo that routes into the case under test)

    private func op33ApiVersion() -> ApiVersionResponse {
        ApiVersionResponse(cargo: Bytes.firstTwoBytesLittleEndian(2) + Bytes.firstTwoBytesLittleEndian(5))
    }
    private func op70TimeSinceReset() -> TimeSinceResetResponse {
        TimeSinceResetResponse(cargo: [UInt8](repeating: 0, count: 8))
    }
    private func op115BolusCalcSnapshot() -> BolusCalcDataSnapshotResponse {
        BolusCalcDataSnapshotResponse(cargo: [UInt8](repeating: 7, count: 10))
    }
    private func op109ControlIQIOB() -> ControlIQIOBResponse {
        ControlIQIOBResponse(cargo: [9, 9, 9])
    }
    /// An 8-byte V1 EGV frame that decodes to a VALID reading (status 1, mg/dL 120) with a non-zero pump
    /// timestamp (1000s) — so `hasValidReading` is true and `pumpSec > lastCgmPumpSec (0)`, exercising the
    /// full history + predictive-burst branch.
    private func egvValidReading() -> CurrentEGVGuiDataResponse {
        var cargo = [UInt8](repeating: 0, count: 8)
        cargo[0] = 232  // bgReadingTimestampSeconds = 1000 (little-endian uint32)
        cargo[1] = 3
        cargo[4] = 120  // cgmReading = 120 mg/dL
        cargo[6] = 1  // egvStatusId = VALID
        return CurrentEGVGuiDataResponse(cargo: cargo)
    }
    private func alertStatus() -> AlertStatusResponse {
        AlertStatusResponse(cargo: [UInt8](repeating: 0, count: 8))
    }

    private func apply(_ m: Message, to applier: PumpResponseApplier) {
        applier.apply(m, txId: 0, characteristic: .currentStatus)
    }

    // MARK: - Per-opcode ordering (dose-critical)

    /// op-115 BolusCalcDataSnapshotResponse: the calc snapshot must be seated BEFORE the coalesced
    /// `refreshCalcInputsNow()` waiter is woken, or BolusMath can read a half-populated profile.
    @Test func op115SeatsCalcSnapshotBeforeWakingTheCalcWaiter() {
        let rec = Recorder()
        apply(op115BolusCalcSnapshot(), to: makeApplier(recording: rec))
        #expect(rec.steps == ["setCalcSnapshot", "withSnapshot", "noteCalcInputArrived(false)"])
    }

    /// op-109 ControlIQIOBResponse: IOB is stamped into the snapshot, then the calc-input waiter is woken,
    /// then the IOB time series is appended.
    @Test func op109StampsIOBThenWakesWaiterThenAppendsHistory() {
        let rec = Recorder()
        apply(op109ControlIQIOB(), to: makeApplier(recording: rec))
        #expect(rec.steps == ["withSnapshot", "noteCalcInputArrived(true)", "withIOBHistory"])
    }

    /// op-33 ApiVersionResponse: pump identity + firmware are written to the snapshot BEFORE the
    /// device/send-gate is re-wired, and the scheduler is told identity is known LAST.
    @Test func op33WritesIdentityThenRewiresDeviceContextThenNotesBootstrap() {
        let rec = Recorder()
        apply(op33ApiVersion(), to: makeApplier(recording: rec))
        #expect(rec.steps == ["withSnapshot", "applyDeviceContext", "noteBootstrapVersionIdentified"])
    }

    /// op-70 TimeSinceResetResponse (unsolicited): set the pump-time anchor, mark the status request as
    /// sent this connection, then emit the gated `HistoryLogStatusRequest`.
    @Test func op70AnchorsTimeThenGatesTheHistoryStatusRequest() {
        let original = AppSettings.shared.historySyncEnabled
        AppSettings.shared.historySyncEnabled = true  // the on-connect auto-sync gate governs the send
        defer { AppSettings.shared.historySyncEnabled = original }

        let rec = Recorder()
        apply(op70TimeSinceReset(), to: makeApplier(recording: rec))
        #expect(
            rec.steps == [
                "setPumpTimeAnchor",
                "setHistoryStatusRequestedThisConnection(true)",
                "send(HistoryLogStatusRequest)",
            ])
    }

    /// An EGV reading (op-35): snapshot activity flag, resolve the trusted reading time, write the
    /// glucose value, append history, line up the predictive burst, then wake glucose waiters LAST.
    @Test func egvReadingAppliesSnapshotTimeHistoryBurstThenCompletesRead() {
        let rec = Recorder()
        apply(egvValidReading(), to: makeApplier(recording: rec))
        #expect(
            rec.steps == [
                "withSnapshot", "cgmReadingDate", "withSnapshot", "withGlucoseHistory",
                "schedulePredictiveBurst", "completeGlucoseRead",
            ])
    }

    /// A representative alert case (op-69 AlertStatusResponse): the list is set, the alert bitmap is
    /// noted, then notifications are merged — the same triplet order every alert/alarm/CGM/reminder/
    /// malfunction case shares.
    @Test func alertSetsListThenNotesThenMerges() {
        let rec = Recorder()
        apply(alertStatus(), to: makeApplier(recording: rec))
        #expect(rec.steps == ["setAlertList", "noteAlert", "mergeNotifications"])
    }

    // MARK: - Cross-case ordering through ONE applier

    /// Drive a realistic inbound sequence through a SINGLE applier and pin the concatenated cross-case
    /// order — this is the wall any future restructuring of `apply`'s cascade must not disturb.
    @Test func realisticInboundSequenceFiresSeamsInPinnedCrossCaseOrder() {
        let original = AppSettings.shared.historySyncEnabled
        AppSettings.shared.historySyncEnabled = true
        defer { AppSettings.shared.historySyncEnabled = original }

        let rec = Recorder()
        let applier = makeApplier(recording: rec)

        apply(op33ApiVersion(), to: applier)
        apply(op70TimeSinceReset(), to: applier)
        apply(op115BolusCalcSnapshot(), to: applier)
        apply(op109ControlIQIOB(), to: applier)
        apply(egvValidReading(), to: applier)
        apply(alertStatus(), to: applier)

        let expected: [String] = [
            // op-33
            "withSnapshot", "applyDeviceContext", "noteBootstrapVersionIdentified",
            // op-70
            "setPumpTimeAnchor", "setHistoryStatusRequestedThisConnection(true)", "send(HistoryLogStatusRequest)",
            // op-115
            "setCalcSnapshot", "withSnapshot", "noteCalcInputArrived(false)",
            // op-109
            "withSnapshot", "noteCalcInputArrived(true)", "withIOBHistory",
            // EGV (op-35)
            "withSnapshot", "cgmReadingDate", "withSnapshot", "withGlucoseHistory", "schedulePredictiveBurst", "completeGlucoseRead",
            // alert (op-69)
            "setAlertList", "noteAlert", "mergeNotifications",
        ]

        // Anti-vacuity: the recorder must have observed the full cross-case sequence, not silently
        // nothing (an unbound seam would drop steps and shorten the array).
        #expect(rec.steps.count == 21, "every dose-critical seam in the driven sequence must have fired")
        #expect(rec.steps == expected, "the cross-case set*/apply order must match the current code exactly")
    }
}
