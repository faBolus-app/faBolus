import Testing
import Foundation
@testable import faBolusCore

/// Pins the alert policy: per-category on/off with fixed urgency, the bolus result never suppressed, every
/// safety category posted time-sensitive, nothing above time-sensitive this release, and nothing but the
/// user's own switch suppressing a category.
@Suite struct NotificationBrokerTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private func msg(_ c: C, severity: AlertSeverity = .warning, id: String = "k") -> B.Message {
        B.Message(category: c, severity: severity, title: "t", body: "b", identifier: id)
    }

    /// Every switchable category off: the most hostile policy a user can set.
    private var everythingOff: AlertPolicy {
        var p = AlertPolicy()
        for c in C.allCases { p.setOn(false, for: c) }
        return p
    }

    @Test func exactlyTheFiveSafetySetCategories() {
        // The app's own safety categories: the bolus result, pump disconnected, connection unstable, the
        // backup urgent low and CGM loss (shown in the app only this release).
        let safety = Set(C.allCases.filter { $0.isSafetySet }.map(\.rawValue))
        #expect(
            safety == [
                "pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "pumpConnectionUnstable", "urgentLowGlucose"
            ])
    }

    /// Changed: pump-mirrored notifications are two categories now, the two switches Tandem's app has
    /// (owner decision 2026-11-01), not one.
    @Test func pumpAndCgmAlertsAreThePumpMirrorCategories() {
        let mirror = Set(C.allCases.filter { $0.notificationSource == .pumpMirror }.map(\.rawValue))
        #expect(mirror == ["pumpAlert", "pumpCgmAlert"])
    }

    /// The plan: every safety category is posted time-sensitive. CGM loss would be too, but it never
    /// notifies this release, so it is asserted through its level only.
    @Test func everySafetyCategoryPostsTimeSensitive() {
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            let d = B.decide(msg(c), policy: AlertPolicy())
            #expect(d.level == .timeSensitive, "\(c.rawValue) must post time-sensitive")
        }
        #expect(C.cgmDataLoss.level == .timeSensitive)
        for c in [C.bolusReconciliation, .pumpDisconnect, .pumpConnectionUnstable, .urgentLowGlucose] {
            #expect(c.isSafetySet)
        }
    }

    /// Without the Critical Alerts entitlement nothing goes above time-sensitive, whatever a category's
    /// level says.
    @Test func nothingPostsAboveTheReleaseCeiling() {
        #expect(AlertInterruptionLevel.releaseCeiling == .timeSensitive)
        for c in C.allCases {
            if let level = B.decide(msg(c, severity: .critical), policy: AlertPolicy()).level {
                #expect(level <= .timeSensitive, "\(c.rawValue) posted above time-sensitive")
            }
        }
    }

    /// Room for a pump without its own screen: every category carries an escalation, and nothing escalates
    /// past one notification this release.
    @Test func nothingEscalatesPastOneNotificationThisRelease() {
        #expect(AlertEscalation.releaseCeiling == AlertEscalation.none)
        for c in C.allCases {
            let d = B.decide(c, policy: AlertPolicy())
            if d.deliver { #expect(d.escalation == AlertEscalation.none, "\(c.rawValue)") }
        }
    }

    /// The core of R11: the bolus result is never suppressed. Every switch off, and it still posts,
    /// time-sensitive.
    @Test func theBolusResultIsNeverSuppressed() {
        let policy = everythingOff
        #expect(!C.bolusReconciliation.canBeTurnedOff)
        #expect(policy.isOn(.bolusReconciliation))
        let d = B.decide(msg(.bolusReconciliation), policy: policy)
        #expect(d.deliver && d.level == .timeSensitive && d.reason == nil)
    }

    /// Changed: turning a safety category off suppresses it — every one except the bolus result, which
    /// the old ladder could also lower to Off (the plan: the app never suppresses it).
    @Test func turningOffSuppressesEverySwitchableSafetyCategoryButNotTheBolusResult() {
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            var policy = AlertPolicy()
            policy.setOn(false, for: c)
            let d = B.decide(msg(c), policy: policy)
            if c == .bolusReconciliation {
                #expect(d.deliver, "the bolus result can't be turned off")
            } else {
                #expect(!d.deliver && d.reason == .categoryOff, "\(c.rawValue): turned off must suppress")
            }
        }
    }

    /// Changed: the old "no cascade" fallback is gone. Under the most hostile policy only the bolus result
    /// posts, and CGM loss is refused as shown-in-the-app-only.
    @Test func underEverySwitchOffOnlyTheBolusResultPosts() {
        let policy = everythingOff
        for c in C.allCases {
            let d = B.decide(msg(c), policy: policy)
            switch c {
            case .bolusReconciliation: #expect(d.deliver)
            case .cgmDataLoss: #expect(!d.deliver && d.reason == .uiStateOnly)
            default: #expect(!d.deliver && d.reason == .categoryOff, "\(c.rawValue)")
            }
        }
    }

    @Test func bolusDeliveryFailedIsSwitchableNotASafetyCategory() {
        #expect(!C.bolusDeliveryFailed.isSafetySet)
        #expect(C.bolusDeliveryFailed.canBeTurnedOff)
        #expect(AlertPolicy().isOn(.bolusDeliveryFailed), "on by default")
        var off = AlertPolicy()
        off.setOn(false, for: .bolusDeliveryFailed)
        let d = B.decide(msg(.bolusDeliveryFailed), policy: off)
        #expect(!d.deliver && d.reason == .categoryOff)
        #expect(B.decide(msg(.bolusDeliveryFailed), policy: AlertPolicy()).level == .active)
    }

    /// The urgent-low backstop is its own category: turning CGM loss off doesn't touch it.
    @Test func urgentLowGlucoseIsIndependentOfCgmDataLoss() {
        var policy = AlertPolicy()
        policy.setOn(false, for: .cgmDataLoss)
        let d = B.decide(msg(.urgentLowGlucose), policy: policy)
        #expect(d.deliver && d.level == .timeSensitive)
    }

    @Test func connectionUnstableIsIndependentOfPumpDisconnect() {
        var policy = AlertPolicy()
        policy.setOn(false, for: .pumpDisconnect)
        #expect(B.decide(msg(.pumpConnectionUnstable), policy: policy).deliver)
        var aimed = AlertPolicy()
        aimed.setOn(false, for: .pumpConnectionUnstable)
        #expect(B.decide(msg(.pumpConnectionUnstable), policy: aimed).reason == .categoryOff)
        #expect(B.decide(msg(.pumpDisconnect), policy: aimed).deliver)
    }

    /// "Pump disconnected" is off exactly when its delay is "never" (owner decision 2026-11-01).
    @Test func pumpDisconnectIsOffWhenItsDelayIsNever() {
        var policy = AlertPolicy()
        #expect(policy.pumpDisconnectDelay == .fifteenMinutes, "the owner's default")
        #expect(B.decide(msg(.pumpDisconnect), policy: policy).level == .timeSensitive)
        policy.pumpDisconnectDelay = .never
        #expect(!policy.isOn(.pumpDisconnect))
        #expect(B.decide(msg(.pumpDisconnect), policy: policy).reason == .categoryOff)
        policy.setOn(true, for: .pumpDisconnect)
        #expect(policy.pumpDisconnectDelay == .fifteenMinutes, "turning it back on restores the default delay")
        policy.pumpDisconnectDelay = .immediately
        policy.setOn(true, for: .pumpDisconnect)
        #expect(policy.pumpDisconnectDelay == .immediately, "turning on an on category keeps the user's delay")
    }

    /// Changed: severity never changes the decision (the old `.critical` bypass was already retired;
    /// now nothing but the category and the policy count).
    @Test func severityNeverChangesTheDecision() {
        var off = AlertPolicy()
        off.setOn(false, for: .pumpAlert)
        for severity in AlertSeverity.allCases {
            #expect(B.decide(msg(.pumpAlert, severity: severity), policy: off).reason == .categoryOff)
            #expect(B.decide(msg(.pumpAlert, severity: severity), policy: AlertPolicy()).level == .active)
        }
    }

    /// Changed (the old daily budget, rate limit, episode dedupe and snooze are gone; owner decision
    /// 2026-11-01): deciding the same message any number of times gives the same answer, because no
    /// count or timer is involved.
    @Test func noCountOrSnoozeEverSuppresses() {
        let policy = AlertPolicy()
        for _ in 0..<500 {
            #expect(B.decide(msg(.remoteBolusRejected), policy: policy).deliver)
        }
    }

    /// Every category is on by default; no category is silent out of the box.
    @Test func everyCategoryIsOnByDefault() {
        let policy = AlertPolicy()
        for c in C.allCases { #expect(policy.isOn(c), "\(c.rawValue) must default on") }
        for c in C.allCases where c.deliversAsNotification {
            #expect(B.decide(msg(c), policy: policy).deliver)
        }
    }

    /// The settings switches: every category but the bolus result and CGM loss.
    @Test func settingsShowASwitchForEveryCategoryButTheBolusResultAndCgmLoss() {
        #expect(
            Set(AlertPolicy.switchableCategories.map(\.rawValue)) == [
                "pumpDisconnect", "pumpConnectionUnstable", "urgentLowGlucose", "pumpAlert", "pumpCgmAlert",
                "bolusDeliveryFailed", "remoteBolusRejected"
            ])
    }

    @Test func policyRoundTripsAndDecodesTolerantly() throws {
        var policy = AlertPolicy(pumpDisconnectDelay: .fiveMinutes)
        policy.setOn(false, for: .pumpAlert)
        let again = try JSONDecoder().decode(AlertPolicy.self, from: JSONEncoder().encode(policy))
        #expect(again == policy)
        // An unknown category, an attempt to turn the bolus result off, and an unknown delay decode without
        // failing: the unknown ones are dropped, the bolus result stays on, the delay falls back.
        let json = """
            {"pumpDisconnectDelay":"fortnight","off":["pumpAlert","retiredCategory","bolusReconciliation"]}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AlertPolicy.self, from: json)
        #expect(!decoded.isOn(.pumpAlert))
        #expect(decoded.isOn(.bolusReconciliation))
        #expect(decoded.pumpDisconnectDelay == .fifteenMinutes)
        var expected = AlertPolicy()
        expected.setOn(false, for: .pumpAlert)
        #expect(decoded == expected)
        // An empty blob is every category on.
        #expect(try JSONDecoder().decode(AlertPolicy.self, from: Data("{}".utf8)) == AlertPolicy())
    }
}
