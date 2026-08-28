import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Custom auto-snooze rules stay frozen empty so a restored backup or setter cannot re-arm them;
/// they never touch the dose path or the safety-notification path.
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
