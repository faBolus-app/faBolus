import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// **FEAT-08 SAFETY freeze-guard (Phase 7, 07-05, P-E, D-06/D-07).** The custom alert-rules ENGINE
/// (`AlertRule`/`AlertRuleEngine`/`AlertAction` in the byte-identity-protected `faBolusCore`) cannot
/// be literally deleted — `TandemBackend.swift:172`'s `applyAutoRules` reads
/// `AppSettings.shared.alertRules` and is itself DOSE_PATHS-protected. Instead `alertRules` is frozen
/// to an always-empty computed property (`get { [] } set { } }`), which makes `applyAutoRules`'s
/// `guard !rules.isEmpty else { return }` fire unconditionally — a behavior-neutral early-return,
/// never touching `TandemBackend.swift` or `AlertRuleEngine.swift` themselves (both stay
/// BYTE-IDENTICAL; proven separately by `git diff --quiet pre-narrow/2026-08-20` in this plan's
/// `<verify>`).
///
/// This suite proves the settable INPUT can never carry a non-empty rule-set again by any route:
/// neither a restored settings backup (`applyBackup`) nor a direct setter call. §6d (owner-accepted
/// PASS, 07-OWNER-FLAGS.md) established that no SAFETY alert (glucose LOW/HIGH/urgent-low, or the
/// pump-disconnect/CGM-data-loss/bolus-reconciliation trio) ever routed through
/// `AlertRuleEngine` in the first place — this freeze only removes the CUSTOM, user-authored
/// auto-snooze/auto-dismiss convenience rules, never the safety-notification path. The 3 safety
/// suites (`SafetyNotificationTests`, `NotificationCoordinatorTests`,
/// `PumpBackgroundDisconnectNotificationTests`) staying green UNCHANGED is the direct evidence of
/// that claim, verified alongside this suite, not inside it.
///
/// RED-first: every assertion below FAILS against pre-freeze `main` (the property is a real,
/// persisted stored value that accepts and returns whatever was last written) — proving this guard
/// has teeth. GREEN once the freeze in `AppSettings.swift` lands.
@MainActor
struct AlertRulesFreezeGuardTests {

    /// A representative non-empty rule (matches the shape a real user-authored rule, or a restored
    /// legacy backup, would carry) — used to prove the freeze rejects it via every route.
    private static func sampleRule() -> AlertRule {
        AlertRule(name: "Overnight snooze", kinds: [.alert], alertIds: [7],
                  startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60,
                  glucoseBelow: nil, glucoseAbove: nil, action: .autoSnooze)
    }

    // MARK: - alertRules starts empty (the frozen default)

    @Test func alertRulesIsAlwaysEmptyByDefault() {
        #expect(AppSettings.shared.alertRules.isEmpty,
                "alertRules must be frozen to always-empty so applyAutoRules early-returns unconditionally (FEAT-08, D-07, SAFETY)")
    }

    // MARK: - a restored settings backup carrying a non-empty rule-set cannot re-arm the engine

    @Test func applyBackupWithNonEmptyAlertRulesLeavesItEmpty() {
        let encoded = (try? JSONEncoder().encode([Self.sampleRule()])) ?? Data()
        AppSettings.shared.applyBackup(["alertRules": .data(encoded)])
        #expect(AppSettings.shared.alertRules.isEmpty,
                "a restored backup carrying a non-empty alertRules blob must never re-arm the custom-rule engine (FEAT-08, D-07, SAFETY)")
    }

    // MARK: - no direct setter call can arm it either (defense-in-depth, no-op setter)

    @Test func directSetterCallOnAlertRulesHasNoEffect() {
        AppSettings.shared.alertRules = [Self.sampleRule(), Self.sampleRule()]
        #expect(AppSettings.shared.alertRules.isEmpty,
                "alertRules's getter-level freeze must reject a direct setter call too, not just applyBackup (FEAT-08, D-07, SAFETY)")
    }

    // MARK: - resetPumpRelevantSettings' own alertRules = [] assignment stays a harmless no-op

    @Test func resetPumpRelevantSettingsLeavesAlertRulesEmpty() {
        AppSettings.shared.resetPumpRelevantSettings()
        #expect(AppSettings.shared.alertRules.isEmpty)
    }
}
