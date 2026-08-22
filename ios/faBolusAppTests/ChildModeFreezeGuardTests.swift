import Testing
import Foundation
@testable import faBolus

/// **FEAT-04 SAFETY freeze-guard (Phase 7, 07-04, P-D, D-05).** Child Mode is removed from narrow
/// `main` via a RUNTIME gate: `AppSettings.childModeEnabled` and `.requireRemoteBolusApproval` are
/// frozen to `false` with a belt-and-suspenders shape — a getter-level freeze (`get { false }
/// set { } }`) AND (for `childModeEnabled`) removal of the `applyBackup` restore line — so a
/// settings-restore (local backup) CANNOT resurrect either flag, and no direct setter call can make
/// either `true` by any other route either. The dose-adjacent evaluator (`AccessPolicy`/
/// `ChildFeature`/`BolusGate`/`GatedPumpWrite` in faBolusCore) and `AppModel`'s one read of these two
/// values stay BYTE-IDENTICAL — this suite only proves the settable INPUT can never become `true`
/// again, never touches the evaluator itself (that pure-logic proof lives in faBolusCore's own
/// `AccessPolicyTests`, which constructs `AccessContext(childModeEnabled: true, ...)` literals
/// directly and is unaffected by this freeze).
///
/// RED-first: every assertion below FAILS against pre-freeze `main` (the setters/restore still
/// accept `true`) — proving this guard has teeth. GREEN once the freeze in `AppSettings.swift` lands.
@MainActor
struct ChildModeFreezeGuardTests {

    /// Snapshot nothing to restore: both properties are frozen constants post-fix, so there is no
    /// live state to leak between tests — unlike every other `AppSettings` gate in this suite, no
    /// save/restore scaffolding is needed here (by design: that is exactly what "frozen" means).

    // MARK: - childModeEnabled: local-backup restore cannot resurrect it (option a)

    @Test func applyBackupWithChildModeEnabledTrueLeavesItFalse() {
        AppSettings.shared.applyBackup(["childModeEnabled": .bool(true)])
        #expect(AppSettings.shared.childModeEnabled == false,
                "a restored backup carrying childModeEnabled=true must never resurrect Child Mode (FEAT-04, D-05, SAFETY)")
    }

    // MARK: - childModeEnabled: no direct setter call can arm it either (option b, defense-in-depth)

    @Test func directSetterCallOnChildModeEnabledHasNoEffect() {
        AppSettings.shared.childModeEnabled = true
        #expect(AppSettings.shared.childModeEnabled == false,
                "childModeEnabled's getter-level freeze must reject a direct setter call too, not just applyBackup (FEAT-04, D-05, SAFETY)")
    }

    // MARK: - requireRemoteBolusApproval: local-backup restore cannot resurrect it either

    @Test func applyBackupWithRequireRemoteBolusApprovalTrueLeavesItFalse() {
        AppSettings.shared.applyBackup(["requireRemoteBolusApproval": .bool(true)])
        #expect(AppSettings.shared.requireRemoteBolusApproval == false,
                "a restored backup carrying requireRemoteBolusApproval=true must never re-arm a no-approver bolus-approval gate (FEAT-04, D-05, SAFETY)")
    }

    // MARK: - requireRemoteBolusApproval: no direct setter call can arm it either

    @Test func directSetterCallOnRequireRemoteBolusApprovalHasNoEffect() {
        AppSettings.shared.requireRemoteBolusApproval = true
        #expect(AppSettings.shared.requireRemoteBolusApproval == false,
                "requireRemoteBolusApproval's getter-level freeze must reject a direct setter call too, not just applyBackup (FEAT-04, D-05, SAFETY)")
    }

    // MARK: - both flags together (the exact shape a real exported/restored backup file would carry)

    @Test func applyBackupWithBothFlagsTrueLeavesBothFalse() {
        AppSettings.shared.applyBackup([
            "childModeEnabled": .bool(true),
            "requireRemoteBolusApproval": .bool(true),
        ])
        #expect(AppSettings.shared.childModeEnabled == false)
        #expect(AppSettings.shared.requireRemoteBolusApproval == false)
    }
}
