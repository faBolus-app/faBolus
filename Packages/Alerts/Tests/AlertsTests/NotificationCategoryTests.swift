import Foundation
import Testing
import faBolusCore

#if canImport(UserNotifications)
import UserNotifications
#endif

@testable import Alerts

/// What a posted notification carries. Nothing can be silenced from a notification: the only action is
/// "Clear" on a dismissable pump notification, which dismisses it on the pump. Replaces the old app's
/// `UnresolvedDoseNotificationsOfferNoSilencingActionTests`, whose snooze button is gone (owner decision
/// 2026-11-01).
@Suite struct NotificationCategoryTests {
    private func request(_ category: NotificationBroker.Category, pumpAlert: PumpAlert? = nil) -> AlertRequest {
        AlertRequest(
            identifier: "x", category: category, severity: .warning, level: category.level, title: "t", body: "b",
            pumpAlert: pumpAlert)
    }

    /// Clear is offered where the session says the phone may clear (`remoteClear` available, or not yet
    /// known for the pump, the phone's to try); an alert to clear on the pump has no action.
    @Test func onlyAPumpNotificationThePhoneMayClearCarriesAnAction() {
        let clearable = PumpAlert(id: 0, kind: .alert, title: "Low insulin", remoteClear: .available)
        let tryable = PumpAlert(id: 0, kind: .alert, title: "Low insulin", remoteClear: .tryable)
        let onThePump = PumpAlert(id: 0, kind: .alert, title: "Low insulin", remoteClear: .unavailable)
        let alarm = PumpAlert(id: 2, kind: .alarm, title: "Occlusion", isDismissable: false)
        let malfunction = PumpAlert(id: 2, kind: .alarm, title: "M", isDismissable: false, malfunctionCode: 2)
        for alert in [clearable, tryable] {
            #expect(
                AlertNotificationCategories.identifier(for: request(.pumpAlert, pumpAlert: alert))
                    == AlertNotificationCategories.dismissablePumpAlert)
        }
        #expect(AlertNotificationCategories.identifier(for: request(.pumpAlert, pumpAlert: onThePump)) == "pumpAlert")
        #expect(AlertNotificationCategories.identifier(for: request(.pumpAlert, pumpAlert: alarm)) == "pumpAlert")
        #expect(AlertNotificationCategories.identifier(for: request(.pumpAlert, pumpAlert: malfunction)) == "pumpAlert")
        for category in NotificationBroker.Category.allCases {
            #expect(AlertNotificationCategories.identifier(for: request(category)) == category.rawValue)
        }
    }

    @Test func clearRoundTripsThePumpNotification() {
        let alert = PumpAlert(id: 5, kind: .cgmAlert, title: "Sensor expiring", detail: "6 h left")
        let info = AlertNotificationCategories.userInfo(for: request(.pumpCgmAlert, pumpAlert: alert))
        #expect(info[AlertNotificationCategories.categoryKey] == "pumpCgmAlert")
        #expect(
            AlertNotificationCategories.pumpAlertToClear(
                actionIdentifier: AlertNotificationCategories.clearAction, userInfo: info) == alert)
        #expect(AlertNotificationCategories.pumpAlertToClear(actionIdentifier: "other", userInfo: info) == nil)
        #expect(
            AlertNotificationCategories.pumpAlertToClear(
                actionIdentifier: AlertNotificationCategories.clearAction, userInfo: [:]) == nil)
    }

    #if canImport(UserNotifications)
    @Test func theRegisteredCategoriesOfferNoSilencingAction() {
        let registered = AlertNotificationCategories.registered()
        for category in registered {
            if category.identifier == AlertNotificationCategories.dismissablePumpAlert {
                #expect(category.actions.map(\.identifier) == [AlertNotificationCategories.clearAction])
            } else {
                #expect(category.actions.isEmpty, "\(category.identifier) must carry no action")
            }
        }
        let ids = Set(registered.map(\.identifier))
        for c in NotificationBroker.Category.allCases { #expect(ids.contains(c.rawValue)) }
    }

    /// The content posts at the request's level, so a time-sensitive category is time-sensitive in iOS.
    @Test func contentCarriesTheLevelAndATriggerOnlyForAFutureFireDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for category in NotificationBroker.Category.allCases {
            let content = AlertNotificationCategories.content(for: request(category))
            #expect(content.interruptionLevel == category.level.userNotificationLevel)
            #expect(content.sound != nil)
        }
        #expect(
            AlertNotificationCategories.content(for: request(.bolusReconciliation)).interruptionLevel
                == .timeSensitive)
        #expect(AlertNotificationCategories.trigger(fireDate: nil, now: now) == nil)
        #expect(AlertNotificationCategories.trigger(fireDate: now.addingTimeInterval(-5), now: now) == nil)
        #expect(AlertNotificationCategories.trigger(fireDate: now.addingTimeInterval(0.5), now: now) == nil)
        #expect(
            AlertNotificationCategories.trigger(fireDate: now.addingTimeInterval(900), now: now)?.timeInterval == 900)
    }
    #endif
}
