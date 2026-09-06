import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that `RemoteStatusComposer.compose` relays the ACTIVE app-own subset (the app-generated safety
/// notifications, incl. the durable unresolved-dose record) to the watch as the additive, source-agnostic
/// `appOwnAlerts` property, carrying each alert's content (key + title) while its resolved per-category
/// WATCH intent rides the shared `watchNotificationIntents` map — derived from the SAME unified resolver
/// the phone reads. The app-own keys are namespaced so they never collide with a pump-mirror group of the
/// same name (e.g. urgentLowGlucose exists on both axes).
struct RemoteStatusComposerAppOwnRelayTests {

    private func settings(rules: NotificationRules.PersistedRules) -> RemoteStatusSettings {
        RemoteStatusSettings(
            bolusMode: "carbs", bolusIncrement: 0.05, carbIncrement: 5,
            garminScreenOrder: ["glance", "alerts"], garminDefaultScreen: "glance",
            glucoseStaleMinutes: 6, glucoseHideDelayMinutes: nil,
            watchDetailsOrder: ["iob"], watchChartRanges: [3, 6],
            garminComplicationDisplay: "numericColor", remotesReadOnly: false,
            garminClockAnalog: false, glucoseDisplayUnitWireToken: "mgdl",
            glucosePlotFloor: 40, glucosePlotCeiling: 300,
            glucosePlotFloorSmall: nil, glucosePlotCeilingSmall: nil,
            garminBolusEnabled: false, garminComplicationSlots: ["iob", "reservoir", "battery"],
            notificationRules: rules)
    }

    private func compose(
        rules: NotificationRules.PersistedRules,
        appOwn: [ActiveAppOwnAlert]
    ) -> RemoteCommand {
        let inputs = RemoteStatusInputs(
            includeHistory: false, requestId: nil, snapshot: PumpSnapshot(),
            activeNotifications: [], glucoseHistory: [], now: Date(timeIntervalSince1970: 1_700_000_000),
            remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
            supportsRemoteAlertDismiss: false, rawActiveNotifications: nil, settings: settings(rules: rules),
            activeAppOwnAlerts: appOwn)
        return RemoteStatusComposer.compose(inputs)
    }

    /// The active app-own subset rides the wire as `appOwnAlerts` (content: namespaced key + title), and
    /// each item's resolved WATCH intent appears in `watchNotificationIntents` under the same namespaced
    /// key, equal to the resolver's own watch intent for that category.
    @Test func composeRelaysTheActiveAppOwnSubsetWithPerCategoryWatchIntent() {
        let rules = NotificationRules.PersistedRules()
        let cmd = compose(
            rules: rules,
            appOwn: [
                ActiveAppOwnAlert(category: .bolusIndeterminate, title: "Bolus outcome unknown"),
                ActiveAppOwnAlert(category: .pumpDisconnect, title: "Pump disconnected"),
            ])

        let relayed = cmd.appOwnAlerts
        #expect(relayed != nil, "compose must populate appOwnAlerts from the active app-own subset")
        let keys = Set((relayed ?? []).map(\.key))
        #expect(
            keys == ["appOwn:bolusIndeterminate", "appOwn:pumpDisconnect"],
            "each active app-own category is relayed under its namespaced key")
        #expect(
            (relayed ?? []).first(where: { $0.key == "appOwn:bolusIndeterminate" })?.title == "Bolus outcome unknown",
            "the relayed item carries the phone-authoritative title")

        for category in [NotificationBroker.Category.bolusIndeterminate, .pumpDisconnect] {
            let key = "appOwn:" + category.rawValue
            let expected = RemoteCommand.watchIntentWireToken(
                NotificationRules.resolve(
                    rules.cascade(for: category),
                    timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable).watch)
            #expect(
                cmd.watchNotificationIntents?[key] == expected,
                "the app-own watch intent for \(key) must match the resolver (\(expected))")
        }
    }

    /// The durable unresolved-dose category (`.bolusIndeterminate`) — the record Phase 27 consumes — is in
    /// the relayed subset when active, defaulting to the app-own safety intent (Alert = vibrate).
    @Test func theRelayedAppOwnSubsetIncludesBolusIndeterminate() {
        let cmd = compose(
            rules: NotificationRules.PersistedRules(),
            appOwn: [ActiveAppOwnAlert(category: .bolusIndeterminate, title: "Bolus outcome unknown")])
        #expect(
            (cmd.appOwnAlerts ?? []).contains(where: { $0.key == "appOwn:bolusIndeterminate" }),
            "the durable unresolved-dose record must be relayed to the watch")
        #expect(
            cmd.watchNotificationIntents?["appOwn:bolusIndeterminate"] == "alert",
            "an app-own safety category defaults to the vibrating rung on the wire")
    }

    /// An explicit per-category Off is the user's own choice and rides the wire as `off`; the watch honors
    /// it (down to nothing), while the phone stays authoritative.
    @Test func anAppOwnCategoryLoweredToOffRidesTheWireAsOff() {
        let rules = NotificationRules.PersistedRules(
            appOwnCategoryOverrides: ["bolusIndeterminate": NotificationRules.Rule(intent: .off)])
        let cmd = compose(
            rules: rules,
            appOwn: [ActiveAppOwnAlert(category: .bolusIndeterminate, title: "Bolus outcome unknown")])
        #expect(
            cmd.watchNotificationIntents?["appOwn:bolusIndeterminate"] == "off",
            "an explicit app-own Off cascades to the watch intent")
    }

    /// No active app-own alerts ⇒ an empty relay (never absent-as-fabricated), and the version const is
    /// never bumped by this additive relay.
    @Test func anEmptyAppOwnSubsetEmitsAnEmptyRelayUnderAnUnchangedVersion() {
        let cmd = compose(rules: NotificationRules.PersistedRules(), appOwn: [])
        #expect(cmd.appOwnAlerts == [], "no active app-own alerts emits an empty relay")
        #expect(cmd.version == 1, "the additive relay never bumps the wire version")
    }

    /// The namespaced app-own key never overwrites a pump-mirror group of the same name — `urgentLowGlucose`
    /// exists on BOTH axes, so both intents must survive independently on the wire.
    @Test func appOwnKeysDoNotCollideWithPumpMirrorGroupsOfTheSameName() {
        let cmd = compose(
            rules: NotificationRules.PersistedRules(),
            appOwn: [ActiveAppOwnAlert(category: .urgentLowGlucose, title: "Urgent low glucose")])
        #expect(
            cmd.watchNotificationIntents?["urgentLowGlucose"] != nil,
            "the pump-mirror urgentLowGlucose intent must still be emitted")
        #expect(
            cmd.watchNotificationIntents?["appOwn:urgentLowGlucose"] != nil,
            "the app-own urgentLowGlucose intent must be emitted under its own namespaced key")
    }
}
