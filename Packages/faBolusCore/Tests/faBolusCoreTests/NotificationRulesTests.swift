import Testing
import Foundation
@testable import faBolusCore

/// Pins the rules both surfaces read: a pump notification's category, and the phone's and the watch's
/// intent for a category under the user's policy.
@Suite struct NotificationRulesTests {
    typealias R = NotificationRules
    typealias C = NotificationBroker.Category

    @Test func intentLadderIsOrderedOffQuietAlertUrgent() {
        #expect(R.Intent.off < .quiet)
        #expect(R.Intent.quiet < .alert)
        #expect(R.Intent.alert < .urgent)
        #expect(R.Intent.allCases == [.off, .quiet, .alert, .urgent])
    }

    @Test func aLevelMapsToTheIntentItExpresses() {
        #expect(R.Intent(level: .passive) == .quiet)
        #expect(R.Intent(level: .active) == .alert)
        #expect(R.Intent(level: .timeSensitive) == .urgent)
        #expect(R.Intent(level: .critical) == .urgent)
    }

    /// The watch follows the phone, capped at its vibrating rung: a time-sensitive phone alert vibrates
    /// the watch, a standard one alerts it, and nothing reaches a rung the Garmin ladder doesn't have.
    @Test func theWatchFollowsThePhoneCappedAtAlert() {
        for c in C.allCases {
            let (phone, watch) = R.resolve(c, policy: AlertPolicy())
            #expect(watch == Swift.min(phone, .alert), "\(c.rawValue)")
            #expect(watch != .urgent)
        }
        let urgentLow = R.resolve(.urgentLowGlucose, policy: AlertPolicy())
        #expect(urgentLow.phone == .urgent && urgentLow.watch == .alert)
        let pump = R.resolve(.pumpAlert, policy: AlertPolicy())
        #expect(pump.phone == .alert && pump.watch == .alert)
    }

    /// A category that is off on the phone is off on the watch too (R12: the phone is the authority).
    @Test func aCategoryOffOnThePhoneIsOffOnTheWatch() {
        var policy = AlertPolicy()
        policy.setOn(false, for: .pumpCgmAlert)
        let cgm = R.resolve(.pumpCgmAlert, policy: policy)
        #expect(cgm.phone == .off && cgm.watch == .off)
        let loss = R.resolve(.cgmDataLoss, policy: AlertPolicy())
        #expect(loss.phone == .off && loss.watch == .off, "shown in the app only")
    }

    /// The bolus result resolves urgent on the phone under any policy.
    @Test func theBolusResultResolvesUrgentUnderAnyPolicy() {
        var policy = AlertPolicy()
        for c in C.allCases { policy.setOn(false, for: c) }
        #expect(R.resolve(.bolusReconciliation, policy: policy).phone == .urgent)
    }

    /// Every alarm and every malfunction is a pump alert, whatever its bit: it stops delivery.
    @Test func everyAlarmAndMalfunctionIsAPumpAlert() {
        for id in 0..<64 {
            #expect(R.category(for: PumpAlert(id: id, kind: .alarm, title: "t")) == .pumpAlert)
            #expect(
                R.category(
                    for: PumpAlert(id: id, kind: .alarm, title: "t", isDismissable: false, malfunctionCode: id))
                    == .pumpAlert)
        }
    }

    /// CGM alerts, and the alert bits pumpx2 names as CGM alerts or errors, are "CGM alerts & errors";
    /// other alerts and reminders are "Pump alerts & alarms".
    @Test func cgmAlertsAndCgmNamedAlertBitsAreCgmAlerts() {
        for id in 0..<64 {
            #expect(R.category(for: PumpAlert(id: id, kind: .cgmAlert, title: "t")) == .pumpCgmAlert)
            #expect(R.category(for: PumpAlert(id: id, kind: .reminder, title: "t")) == .pumpAlert)
        }
        // pumpx2: LOW_TRANSMITTER_ALERT 19, SENSOR_EXPIRING_ALERT 22, CGM_ERROR 40, CGM_UNAVAILABLE 48.
        for id in [19, 22, 40, 48] {
            #expect(R.category(for: PumpAlert(id: id, kind: .alert, title: "t")) == .pumpCgmAlert)
        }
        // pumpx2: LOW_INSULIN_ALERT 0, LOW_POWER_ALERT 2, CONTROL_IQ_LOW 51; 52 is unnamed.
        for id in [0, 2, 51, 52] {
            #expect(R.category(for: PumpAlert(id: id, kind: .alert, title: "t")) == .pumpAlert)
        }
    }

    /// Both pump-mirror categories are on by default and alert at the standard level, so a bit filed
    /// under the wrong switch is still announced.
    @Test func bothPumpMirrorCategoriesAlertByDefault() {
        for c in [C.pumpAlert, .pumpCgmAlert] {
            #expect(R.resolve(c, policy: AlertPolicy()).phone == .alert)
        }
    }
}
