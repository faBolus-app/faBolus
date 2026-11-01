import Foundation
import RemoteProtocol
import Testing

@testable import Alerts
@testable import RemoteHost
@testable import faBolusCore

@Suite struct StatusComposerTests {
    static let now = Date(timeIntervalSince1970: TimeInterval(GoldenFixtures.now))
    static let access = AccessPolicy.AccessContext(
        phoneReadOnly: false, remotesReadOnly: false, capabilities: .tslimX2, garminBolusEnabled: true)

    func observed<V>(_ v: V, age: TimeInterval) -> Observed<V> {
        Observed(v, measuredAt: Self.now.addingTimeInterval(-age), receivedAt: Self.now)
    }

    func compose(
        _ pump: PumpState, block: BolusBlock? = nil, alerts: [ActiveAlert] = [],
        access: AccessPolicy.AccessContext = access, provenance: GlucoseProvenance = .pump,
        autoCorrection: Date? = nil
    ) -> StatusPayload {
        StatusComposer.compose(
            StatusInputs(
                pump: pump, glucoseProvenance: provenance, access: access, bolusBlock: block, alerts: alerts,
                lastAutoCorrection: autoCorrection, configRevision: "0123456789abcdef", remoteSizeLimitUnits: 5,
                now: Self.now))
    }

    var connected: PumpState {
        var p = PumpState()
        p.link = .connected
        p.model = .tslimX2
        return p
    }

    /// The last auto-correction goes as its own time; none known, or a time in the future beyond clock
    /// skew, goes as nothing.
    @Test func theLastAutoCorrectionIsSentOnlyWhenKnownAndBelievable() {
        let at = Self.now.addingTimeInterval(-2700)
        #expect(compose(connected, autoCorrection: at).lastAutoCorrectionAt == Int(at.timeIntervalSince1970))
        #expect(compose(connected).lastAutoCorrectionAt == nil)
        #expect(compose(connected, autoCorrection: Self.now.addingTimeInterval(3600)).lastAutoCorrectionAt == nil)
        #expect(compose(connected, autoCorrection: Date(timeIntervalSince1970: 0)).lastAutoCorrectionAt == nil)
    }

    /// Each value keeps the time it was measured; the watch ages it itself.
    @Test func valuesCarryTheirMeasurementTimes() {
        var p = connected
        p.glucose = observed(PumpGlucose(mgdl: 142, trend: .rising), age: 80)
        p.insulinOnBoard = observed(1.25, age: 20)
        p.bolusCalculator = observed(
            BolusCalculatorSettings(carbRatio: 7.5, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 25), age: 20)
        p.basalDeliveryState = observed(.suspended, age: 40)
        let s = compose(p, provenance: .failover(sourceID: "dexcom-share", reason: .pumpStale))
        #expect(
            s.glucose == Timed(GlucoseReading(mgdl: 142, trend: .rising, backup: true), at: GoldenFixtures.now - 80))
        #expect(s.insulinOnBoardMilliunits == Timed(1250, at: GoldenFixtures.now - 20))
        #expect(s.calculator?.value.carbRatioMilligramsPerUnit == 7500)
        #expect(s.calculator?.value.maxBolusMilliunits == 25_000)
        #expect(s.basal == Timed(.suspended, at: GoldenFixtures.now - 40))
        #expect(s.remoteLimitMilliunits == 5000)
        #expect(s.sentAt == GoldenFixtures.now)
    }

    /// A value dated in the future can't be trusted, so it isn't sent as current.
    @Test func aValueFromTheFutureIsLeftOut() {
        var p = connected
        p.insulinOnBoard = observed(1.0, age: -600)
        p.reservoirUnits = Observed(100, measuredAt: .distantPast, receivedAt: Self.now)
        let s = compose(p)
        #expect(s.insulinOnBoardMilliunits == nil)
        #expect(s.reservoirMilliunits == nil)
    }

    @Test func unusableCalculatorSettingsAreLeftOut() {
        var p = connected
        p.bolusCalculator = observed(
            BolusCalculatorSettings(carbRatio: 0, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 25), age: 1)
        #expect(compose(p).calculator == nil)
    }

    /// The status's gate is the composer's own availability check, so the watch's button and the phone's
    /// answer agree.
    @Test func theGateFollowsTheComposer() {
        #expect(compose(connected).bolusBlock == nil)
        #expect(compose(PumpState()).bolusBlock == .pumpNotConnected)
        #expect(compose(connected, block: .unknownOutcome(since: Self.now)).bolusBlock == .outcomeUnknown)
        #expect(compose(connected, block: .bolusInProgress).bolusBlock == .bolusInProgress)
        #expect(compose(connected, block: .ledgerUnreadable).bolusBlock == .deliveryLocked)
        var off = Self.access
        off.garminBolusEnabled = false
        #expect(compose(connected, access: off).bolusBlock == .watchBolusOff)
        var readOnly = Self.access
        readOnly.remotesReadOnly = true
        #expect(compose(connected, access: readOnly).bolusBlock == .readOnly)
        var mobi = connected
        mobi.model = .mobi
        #expect(compose(mobi).bolusBlock == .pumpCannotBolus)
        var loading = connected
        loading.cartridge = observed(CartridgeLoadState(rawValue: 1), age: 1)
        #expect(compose(loading).bolusBlock == .cartridgeNotReady)
    }

    @Test func theActiveBolusIsSentWhoeverStartedIt() {
        var p = connected
        p.bolusState = observed(
            .inProgress(
                DoseEntry(startDate: Self.now.addingTimeInterval(-30), programmedUnits: 4, deliveredUnits: 1.25)),
            age: 1)
        #expect(
            compose(p).activeBolus
                == ActiveBolus(requestedMilliunits: 4000, deliveredMilliunits: 1250, startedAt: GoldenFixtures.now - 30)
        )
    }

    static func alert(
        _ id: String, _ severity: AlertSeverity, _ level: AlertInterruptionLevel, pump: PumpAlert? = nil
    ) -> ActiveAlert {
        ActiveAlert(
            AlertRequest(
                identifier: id, category: .pumpAlert, severity: severity, level: level, title: "T", body: "B",
                pumpAlert: pump))
    }

    /// The watch mirrors the phone's list, most severe first, capped at vibration; a malfunction is never
    /// offered as dismissable, and a pump alert is only when the session says it can be cleared remotely:
    /// one the phone may still try isn't.
    @Test func alertsAreMirroredInOrder() {
        let malfunction = PumpAlert(
            id: 4, kind: .alarm, title: "M", isDismissable: true, malfunctionCode: 4, remoteClear: .available)
        func alerts(_ clear: RemoteClear) -> [ActiveAlert] {
            [
                Self.alert("info", .info, .passive),
                Self.alert("crit", .critical, .timeSensitive, pump: malfunction),
                Self.alert(
                    "warn", .warning, .active, pump: PumpAlert(id: 2, kind: .alert, title: "L", remoteClear: clear))
            ]
        }
        let items = StatusComposer.alertItems(alerts(.available))
        #expect(items.map(\.id) == ["crit", "warn", "info"])
        #expect(items.map(\.intent) == [.alert, .alert, .quiet])
        #expect(items.map(\.dismissable) == [false, true, false])
        #expect(StatusComposer.alertItems(alerts(.tryable)).map(\.dismissable) == [false, false, false])
        #expect(StatusComposer.alertItems(alerts(.unavailable)).map(\.dismissable) == [false, false, false])
    }

    @Test func longTextIsCutToTheLimit() {
        var a = Self.alert("x", .info, .active)
        a.title = String(repeating: "t", count: 200)
        a.body = String(repeating: "b", count: 900)
        let item = StatusComposer.alertItems([a])[0]
        #expect(item.title.count == WireLimits.maxTitleLength)
        #expect(item.body.count == WireLimits.maxTextLength)
        #expect(RemoteMessage.receive(RemoteMessage.status(compose(connected, alerts: [a])).wire) != .unrecognized)
    }

    /// What the composer builds always decodes on the other side.
    @Test func aComposedStatusIsAValidMessage() {
        var p = connected
        p.glucose = observed(PumpGlucose(mgdl: 38, trend: nil), age: 900)
        p.battery = observed(PumpBattery(percent: 140, isCharging: nil), age: 10)
        let status = compose(p, alerts: [Self.alert("a", .warning, .active)])
        #expect(RemoteMessage.receive(RemoteMessage.status(status).wire) == .message(.status(status)))
    }
}

@Suite struct ConfigComposerTests {
    static let access = StatusComposerTests.access

    /// Settings the watch can't use are corrected, never sent as they are.
    @Test func impossibleSettingsAreCorrected() {
        var p = WatchPreferences()
        p.screenOrder = ["bogus", "details", "details", "clock"]
        p.defaultScreen = "glance"
        p.watchChartRanges = [5, 6, 6]
        p.complicationSlots = ["basal", "iob", "reservoir", "battery"]
        p.complicationLabels = false
        p.bolusMode = "extended"
        p.glucosePlotFloor = 50
        p.glucosePlotFloorSmall = 40
        p.glucosePlotCeilingSmall = 350
        let c = ConfigComposer.compose(p, access: Self.access, freshness: .standard)
        #expect(c.screenOrder == [.details, .clock])
        #expect(c.defaultScreen == .details)
        #expect(c.chartHours == [6])
        #expect(c.complicationSlots == [.basal, .iob, .reservoir])
        #expect(c.complicationLabels == false)
        #expect(c.defaultBolusMode == .carbs)
        #expect(c.plotFloorMgdl == 40)
        #expect(c.plotCeilingMgdl == 350)
        #expect(RemoteMessage.receive(RemoteMessage.config(c).wire) == .message(.config(c)))
    }

    @Test func anEmptyLayoutFallsBackToTheDefault() {
        var p = WatchPreferences()
        p.screenOrder = []
        p.watchChartRanges = []
        let c = ConfigComposer.compose(p, access: Self.access, freshness: .standard)
        #expect(c.screenOrder == [.glance, .alerts, .history, .details])
        #expect(c.chartHours == WatchConfig.allowedChartHours)
    }

    /// The watch's staleness is the phone's own freshness windows, in whole minutes rounded down and clamped:
    /// never current on the watch for longer than on the phone.
    @Test func theWatchsStalenessFollowsThePhonesFreshness() {
        let p = WatchPreferences()
        var f = FreshnessThresholds(glucoseStaleAfter: 10 * 60, glucoseHideAfter: 30 * 60)
        var c = ConfigComposer.compose(p, access: Self.access, freshness: f)
        #expect(c.glucoseStaleMinutes == 10)
        #expect(c.glucoseHideDelayMinutes == 20)
        f.glucoseHideAfter = nil
        #expect(ConfigComposer.compose(p, access: Self.access, freshness: f).glucoseHideDelayMinutes == nil)
        f.glucoseStaleAfter = .nan
        c = ConfigComposer.compose(p, access: Self.access, freshness: f)
        #expect(c.glucoseStaleMinutes == 0)
        f.glucoseStaleAfter = 90
        #expect(ConfigComposer.compose(p, access: Self.access, freshness: f).glucoseStaleMinutes == 1)
        f.glucoseStaleAfter = 30
        #expect(ConfigComposer.compose(p, access: Self.access, freshness: f).glucoseStaleMinutes == 0)
        f.glucoseStaleAfter = 600 * 60
        #expect(ConfigComposer.compose(p, access: Self.access, freshness: f).glucoseStaleMinutes == 60)
    }

    /// Whether the watch may bolus is the access the phone enforces, not a copy of it.
    @Test func bolusingOnTheWatchIsTheAccessThePhoneEnforces() {
        var access = Self.access
        #expect(ConfigComposer.compose(WatchPreferences(), access: access, freshness: .standard).bolusEnabled)
        access.garminBolusEnabled = false
        access.remotesReadOnly = true
        let c = ConfigComposer.compose(WatchPreferences(), access: access, freshness: .standard)
        #expect(!c.bolusEnabled)
        #expect(c.readOnly)
        // The phone's own read-only mode isn't the watch's setting; the gate in the status carries it.
        access = Self.access
        access.phoneReadOnly = true
        #expect(!ConfigComposer.compose(WatchPreferences(), access: access, freshness: .standard).readOnly)
    }

    /// The IOB and settings windows the watch's calculator and slots use are the phone's.
    @Test func theWatchsInputWindowsAreThePhones() {
        let f = FreshnessThresholds(
            insulinOnBoardStaleAfter: 4 * 60, therapyStaleAfter: 20 * 60, pumpStatusStaleAfter: 30 * 60)
        let c = ConfigComposer.compose(WatchPreferences(), access: Self.access, freshness: f)
        #expect(c.iobStaleMinutes == 4)
        #expect(c.therapyStaleMinutes == 20)
        #expect(c.pumpStatusStaleMinutes == 30)
        #expect(
            ConfigComposer.compose(WatchPreferences(), access: Self.access, freshness: .standard)
                .glucoseIncludableMinutes == 15)
        let unusable = FreshnessThresholds(insulinOnBoardStaleAfter: -1, therapyStaleAfter: 45)
        let none = ConfigComposer.compose(WatchPreferences(), access: Self.access, freshness: unusable)
        #expect(none.iobStaleMinutes == 0)
        #expect(none.therapyStaleMinutes == 0)
    }

    /// The constants the watch keeps its own copy of are the phone's: a change here fails until the contract
    /// file, and with it the watch's test, follows.
    @Test func theSharedConstantsAreThePhones() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RemoteProtocol/contract/shared_constants.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Int]])
        #expect(
            object["glucoseBands"] == [
                "low": GlucoseThresholds.low, "high": GlucoseThresholds.high, "veryHigh": GlucoseThresholds.veryHigh
            ])
        #expect(object["plausibleGlucose"] == ["min": GlucosePlausibility.minimum, "max": GlucosePlausibility.maximum])
    }

    /// The default preferences are the golden config.
    @Test func theDefaultsAreTheGoldenConfig() {
        #expect(
            ConfigComposer.compose(WatchPreferences(), access: Self.access, freshness: .standard)
                == GoldenFixtures.config)
    }

    @Test func theUnitsStepIsExact() {
        var p = WatchPreferences()
        p.bolusIncrementUnits = 0.1
        #expect(ConfigComposer.compose(p, access: Self.access, freshness: .standard).unitsStepMilliunits == 100)
    }
}

@Suite struct ComposerReviewTests {
    /// One value outside what the message allows is left out; the rest of the status still reads.
    @Test func anOutOfRangeValueIsLeftOutNotSent() {
        let t = StatusComposerTests()
        var p = t.connected
        p.glucose = t.observed(PumpGlucose(mgdl: 1023, trend: nil), age: 10)
        p.battery = t.observed(PumpBattery(percent: 140, isCharging: true), age: 10)
        p.bolusCalculator = t.observed(
            BolusCalculatorSettings(carbRatio: 10, correctionFactor: 4000, targetMgdl: 110, maxBolusUnits: 25), age: 1)
        p.insulinOnBoard = t.observed(1, age: 10)
        let s = t.compose(p)
        #expect(s.glucose == nil)
        #expect(s.battery == nil)
        #expect(s.calculator == nil)
        #expect(s.insulinOnBoardMilliunits?.value == 1000)
        #expect(RemoteMessage.receive(RemoteMessage.status(s).wire) == .message(.status(s)))
    }

    /// Readings that share a second can't make a history the decoder rejects.
    @Test func historyFromDuplicateTimesStillReads() {
        let points = [
            HistoryPayload.Point(at: GoldenFixtures.now, mgdl: 120),
            HistoryPayload.Point(at: GoldenFixtures.now, mgdl: 121),
            HistoryPayload.Point(at: GoldenFixtures.now - 300, mgdl: 118), HistoryPayload.Point(at: 5, mgdl: 1)
        ]
        let h = HistoryPayload.newest(points, sentAt: GoldenFixtures.now)
        #expect(h.points.map(\.at) == [GoldenFixtures.now - 300, GoldenFixtures.now])
        #expect(RemoteMessage.receive(RemoteMessage.history(h).wire) == .message(.history(h)))
    }
}
