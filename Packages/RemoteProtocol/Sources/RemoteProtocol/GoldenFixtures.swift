import Foundation

/// The golden messages. Each is written to `contract/fixtures/<name>.json` from these values, and every
/// remote's tests decode or produce exactly those files, so both sides test real messages rather than field
/// names.
public enum GoldenFixtures {
    public struct Fixture: Sendable {
        public var name: String
        public var wire: WireValue
        /// The typed message, for the version 2 fixtures.
        public var message: RemoteMessage?
    }

    /// 2026-11-01 12:00:00 UTC.
    public static let now = 1_793_534_400

    public static let config = WatchConfig(
        bolusEnabled: true, readOnly: false, defaultBolusMode: .carbs, unitsStepMilliunits: 50, carbStepGrams: 5,
        screenOrder: [.glance, .alerts, .history, .details], defaultScreen: .glance,
        detailsOrder: [.iob, .reservoir, .battery, .cgm, .lastBolus, .carbRatio, .isf, .target, .maxBolus],
        chartHours: [3, 6, 12, 24], complicationDisplay: .numericColor, complicationSlots: [.iob, .reservoir, .battery],
        clockAnalog: false, glucoseUnit: .mgdl, glucoseStaleMinutes: 6, glucoseHideDelayMinutes: nil, plotFloorMgdl: 40,
        plotCeilingMgdl: 300)

    public static let status = StatusPayload(
        sentAt: now, configRevision: config.revision, pumpLink: .connected,
        glucose: Timed(GlucoseReading(mgdl: 142, trend: .rising, backup: false), at: now - 80),
        insulinOnBoardMilliunits: Timed(1250, at: now - 20), reservoirMilliunits: Timed(143_500, at: now - 40),
        battery: Timed(BatteryReading(percent: 72, charging: false), at: now - 40),
        basal: Timed(.active(milliunitsPerHour: 850), at: now - 40), lastBolusMilliunits: Timed(3200, at: now - 5400),
        calculator: Timed(
            CalculatorSettings(
                carbRatioMilligramsPerUnit: 7500, correctionFactor: 40, targetMgdl: 110, maxBolusMilliunits: 25_000),
            at: now - 20), controlIQ: Timed(ControlIQReading(enabled: true, activity: .normal), at: now - 40),
        maxBasalMilliunitsPerHour: Timed(3000, at: now - 600), lastAutoCorrectionAt: now - 2700, bolusBlock: nil,
        alerts: [
            AlertItem(
                id: "pump.alert.2", title: "Low insulin", body: "50 units or less remain.", severity: .warning,
                intent: .alert, dismissable: true),
            AlertItem(
                id: "app.pumpDisconnected", title: "Pump disconnected",
                body: "faBolus hasn't reached the pump for 15 minutes.", severity: .warning, intent: .alert,
                dismissable: false)
        ], remoteLimitMilliunits: 10_000)

    /// A status before anything has been read, with bolusing blocked.
    public static let statusMinimal = StatusPayload(
        sentAt: now, configRevision: config.revision, pumpLink: .connecting, bolusBlock: .pumpNotConnected)

    /// A status while a bolus is running, glucose from the backup source and stale, basal suspended.
    public static let statusDelivering = StatusPayload(
        sentAt: now, configRevision: config.revision, pumpLink: .connected,
        glucose: Timed(GlucoseReading(mgdl: 38, trend: nil, backup: true), at: now - 900),
        insulinOnBoardMilliunits: Timed(4050, at: now - 10), basal: Timed(.suspended, at: now - 10),
        bolusBlock: .bolusInProgress,
        activeBolus: ActiveBolus(requestedMilliunits: 4000, deliveredMilliunits: 1250, startedAt: now - 30))

    public static let history = HistoryPayload(
        sentAt: now,
        points: (0..<6).map {
            HistoryPayload.Point(at: now - 1500 + $0 * 300, mgdl: [118, 121, 127, 133, 138, 142][$0])
        })

    public static let fixtures: [Fixture] = [
        v2("status", .status(status)),
        v2("status-minimal", .status(statusMinimal)),
        v2("status-delivering", .status(statusDelivering)),
        v2("config", .config(config)),
        v2("history", .history(history)),
        v2(
            "bolusOutcome-delivering",
            .bolusOutcome(
                BolusOutcomePayload(
                    requestId: "1793534390-7-118220", outcome: .delivering, requestedMilliunits: 4000,
                    deliveredMilliunits: nil, message: nil, sentAt: now))),
        v2(
            "bolusOutcome-delivered",
            .bolusOutcome(
                BolusOutcomePayload(
                    requestId: "1793534390-7-118220", outcome: .delivered, requestedMilliunits: 4000,
                    deliveredMilliunits: 4000, message: nil, sentAt: now))),
        v2(
            "bolusOutcome-failed",
            .bolusOutcome(
                BolusOutcomePayload(
                    requestId: "1793534390-8-120004", outcome: .failed, requestedMilliunits: nil,
                    deliveredMilliunits: nil, message: "Remote control is turned off — remotes are read-only.",
                    sentAt: now))),
        v2(
            "dismissResult",
            .dismissResult(
                DismissResultPayload(requestId: "1793534395-r3-119001", alertId: "pump.alert.2", result: .cleared))),
        v2("incompatible", .incompatible(IncompatiblePayload(peerVersion: 3))),
        v2(
            "poll",
            .poll(
                PollPayload(
                    configRevision: config.revision, awaitingRequestId: "1793534390-7-118220", wantsHistory: true,
                    freshGlucose: false, appVersion: "0.1.0"))),
        v2(
            "poll-empty",
            .poll(
                PollPayload(
                    configRevision: nil, awaitingRequestId: nil, wantsHistory: false, freshGlucose: true,
                    appVersion: "0.1.0"))),
        v2(
            "bolus-units",
            .bolus(
                BolusRequestPayload(
                    requestId: "1793534390-7-118220", sentAt: now - 10, amount: .units(milliunits: 4000),
                    glucoseMgdl: nil, includeStaleGlucose: false))),
        v2(
            "bolus-carbs",
            .bolus(
                BolusRequestPayload(
                    requestId: "1793534390-9-118999", sentAt: now - 10,
                    amount: .calculator(carbsGrams: 45, estimateMilliunits: 6000), glucoseMgdl: 142,
                    includeStaleGlucose: false))),
        v2(
            "bolus-carbs-stale",
            .bolus(
                BolusRequestPayload(
                    requestId: "1793534390-10-119500", sentAt: now - 10,
                    amount: .calculator(carbsGrams: 30, estimateMilliunits: 4000), glucoseMgdl: 160,
                    includeStaleGlucose: true))),
        v2("cancel", .cancel(CancelPayload(requestId: "1793534399-11-121000", bolusRequestId: "1793534390-7-118220"))),
        v2("dismiss", .dismiss(DismissPayload(requestId: "1793534395-r3-119001", alertId: "pump.alert.2"))),
        // What the old apps send, so each side can test meeting one.
        Fixture(
            name: "v1-statusRead-from-watch",
            wire: .object([
                "version": .int(1), "kind": .string("statusRead"), "requestId": .string("1793534390-r4-118000")
            ])),
        Fixture(
            name: "v1-bolusRequest-from-watch",
            wire: .object([
                "version": .int(1), "kind": .string("bolusRequest"), "requestId": .string("1793534390-7-118220"),
                "units": .double(2.5), "sentAt": .int(now - 5)
            ])),
        Fixture(
            name: "v1-statusRead-from-phone",
            wire: .object([
                "version": .int(1), "kind": .string("statusRead"), "requestId": .string("1793534390-r4-118000"),
                "units": .double(1.25), "bgMgdl": .double(142), "message": .string("Connected"),
                "trend": .string("up45"), "glucoseEpochSec": .int(now - 80), "canBolus": .bool(true),
                "garminBolusEnabled": .bool(true)
            ])),
        Fixture(
            name: "v1-bolusStatus-from-phone",
            wire: .object([
                "version": .int(1), "kind": .string("bolusStatus"), "requestId": .string("1793534390-7-118220"),
                "status": .string("delivered"), "deliveredUnits": .double(4.0)
            ])),
        Fixture(
            name: "v1-reply-to-statusRead",
            wire: LegacyV1.reply(to: .init(kind: "statusRead", requestId: "1793534390-r4-118000")) ?? .null),
        Fixture(
            name: "v1-reply-to-bolusRequest",
            wire: LegacyV1.reply(to: .init(kind: "bolusRequest", requestId: "1793534390-7-118220")) ?? .null)
    ]

    private static func v2(_ name: String, _ message: RemoteMessage) -> Fixture {
        Fixture(name: name, wire: message.wire, message: message)
    }
}
