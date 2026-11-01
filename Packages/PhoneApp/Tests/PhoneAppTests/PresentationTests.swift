import Foundation
import Testing
import WidgetContent
import faBolusCore

@testable import PhoneApp

/// The bolus banner for each outcome (rewrite of the old `BolusOutcomeBannerTests` for today's outcomes).
@Suite struct BolusBannerTests {
    @Test func eachOutcomeHasItsBanner() {
        #expect(BolusBanner.make(.delivered(units: 1.5), requestedUnits: 1.5).kind == .success)
        #expect(BolusBanner.make(.delivered(units: 1.5), requestedUnits: 1.5).message == "1.50 U delivered")
        let stopped = BolusBanner.make(.stopped(delivered: 0.4, requested: 1), requestedUnits: 1)
        #expect(stopped.kind == .warning && stopped.message == "0.40 of 1.00 U delivered")
        #expect(BolusBanner.make(.refused(reason: "No cartridge"), requestedUnits: 1).title == "Bolus not delivered")
        #expect(BolusBanner.make(.delivering, requestedUnits: 2).kind == .inProgress)
    }

    /// An unknown outcome is never worded as failed (R11).
    @Test func anUnknownOutcomeIsNeverCalledFailed() {
        let b = BolusBanner.make(.unknown(since: Date()), requestedUnits: 1)
        #expect(b.kind == .warning)
        #expect(!b.title.localizedCaseInsensitiveContains("not delivered"))
        #expect(!b.message.localizedCaseInsensitiveContains("fail"))
        #expect(b.message == BolusBanner.unknownMessage)
    }
}

/// One per-alert remote-clear value drives Clear, "Try clearing from phone" and "clear it on the pump".
@Suite struct AlertClearOfferTests {
    func alert(_ clear: RemoteClear) -> PumpAlert {
        PumpAlert(id: 4, kind: .alert, title: "Low insulin", detail: "", isDismissable: true, remoteClear: clear)
    }

    @Test func theOfferFollowsTheAlertsRemoteClear() {
        #expect(AlertClearOffer(alert(.available)) == .clear)
        #expect(AlertClearOffer(alert(.tryable)) == .tryFromPhone)
        #expect(AlertClearOffer(alert(.unavailable)) == .clearOnPump)
    }

    @Test func aClearThatDidntTakeSaysToClearItOnThePump() {
        #expect(AlertClearOffer.message(after: .cleared) == nil)
        #expect(AlertClearOffer.message(after: .notCleared) == AlertClearOffer.notClearedText)
        #expect(AlertClearOffer.message(after: .unsupported) == AlertClearOffer.notClearedText)
        #expect(AlertClearOffer.message(after: .unconfirmed) != nil)
    }
}

/// Widget reloads follow what the widgets draw, not routine re-reads.
@Suite struct WidgetReloadTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func snap(mgdl: Int, measured: Date, received: Date, iob: Double = 1) -> WidgetSnapshot {
        WidgetSnapshot(
            glucose: Observed(PumpGlucose(mgdl: mgdl, trend: nil), measuredAt: measured, receivedAt: received),
            insulinOnBoard: Observed(iob, measuredAt: received, receivedAt: received), connected: true,
            publishedAt: received)
    }

    @Test func aNewReadingReloadsAtOnceAndARereadDoesNot() {
        let first = snap(mgdl: 120, measured: t0, received: t0)
        #expect(WidgetPublisher.needsReload(first, last: nil, now: t0))
        let reread = snap(mgdl: 120, measured: t0, received: t0.addingTimeInterval(30))
        #expect(!WidgetPublisher.needsReload(reread, last: (first, t0), now: t0.addingTimeInterval(30)))
        let next = snap(mgdl: 125, measured: t0.addingTimeInterval(300), received: t0.addingTimeInterval(300))
        #expect(WidgetPublisher.needsReload(next, last: (first, t0), now: t0.addingTimeInterval(20)))
        let iobChanged = snap(mgdl: 120, measured: t0, received: t0.addingTimeInterval(30), iob: 2)
        #expect(!WidgetPublisher.needsReload(iobChanged, last: (first, t0), now: t0.addingTimeInterval(30)))
        #expect(WidgetPublisher.needsReload(iobChanged, last: (first, t0), now: t0.addingTimeInterval(61)))
        #expect(WidgetPublisher.needsReload(first, last: (first, t0), now: t0.addingTimeInterval(301)))
    }

    /// The pump re-reporting the reservoir unchanged moves the time the widget ages it from, so it reloads
    /// (on the once-a-minute rule) rather than show the value as gone before the phone does.
    @Test func aRereadReservoirReloadsSoItsAgeIsRight() {
        var first = snap(mgdl: 120, measured: t0, received: t0)
        first.reservoirUnits = Observed(150, measuredAt: t0, receivedAt: t0)
        var reread = first
        reread.reservoirUnits = Observed(
            150, measuredAt: t0.addingTimeInterval(90), receivedAt: t0.addingTimeInterval(90))
        #expect(WidgetPublisher.needsReload(reread, last: (first, t0), now: t0.addingTimeInterval(90)))
        var received = first
        received.reservoirUnits = Observed(150, measuredAt: t0, receivedAt: t0.addingTimeInterval(90))
        #expect(!WidgetPublisher.needsReload(received, last: (first, t0), now: t0.addingTimeInterval(90)))
    }
}
