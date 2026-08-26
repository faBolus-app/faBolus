import Foundation

/// GO-1 Step 7 (REMED-16, GO-1 §4.6 — CX-A-01 item 4) — an additive, app-layer capability protocol
/// naming the handful of concrete `TandemBackend` hooks that `AppModel` reaches through 8
/// `source as? TandemBackend` / `source is TandemBackend` casts (R5/R28/R29/R34/R48). Lives in the
/// APP layer, not `faBolusCore`, because it names `TandemBackend` by construction (16-PATTERNS.md
/// "Additive capability protocol" placement rule) — `PumpBackend` itself (the ~50-member contract in
/// `Packages/faBolusCore/Sources/faBolusCore/PumpBackend.swift`) gains NOTHING; that file stays
/// byte-unchanged.
///
/// **No behavior change.** Every one of the 8 cast sites already fell back to a nil/idle/empty value
/// when `source` was not a `TandemBackend`. `MockBackend` intentionally does NOT conform, so
/// `source as? TandemOnlyOps` is nil for it too — the identical fallback, reached through the
/// protocol cast instead of the concrete-type cast.
///
/// **CAPABILITY-OWNERSHIP CONTRACT (transitional superset — read before editing).** This plan (16-07)
/// lands BEFORE the two GO-2 capability protocols exist, so `TandemOnlyOps` is a deliberate transitional
/// superset. Once `PumpHistoryProviding` (16-08) and `PumpDiagnosticsProviding` (16-09) exist, 16-10
/// re-narrows `AppModel`'s casts for the two groups below OFF `TandemOnlyOps` and ONTO the capability
/// protocols, then removes those members from this protocol. The final, single-owner map (record
/// verbatim, do not duplicate a member across two protocols after 16-10):
///   - `PumpHistoryProviding` (16-08): `historySyncState`, `triggerManualHistorySync`, `cancelHistorySync`
///   - `PumpDiagnosticsProviding` (16-09): `onCommandLatency`, `onWillRetryReconnect`,
///     `badOpcodesForDiagnostics`
///   - `TandemOnlyOps` (permanent residue — genuinely Tandem-specific, covered by neither capability
///     protocol): `consumeSleepScheduleWriteError`, `pumpIdentityDetail`
@MainActor
protocol TandemOnlyOps: AnyObject {
    /// B3a (§5.2.8): observational command round-trip latency sink. Diagnostics-only; never influences
    /// control flow. (16-10 target: `PumpDiagnosticsProviding`.)
    var onCommandLatency: (@MainActor (Double?) -> Void)? { get set }

    /// D-05: observational reconnect-ladder sink. Diagnostics-only; never influences control flow.
    /// (16-10 target: `PumpDiagnosticsProviding`.)
    var onWillRetryReconnect: (@MainActor (Int, TimeInterval) -> Void)? { get set }

    /// Part B-a (09.6-01, D-02a): opcodes the connected pump has rejected this connection-lifetime, for
    /// the `[Capability/opcode]` diagnostics section. (16-10 target: `PumpDiagnosticsProviding`.)
    var badOpcodesForDiagnostics: Set<UInt8> { get }

    /// D-01/D-05 (Phase 09.7-02): the gap-sync's current state for the "Pump history sync" UI section.
    /// (16-10 target: `PumpHistoryProviding`.)
    var historySyncState: HistorySyncState { get }

    /// D-05 ("Sync now"): manually run the gap-aware history sync regardless of the automatic-sync
    /// toggle. (16-10 target: `PumpHistoryProviding`.)
    func triggerManualHistorySync()

    /// D-05 ("Stop syncing"): abort an in-progress manual/automatic gap sync. (16-10 target:
    /// `PumpHistoryProviding`.)
    func cancelHistorySync()

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
