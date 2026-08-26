import Foundation

/// GO-1 Step 7 (REMED-16, GO-1 §4.6 — CX-A-01 item 4) — an additive, app-layer capability protocol
/// originally naming the handful of concrete `TandemBackend` hooks that `AppModel` reached through 8
/// `source as? TandemBackend` / `source is TandemBackend` casts (R5/R28/R29/R34/R48). Lives in the
/// APP layer, not `faBolusCore`, because it names `TandemBackend` by construction (16-PATTERNS.md
/// "Additive capability protocol" placement rule) — `PumpBackend` itself (the ~50-member contract in
/// `Packages/faBolusCore/Sources/faBolusCore/PumpBackend.swift`) gains NOTHING; that file stays
/// byte-unchanged.
///
/// **No behavior change.** Every one of the (originally 8, now 2) cast sites already fell back to a
/// nil/idle/empty value when `source` was not a `TandemBackend`. `MockBackend` intentionally does NOT
/// conform, so `source as? TandemOnlyOps` is nil for it too — the identical fallback, reached through
/// the protocol cast instead of the concrete-type cast.
///
/// **CAPABILITY-OWNERSHIP CONTRACT — FINAL (16-10 re-narrowing complete).** This protocol was a
/// deliberate transitional superset (16-07) until the two GO-2 capability protocols existed. 16-10
/// (GO-2 Step 3, REMED-16) re-narrowed `AppModel`'s history/diagnostics casts OFF `TandemOnlyOps` and
/// ONTO `PumpHistoryProviding` (16-08) / `PumpDiagnosticsProviding` (16-09), removing those 6 members
/// from this protocol. Every member below now has exactly ONE protocol owner — no duplication:
///   - `PumpHistoryProviding` (16-08, faBolusCore): `historySyncState`, `triggerManualHistorySync`,
///     `cancelHistorySync`
///   - `PumpDiagnosticsProviding` (16-09, faBolusCore): `onCommandLatency`, `onWillRetryReconnect`,
///     `badOpcodesForDiagnostics`
///   - `TandemOnlyOps` (this protocol — permanent residue, genuinely Tandem-specific, covered by
///     neither capability protocol): `consumeSleepScheduleWriteError`, `pumpIdentityDetail`
@MainActor
protocol TandemOnlyOps: AnyObject {
    /// Phase 09.10 D-04: one-shot consume of the most recent Sleep-schedule write rejection
    /// (`SetSleepScheduleResponse.status != 0`), surfaced via `AppModel.lastError` right after the
    /// write completes. Permanent `TandemOnlyOps` residue — genuinely Tandem-specific.
    func consumeSleepScheduleWriteError() -> String?

    /// B4 (owner 2026-08-09) — the concrete-Tandem-only identity detail feeding
    /// `AppModel.currentPumpIdentity()`'s "real" branch (R28): the paired peripheral's CoreBluetooth
    /// UUID, or `"unpaired"` before first pairing. A non-Tandem backend never reaches this — the
    /// `source as? TandemOnlyOps` cast is nil and `currentPumpIdentity()` falls back on
    /// `source.snapshot.isMobi`. Permanent `TandemOnlyOps` residue — genuinely Tandem-specific.
    var pumpIdentityDetail: String { get }
}
