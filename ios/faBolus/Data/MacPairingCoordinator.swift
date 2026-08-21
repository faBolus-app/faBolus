import Foundation

/// Phase 3 (03-02, REMOTE-02, D-02/D-09) — minimal stub replacing the real Mac/peer pairing
/// coordinator. `PeerRemoteHost` (the shared BLE-peripheral receiver for both a literal Mac and an
/// iPhone-peer remote) is removed in this same plan, and the Mac client itself was already removed in
/// 03-01 — so there is no remaining producer of a paired device. The byte-frozen `AppModel.swift:1914`
/// still hard-references `MacPairingCoordinator.shared.pairedMacs` (`private var hasPairedRemote: Bool
/// { !MacPairingCoordinator.shared.pairedMacs.isEmpty }`), so this stub exists solely to keep that one
/// call site compiling without editing the dose-frozen file.
///
/// **Consequence (F-1, owner-ratified 2026-08-21):** `pairedMacs` is now permanently empty, so
/// `hasPairedRemote` is permanently `false` — the Child-Mode reverse-approval branch at
/// `AppModel.swift:1871` (`if childModeEnabled, requireRemoteBolusApproval, hasPairedRemote {
/// requestRemoteApproval(...) }`) can never fire again; a child's bolus always falls through to local
/// delivery (still guarded by the pump's own passcode/limit checks). This is the correct, fail-closed
/// direction — there is no remaining approver device — and is documented + owner-ratified in
/// `03-OWNER-FLAGS.md` F-1, not a silent behavior change.
///
/// D-09 explicitly prefers this minimal shape (no `setPolicy`/`setPairedViaQR`/`authorize`/`token` API)
/// over widening it to keep old tests compiling — those tests are deleted instead (03-02 Task 4, F-3).
///
/// Reintegration: see `dev/phone-remote`'s `REINTEGRATION.md` for what a future re-add must restore
/// (the real, observable pairing coordinator this replaced is preserved there byte-identical).
@MainActor
final class MacPairingCoordinator {
    static let shared = MacPairingCoordinator()
    /// Always empty — no possible producer of a paired device anymore (fail-closed, F-1).
    private(set) var pairedMacs: [String] = []
    private init() {}
}
