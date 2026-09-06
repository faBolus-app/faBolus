import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that `RemoteStatusComposer.compose` populates the additive `watchNotificationIntents` wire
/// field from the SAME unified resolver the phone reads (via `pumpMirrorWatchIntent`), for every
/// relayed pump-mirror category — and that it does so WITHOUT dropping the legacy alert-intensity
/// emission (the watch still reads those until the consumer lands).
struct RemoteStatusComposerWatchIntentTests {

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
            garminBolusEnabled: false,
            alertIntensityMode: "vibrate", alertAudibleMinSeverity: "critical",
            alertCriticalOverridesDnd: false, garminComplicationSlots: ["iob", "reservoir", "battery"],
            notificationRules: rules)
    }

    private func compose(rules: NotificationRules.PersistedRules) -> RemoteCommand {
        let inputs = RemoteStatusInputs(
            includeHistory: false, requestId: nil, snapshot: PumpSnapshot(),
            activeNotifications: [], glucoseHistory: [], now: Date(timeIntervalSince1970: 1_700_000_000),
            remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
            supportsRemoteAlertDismiss: false, rawActiveNotifications: nil, settings: settings(rules: rules))
        return RemoteStatusComposer.compose(inputs)
    }

    /// Every relayed pump-mirror category's emitted token must equal the resolver's own watch intent
    /// for that category — proving the wire value is derived from the ONE resolver, not a parallel path.
    @Test func everyRelayedCategoryTokenMatchesTheResolverWatchIntent() {
        let rules = NotificationRules.PersistedRules(
            sourceOverride: nil,
            groupOverrides: [
                "deliveryStopped": NotificationRules.Rule(intent: .off),
                "glucoseAndControlIQ": NotificationRules.Rule(intent: .alert, watchOverride: .quiet),
            ])
        let cmd = compose(rules: rules)
        let emitted = cmd.watchNotificationIntents
        #expect(emitted != nil, "compose must populate watchNotificationIntents")

        for group in NotificationRules.PumpMirrorGroup.allCases {
            let expected = RemoteCommand.watchIntentWireToken(
                RemoteStatusComposer.pumpMirrorWatchIntent(rules: rules.cascade(for: group)))
            #expect(
                emitted?[group.rawValue] == expected,
                "emitted watch intent for \(group.rawValue) must match the resolver (\(expected))")
        }
    }

    /// Representative concrete values: an explicit category off emits "off"; a per-group watch override
    /// wins over the phone intent; a group left at its fatigue-averse default emits its default token.
    @Test func representativeCategoriesResolveToTheExpectedTokens() {
        let rules = NotificationRules.PersistedRules(
            groupOverrides: [
                "deliveryStopped": NotificationRules.Rule(intent: .off),
                "runningLow": NotificationRules.Rule(intent: .alert, watchOverride: .quiet),
            ])
        let cmd = compose(rules: rules)
        #expect(cmd.watchNotificationIntents?["deliveryStopped"] == "off", "an explicit off rides the wire as off")
        #expect(cmd.watchNotificationIntents?["runningLow"] == "quiet", "a per-group watch override wins")
        // pumpRoutine has no override -> its fatigue-averse default is .quiet.
        #expect(cmd.watchNotificationIntents?["pumpRoutine"] == "quiet", "a default group emits its default token")
    }

    /// The legacy alert-intensity properties are STILL emitted in this step — the watch reads them
    /// until the consumer lands; this landing is additive only.
    @Test func legacyAlertIntensityPropertiesAreStillEmitted() {
        let cmd = compose(rules: NotificationRules.PersistedRules())
        #expect(cmd.alertIntensityMode == "vibrate")
        #expect(cmd.alertAudibleMinSeverity == "critical")
        #expect(cmd.alertCriticalOverridesDnd == false)
    }

    /// The emitted field round-trips over the wire and the fail-safe accessor reads it back.
    @Test func watchIntentsRoundTripAndResolveThroughTheAccessor() throws {
        let rules = NotificationRules.PersistedRules(
            groupOverrides: ["deliveryStopped": NotificationRules.Rule(intent: .off)])
        let cmd = compose(rules: rules)
        let decoded = try RemoteCommand.decodeValidated(try cmd.encoded())
        #expect(decoded.resolvedWatchIntent(for: "deliveryStopped") == .off)
        // A category not present in the map (never a pump-mirror key) fails safe.
        #expect(decoded.resolvedWatchIntent(for: "someFutureAppOwnCategory") == .alert)
    }
}
