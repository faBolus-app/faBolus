import Testing
import Foundation
@testable import faBolusCore

/// A CGM gap is UI state, never a notification (owner decisions 2026-08-30 and 2026-11-01; it may become
/// an alert for a pump without its own screen).
///
/// The old app notified once per advanced CGM reading. The gap already shows as UI state (the greyed CGM
/// value with its age), so the category is refused at the one decision point rather than at any poster.
///
/// The boundary this suite defends: refusing `.cgmDataLoss` must NOT silence (a) the app-owned urgent-low
/// backstop, which lives on its own `.urgentLowGlucose` category precisely so it survives this, or (b) a
/// PUMP-raised CGM alert, which arrives on `.pumpCgmAlert` and is a different thing entirely.
@Suite struct CgmGapIsUiStateNotANotificationTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private func msg(_ c: C, severity: AlertSeverity = .warning, id: String = "k") -> B.Message {
        B.Message(category: c, severity: severity, title: "t", body: "b", identifier: id)
    }

    /// `.cgmDataLoss` is the ONLY category that never surfaces as a notification, named exhaustively so a
    /// future category can't be quietly added to the silent set.
    @Test func cgmDataLossIsTheOnlyCategoryThatNeverSurfacesAsANotification() {
        #expect(!C.cgmDataLoss.deliversAsNotification)
        let silent = Set(C.allCases.filter { !$0.deliversAsNotification }.map(\.rawValue))
        #expect(silent == ["cgmDataLoss"])
    }

    /// Refused at every severity and under every policy, including one with the category on.
    @Test func decideRefusesCgmDataLossAtEverySeverityAndUnderEveryPolicy() {
        var off = AlertPolicy()
        off.setOn(false, for: .cgmDataLoss)
        for severity in AlertSeverity.allCases {
            for policy in [AlertPolicy(), off] {
                let d = B.decide(msg(.cgmDataLoss, severity: severity), policy: policy)
                #expect(!d.deliver && d.reason == .uiStateOnly, "a \(severity) .cgmDataLoss must be refused")
            }
        }
    }

    /// The urgent-low backstop is on its own category and still alarms during a gap, even with CGM loss
    /// turned off.
    @Test func theUrgentLowBackstopStillAlarmsDuringACgmGap() {
        var policy = AlertPolicy()
        policy.setOn(false, for: .cgmDataLoss)
        #expect(C.urgentLowGlucose.deliversAsNotification)
        let d = B.decide(msg(.urgentLowGlucose, severity: .critical), policy: policy)
        #expect(d.deliver && d.level == .timeSensitive)
    }

    /// A pump-raised CGM alert (sensor failed) is a `.pumpCgmAlert`, which does notify: a different
    /// channel from the app's own CGM-gap state.
    @Test func aPumpRaisedCgmAlertStillNotifies() {
        let sensorFailed = PumpAlert(id: 11, kind: .cgmAlert, title: "Sensor failed")
        let category = NotificationRules.category(for: sensorFailed)
        #expect(category == .pumpCgmAlert)
        #expect(B.decide(msg(category), policy: AlertPolicy()).deliver)
    }

    /// The other four safety categories notify by default.
    @Test func everyOtherSafetySetCategoryStillDelivers() {
        var delivered: Set<String> = []
        for c in C.allCases where c.isSafetySet && B.decide(msg(c), policy: AlertPolicy()).deliver {
            delivered.insert(c.rawValue)
        }
        #expect(delivered == ["pumpDisconnect", "bolusReconciliation", "pumpConnectionUnstable", "urgentLowGlucose"])
    }
}
