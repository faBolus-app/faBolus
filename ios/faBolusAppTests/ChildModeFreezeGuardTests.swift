import Testing
import Foundation
@testable import faBolus

/// Pins that `childModeEnabled` and `requireRemoteBolusApproval` stay frozen false: a settings
/// backup restore or a direct setter must never resurrect Child Mode or a no-approver bolus-approval gate. AccessPolicyTests still pin the evaluator against `true` literals.
@MainActor
struct ChildModeFreezeGuardTests {

    /// Snapshot nothing to restore: both properties are frozen constants post-fix, so there is no
    /// live state to leak between tests — unlike every other `AppSettings` gate in this suite, no
    /// save/restore scaffolding is needed here (by design: that is exactly what "frozen" means).

    // MARK: - childModeEnabled: local-backup restore cannot resurrect it

    @Test func applyBackupWithChildModeEnabledTrueLeavesItFalse() {
        AppSettings.shared.applyBackup(["childModeEnabled": .bool(true)])
        #expect(AppSettings.shared.childModeEnabled == false,
                "a restored backup carrying childModeEnabled=true must never resurrect Child Mode (FEAT-04, D-05, SAFETY)")
    }

    // MARK: - childModeEnabled: no direct setter call can arm it either

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
