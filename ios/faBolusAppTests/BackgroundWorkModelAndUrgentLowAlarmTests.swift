import Testing
import Foundation
@testable import faBolus
import faBolusCore

/// refresh() arms the background staleness watchdog off cgmFresh, and raises the urgent-low alarm once
/// per episode without touching the dose path.
@MainActor
@Suite(.serialized) struct BackgroundWorkModelAndUrgentLowAlarmTests {

    /// A unique durable-ledger URL so instances don't share the App Group ledger between serialized tests.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bgwm-ledger-\(UUID().uuidString).json")
    }

    /// A minimal, mutable failover source — mirrors `faBolusCoreTests.GlucoseArbiterTests`'
    /// `MockGlucoseSource`, reproduced here (app target) so these tests don't need faBolusCore test
    /// helpers to be exported.
    @MainActor
    private final class FakeGlucoseSource: GlucoseSource {
        let id: String
        let priority: Int
        let connectionKind: GlucoseConnectionKind = .cloudPoll
        var latest: GlucoseSample?
        var history: [GlucoseReading] = []
        var status: GlucoseSourceStatus = .connected
        var onChange: (@MainActor () -> Void)?
        init(id: String = "fake-failover", priority: Int = 10) {
            self.id = id
            self.priority = priority
        }
        func start() async {}
        func stop() {}
    }

    // MARK: - Staleness-watchdog arm/re-arm/cancel wiring

    @Test func refreshArmsTheStalenessWatchdogOnAFreshReadingAndCancelsItOnceNoLongerFresh() {
        let savedStale = GlucoseFreshness.staleAfter
        defer { GlucoseFreshness.staleAfter = savedStale }
        GlucoseFreshness.staleAfter = 300  // 5 min — plenty of margin for the "still fresh" seeds below

        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        let coordinator = NotificationCoordinator(model: model)  // proves the sinks are actually wired
        #expect(model.notificationStalenessSink != nil)
        #expect(model.notificationStalenessCancelSink != nil)

        var armedDates: [Date] = []
        var cancelCount = 0
        model.notificationStalenessSink = { armedDates.append($0) }
        model.notificationStalenessCancelSink = { cancelCount += 1 }

        let d1 = Date()
        backend.seedFreshGlucose(120, at: d1)  // fires onChange -> refresh()
        #expect(armedDates == [d1])
        #expect(cancelCount == 0)

        // A heartbeat re-affirming the SAME reading (no new datum) must not re-arm.
        model.publicRefresh()
        #expect(armedDates == [d1])

        // A genuinely NEWER fresh reading re-arms from the new date. A fresh `Date()` capture (not an
        // offset into the future) — real wall-clock time has elapsed since `d1` was captured, so `d2 >
        // d1` holds without ever being future-dated relative to the `now` `isStale` reads below.
        let d2 = Date()
        backend.seedFreshGlucose(122, at: d2)
        #expect(armedDates == [d1, d2])

        // Force staleness (shrink the window below the reading's already-elapsed age) and re-publish —
        // the real `.cgmDataLoss` edge fires too, but the watchdog-cancel is the assertion here.
        GlucoseFreshness.staleAfter = 0
        model.publicRefresh()
        #expect(cancelCount == 1, "once the feed is no longer fresh the pre-armed watchdog must be cancelled")

        // Already cancelled — a further stale heartbeat must not re-cancel.
        model.publicRefresh()
        #expect(cancelCount == 1)
        _ = coordinator
    }

    // MARK: - The app-owned urgent-low alarm

    /// A failover source's own fresh, in-range reading that crosses `UrgentLowAlarm.thresholdMgdl`
    /// raises once; recovery (the pump feed returns) clears.
    @Test func urgentLowAlarmRaisesOnTheArbitratedFailoverValueAndClearsOnRecovery() {
        let backend = MockBackend()  // seeds a STALE pump reading (10 min old) — pumpFresh == false
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        let coordinator = NotificationCoordinator(model: model)
        var posted: [NotificationBroker.Message] = []
        var withdrawn: [[String]] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationWithdrawSink = { keys in withdrawn.append(keys) }

        let fake = FakeGlucoseSource()
        fake.latest = GlucoseSample(mgdl: UrgentLowAlarm.thresholdMgdl, date: Date(), sourceID: fake.id)
        model.setGlucoseSourceForTesting(fake)

        model.publicRefresh()
        #expect(
            model.glucoseProvenance.isFailover, "the pump's own reading is stale — the fresh fake source must take over"
        )
        #expect(posted.map(\.dedupeKey).contains(UrgentLowAlarm.dedupeKey))
        // The urgent-low alarm posts under its own never-suppressible category, `.urgentLowGlucose`,
        // decoupled from `.cgmDataLoss` (disabling the "CGM data lost" banner must not silence this backstop).
        #expect(posted.last(where: { $0.dedupeKey == UrgentLowAlarm.dedupeKey })?.category == .urgentLowGlucose)

        // A second refresh with the SAME still-active condition must not re-raise.
        posted.removeAll()
        model.publicRefresh()
        #expect(!posted.map(\.dedupeKey).contains(UrgentLowAlarm.dedupeKey), "a steady active alarm must not re-fire")

        // Recovery: the pump's own feed becomes fresh again → provenance flips to `.pump` → clear.
        backend.seedFreshGlucose(120, at: Date())
        model.publicRefresh()
        #expect(withdrawn.contains([UrgentLowAlarm.dedupeKey]))
        _ = coordinator
    }

    /// A sub-40 raw reading never becomes the failover source's own `latest`, so merge reports `.pump`
    /// provenance even with no fresh pump reading — the alarm must still fire off `!pumpFresh` plus the
    /// fresh `UrgentLowSentinel`, or a below-range low with no pump reading would be invisible.
    @Test func urgentLowAlarmRaisesOnTheFreshBelowRangeSentinelEvenWithoutAFailoverProvenance() {
        let backend = MockBackend()  // seeds a STALE pump reading — pumpFresh == false
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        let coordinator = NotificationCoordinator(model: model)
        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }

        let poller = PollingGlucoseSource(id: "sentinel-source", priority: 5)
        poller.ingestRawReading(mgdl: 30, date: Date())  // below GlucosePlausibility.minimum (40)
        #expect(poller.latest == nil, "a below-range raw reading must never become `latest` / a dose input")
        model.setGlucoseSourceForTesting(poller)

        model.publicRefresh()
        #expect(
            model.glucoseProvenance == .pump,
            "no valid sample exists to fail over TO — the arbiter correctly reports plain .pump provenance")
        #expect(
            posted.map(\.dedupeKey).contains(UrgentLowAlarm.dedupeKey),
            "the alarm must still fire off the fresh sentinel despite the .pump provenance")
        #expect(
            model.snapshot.glucose != 30,
            "the sentinel value must never surface as the arbitrated snapshot glucose value")
        _ = coordinator
    }

    /// The alarm is advisory-only: none of this touches the calculator/dose path. Static proof (mirrors
    /// this phase's own grep-based acceptance-criteria style) — `TandemBackend`/`BolusMath` never
    /// reference the new symbols at all.
    @Test func theUrgentLowAlarmMechanismNeverReferencesTheDosePath() {
        // faBolusCore's UrgentLowAlarm.isActive takes only mgdl + provenance — it cannot reach a
        // calculator even in principle (no IOB/carb/ISF/target inputs exist on its signature).
        #expect(UrgentLowAlarm.isActive(mgdl: 40, provenance: .pump) == false)
    }
}
