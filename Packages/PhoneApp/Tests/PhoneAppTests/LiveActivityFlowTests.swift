import Alerts
import Foundation
import PumpScript
import PumpSession
import TandemLink
import TandemMessages
import Testing
import WidgetContent
import faBolusCore

@testable import PhoneApp

/// The Live Activity's bolus and alert screens, against the scripted pump: every dose through the remote
/// composer and the phone's delivery path, the watch's 1 → 2 → 3 confirm, and taps from a screen that
/// isn't the current one doing nothing.
@MainActor
@Suite struct LiveActivityFlowTests {
    @MainActor struct Rig {
        let phone: Phone
        let model: AppModel
        let activity: RecordingLiveActivity

        var flow: LiveActivityFlow { model.liveActivityFlow }
        var panel: LiveActivityPanel { flow.panel }
        var view: LiveActivityPanel.Screen { panel.view }
        var pump: ScriptedPump { phone.mock.pump }

        /// A tap on the screen showing now, as the Live Activity sends it.
        func tap(_ action: LiveActivityAction, unlocked: Bool = true) async {
            await tap(action, on: panel.screen, unlocked: unlocked)
        }

        func tap(_ action: LiveActivityAction, on screen: String, unlocked: Bool = true) async {
            let model = model
            await phone.driving(model) {
                await model.liveActivityTapped(LiveActivityTap(screen: screen, action: action), unlocked: unlocked)
            }
        }

        func entries() async -> [RemoteBolusLedger.Entry] {
            await model.ledger.ledger.allEntries.filter { $0.request.ledgerKey.peerId == LiveActivityFlow.peerId }
        }

        var initiates: Int { pump.arrivals(of: InitiateBolusRequest.self).count }

        /// Waits, with the pump's clock moving, until the result's headline is `headline`.
        func result(_ headline: String) async -> Bool {
            await phone.until(model) {
                if case .result(let r) = view { return r.headline == headline }
                return false
            }
        }

        /// Entry in units at `units`, from the card.
        func units(_ milliunits: Int) async {
            await tap(.startBolus)
            if case .entry(let e) = view, e.mode != .units { await tap(.switchMode) }
            for _ in 0..<(milliunits / 1000) { await tap(.adjust(up: true, coarse: true)) }
            for _ in 0..<((milliunits % 1000) / 50) { await tap(.adjust(up: true, coarse: false)) }
        }

        func confirm() async {
            for n in 1...3 { await tap(.tap(n)) }
        }
    }

    func rig(bolusing: Bool = true, _ configure: (ScriptedPump) -> Void = { _ in }) async -> Rig {
        let phone = Phone()
        configure(phone.mock.pump)
        let activity = RecordingLiveActivity()
        let model = await phone.launch(liveActivity: activity)
        _ = await phone.until(model) { model.pump.link == .connected }
        // The link has held, so the delivery's untested commands may go out.
        await phone.run(model, for: 12)
        model.settings.liveActivityEnabled = true
        model.settings.liveActivityBolusEnabled = bolusing
        await phone.settle(model)
        return Rig(phone: phone, model: model, activity: activity)
    }

    /// The amount chosen with − and +, the review, then 1, 2, 3 in order: delivered once, through the
    /// ledger as the Live Activity's own request, and the Live Activity was told at each step.
    @Test func aUnitsDoseIsDeliveredAfterOneTwoThree() async {
        let r = await rig()
        #expect(r.view == .idle(.bolus))
        await r.units(1000)
        await r.tap(.adjust(up: false, coarse: false))
        guard case .entry(let entry) = r.view else {
            Issue.record("expected the entry, got \(r.view)")
            return
        }
        #expect(entry.value == "0.95 U")
        #expect(entry.canReview)
        await r.tap(.review)
        guard case .review(let review) = r.view else {
            Issue.record("expected the review, got \(r.view)")
            return
        }
        #expect(review.units == "0.95 U" && review.taps == 0)
        await r.tap(.tap(1))
        await r.tap(.tap(2))
        #expect(r.initiates == 0, "nothing goes before the third tap")
        if case .review(let counted) = r.view { #expect(counted.taps == 2) }
        await r.tap(.tap(3))
        #expect(await r.result("Delivered"))
        let entries = await r.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.request.totalUnits == 0.95)
        #expect(r.initiates == 1)
        #expect(r.activity.shown.last?.content.panel == r.panel)
        await r.tap(.close)
        #expect(r.view == .idle(.bolus))
        await r.model.shutdown()
    }

    /// A tap out of order starts the count again; a tap from an older screen, or one the app never drew
    /// (a relaunch), does nothing; a step that needs an unlocked device does nothing from the other intent.
    @Test func tapsThatDontFitSendNothing() async {
        let r = await rig()
        await r.tap(.startBolus, unlocked: false)
        #expect(r.view == .idle(.bolus), "the bolus needs an unlocked device")
        let card = r.panel.screen
        await r.units(500)
        await r.tap(.review)
        await r.tap(.tap(2))
        if case .review(let review) = r.view { #expect(review.taps == 0) }
        await r.tap(.tap(1))
        await r.tap(.tap(3))
        if case .review(let review) = r.view { #expect(review.taps == 0) }
        // The card's Bolus, drawn before all this, is ignored.
        await r.tap(.startBolus, on: card)
        guard case .review = r.view else {
            Issue.record("expected the review still, got \(r.view)")
            return
        }
        await r.tap(.close)
        // A 3 from a screen this run never drew, as after a relaunch: not sent, and said so.
        await r.tap(.tap(3), on: "old-7")
        guard case .result(let result) = r.view else {
            Issue.record("expected a result, got \(r.view)")
            return
        }
        #expect(result.headline == "Not sent" && result.line == LiveActivityFlow.expiredScreenText)
        #expect(await r.entries().isEmpty && r.initiates == 0)
        await r.model.shutdown()
    }

    /// A review left open past its time can only be started over: its taps send nothing.
    @Test func aReviewExpires() async {
        let r = await rig()
        await r.units(1000)
        await r.tap(.review)
        await r.tap(.tap(1))
        await r.phone.run(r.model, for: LiveActivityFlow.reviewLifetime)
        await r.tap(.tap(2))
        await r.tap(.tap(3))
        guard case .review(let review) = r.view else {
            Issue.record("expected the review, got \(r.view)")
            return
        }
        #expect(review.expired)
        #expect(await r.entries().isEmpty && r.initiates == 0)
        await r.model.shutdown()
    }

    /// Off by default, and off under either read-only switch: no button, and a stale Bolus tap is refused
    /// by the composer's own first checks.
    @Test func offOrReadOnlyHasNoBolus() async {
        let r = await rig(bolusing: false)
        #expect(r.view == .idle(.none))
        await r.tap(.startBolus)
        guard case .result(let refused) = r.view else {
            Issue.record("expected a refusal, got \(r.view)")
            return
        }
        #expect(refused.line == AccessPolicy.DenialReason.remoteBolusDisabled.userMessage)
        await r.tap(.close)
        r.model.settings.liveActivityBolusEnabled = true
        r.model.settings.remotesReadOnly = true
        await r.phone.settle(r.model)
        #expect(r.view == .idle(.none))
        r.model.settings.remotesReadOnly = false
        r.model.settings.phoneReadOnly = true
        await r.phone.settle(r.model)
        #expect(r.view == .idle(.none))
        await r.model.shutdown()
    }

    /// The dial stops at the remote size limit, as the watch's does.
    @Test func theDialStopsAtTheRemoteLimit() async {
        let r = await rig()
        r.model.settings.remoteBolusLimitUnits = 1
        await r.units(1000)
        await r.tap(.adjust(up: true, coarse: false))
        guard case .entry(let entry) = r.view else {
            Issue.record("expected the entry, got \(r.view)")
            return
        }
        #expect(entry.value == "1.00 U" && !entry.canIncrease)
        await r.model.shutdown()
    }

    /// Above target the Live Activity asks whether to correct, each answer naming its whole dose; Carbs
    /// only sends no correction, and the dose delivered is the one the answer named.
    @Test func carbsOnlyFromTheCorrectionQuestion() async {
        let r = await rig { $0.glucose = (220, 60) }
        await r.tap(.startBolus)
        if case .entry(let e) = r.view, e.mode != .carbs { await r.tap(.switchMode) }
        for _ in 0..<3 { await r.tap(.adjust(up: true, coarse: true)) }
        guard case .entry(let entry) = r.view else {
            Issue.record("expected the entry, got \(r.view)")
            return
        }
        #expect(entry.value == "30 g")
        #expect(entry.message == "Correction asked next")
        await r.tap(.review)
        guard case .question(let q) = r.view else {
            Issue.record("expected the question, got \(r.view)")
            return
        }
        #expect(q.ask == "Add a correction?" && q.no == "Carbs only")
        await r.tap(.answer(yes: false))
        guard case .review(let review) = r.view else {
            Issue.record("expected the review, got \(r.view)")
            return
        }
        #expect(review.units == q.noUnits)
        await r.confirm()
        #expect(await r.phone.until(r.model) { await r.entries().count == 1 })
        let entry0 = await r.entries().first
        #expect(entry0.map { formatUnits($0.request.totalUnits) } == q.noUnits)
        #expect(entry0?.request.carbsGrams == 30)
        await r.model.shutdown()
    }

    /// A stale reading the composer may still include is asked about, as the watch asks it: Include sends
    /// the reading it named, and the dose corrected from it is delivered.
    @Test func aStaleReadingIsIncludedOnlyWhenChosen() async {
        let r = await rig { $0.glucose = (220, 9 * 60) }
        await r.tap(.startBolus)
        if case .entry(let e) = r.view, e.mode != .carbs { await r.tap(.switchMode) }
        for _ in 0..<3 { await r.tap(.adjust(up: true, coarse: true)) }
        guard case .entry(let entry) = r.view else {
            Issue.record("expected the entry, got \(r.view)")
            return
        }
        #expect(entry.message == "Stale CGM: asked next")
        await r.tap(.review)
        guard case .question(let q) = r.view else {
            Issue.record("expected the question, got \(r.view)")
            return
        }
        #expect(q.ask == "Include it?" && q.yes == "Include" && q.detail.hasPrefix("Stale CGM"))
        await r.tap(.answer(yes: true))
        guard case .review(let review) = r.view else {
            Issue.record("expected the review, got \(r.view)")
            return
        }
        #expect(review.units == q.yesUnits)
        await r.confirm()
        #expect(await r.phone.until(r.model) { await r.entries().count == 1 })
        let sent = await r.entries().first
        #expect(sent.map { formatUnits($0.request.totalUnits) } == q.yesUnits)
        #expect(sent?.request.bgMgdl == 220)
        await r.model.shutdown()
    }

    /// With little insulin left the phone asks to confirm: the Live Activity shows it, Go on returns to
    /// the 1 → 2 → 3 confirm, and only that second request goes to the pump.
    @Test func lowInsulinIsConfirmedThenSent() async {
        let r = await rig { $0.reservoirUnits = 1 }
        await r.units(500)
        await r.tap(.review)
        await r.confirm()
        guard case .confirm(let confirm) = r.view else {
            Issue.record("expected the confirmation, got \(r.view)")
            return
        }
        #expect(confirm.title == "Low insulin")
        #expect(confirm.goOn == "Go on: 0.50 U")
        #expect(await r.entries().isEmpty && r.initiates == 0)
        await r.tap(.goOn)
        guard case .review(let again) = r.view else {
            Issue.record("expected the review again, got \(r.view)")
            return
        }
        #expect(again.taps == 0)
        await r.confirm()
        #expect(await r.result("Delivered"))
        #expect(await r.entries().count == 1 && r.initiates == 1)
        await r.model.shutdown()
    }

    /// Cancel while delivering stops it, and needs no unlocked device.
    @Test func cancelStopsTheDelivery() async {
        let r = await rig { $0.deliveryMilliunitsPerSecond = 10 }
        await r.units(2000)
        await r.tap(.review)
        await r.confirm()
        #expect(await r.result("Delivering…"))
        guard case .result(let going) = r.view else { return }
        #expect(going.button == .cancel)
        await r.tap(.cancelBolus, unlocked: false)
        #expect(await r.result("Stopped"))
        await r.model.shutdown()
    }

    /// An outcome the app lost track of says to check the pump, and no bolus starts from the Live Activity
    /// until it's settled. The pump acted on the lost reply, so the card offers to cancel what it delivers.
    @Test func anUnknownOutcomeBlocks() async {
        let r = await rig { $0.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: true)] }
        await r.units(500)
        await r.tap(.review)
        await r.confirm()
        #expect(await r.result("Outcome unknown"))
        guard case .unknownOutcome = r.model.bolusBlock else {
            Issue.record("expected the unknown outcome to block, got \(String(describing: r.model.bolusBlock))")
            return
        }
        await r.tap(.close)
        #expect(r.view != .idle(.bolus))
        await r.tap(.startBolus)
        guard case .result(let refused) = r.view else {
            Issue.record("expected a refusal, got \(r.view)")
            return
        }
        #expect(refused.headline == "Can't bolus")
        #expect(await r.entries().count == 1 && r.initiates == 1)
        await r.model.shutdown()
    }

    /// The card shows the pump's alert and opens it. Clear on pump is offered only where the watch offers
    /// it: not on a pump whose clears haven't been seen to work (the phone's first try is its own), and then
    /// it clears through the session.
    @Test func anAlertIsShownAndClearedAsTheWatchWould() async throws {
        let r = await rig { $0.alertBitmap = 1 << 7 }
        _ = await r.phone.until(r.model) { r.flow.alertSummary != nil }
        #expect(r.flow.alertSummary?.count == 1)
        await r.tap(.showAlerts)
        guard case .alert(let untried) = r.view else {
            Issue.record("expected the alert, got \(r.view)")
            return
        }
        #expect(!untried.title.isEmpty)
        #expect(!untried.canClear, "a pump not yet known is the phone's to try first")
        await r.tap(.clearAlert)
        #expect(r.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        await r.tap(.close)
        // The phone's own clear shows this pump acts on one; the alert, raised again, may be cleared remotely.
        let alert = try #require(r.model.pump.alerts?.value.first)
        var outcome: DismissOutcome?
        await r.phone.driving(r.model) { outcome = await r.model.dismiss(alert) }
        #expect(outcome == .cleared)
        _ = await r.phone.until(r.model) { r.flow.alertSummary == nil }
        r.pump.alertBitmap = 1 << 7
        _ = await r.phone.until(r.model) { r.flow.alertSummary != nil }
        await r.tap(.showAlerts)
        guard case .alert(let card) = r.view else {
            Issue.record("expected the alert, got \(r.view)")
            return
        }
        #expect(card.canClear)
        await r.tap(.clearAlert)
        #expect(r.view == .idle(.bolus))
        #expect(r.flow.alertSummary == nil)
        #expect(r.pump.arrivals(of: DismissNotificationRequest.self).count == 2)
        // The phone's notification for it goes with it: the Live Activity never alerts on its own, so the
        // alert was announced once, and is withdrawn once the pump's list no longer has it.
        _ = await r.phone.until(r.model) {
            await r.phone.notifications.removed.contains(AlertEngine.pumpAlertIdentifier(alert))
        }
        #expect(await r.phone.notifications.removed.contains(AlertEngine.pumpAlertIdentifier(alert)))
        await r.model.shutdown()
    }

    /// A Live Activity update with a long alert and a busy screen still fits ActivityKit's limit.
    @Test func theContentFitsWithTheControls() throws {
        var layout = LiveActivityLayout()
        layout.plotRangeHours = 6
        layout.fields = LiveActivityField.allCases
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let points = (0..<288).map { WidgetSnapshot.Point(t: now.addingTimeInterval(Double(-$0 * 75)), mgdl: 100 + $0) }
        let snapshot = WidgetSnapshot(connected: true, publishedAt: now, recent: points.reversed())
        let long = String(repeating: "x", count: 180)
        let panel = LiveActivityPanel(
            screen: "abcdef-123",
            view: .alert(
                .init(
                    title: String(repeating: "t", count: 64), body: long, critical: true, position: "1 of 3",
                    canClear: true, note: "No answer from pump")))
        let content = LiveActivityContent.make(
            from: snapshot, layout: layout, panel: panel,
            alerts: LiveActivityAlerts(topTitle: String(repeating: "t", count: 64), topCritical: true, count: 3),
            now: now)
        let size = try JSONEncoder().encode(content).count
        #expect(size < LiveActivityContent.sizeLimit, "encoded size \(size)")
    }

    /// A layout saved before the compact choice and the bolus controls existed still reads, keeping the
    /// user's choices: the old Bolus pill's key is dropped and the compact view is the trend arrow.
    @Test func anOlderSavedLayoutStillReads() throws {
        let saved = Data(
            #"{"style":"classic","fields":["glucose","iob"],"topRight":"iob","plotRangeHours":3,"plotFloorMgdl":40,"plotCeilingMgdl":300,"showXAxisLine":true,"showYAxisLine":false,"showXAxisTicks":false,"showYAxisTicks":false,"showRangeLines":true,"showBolusShortcut":true}"#
                .utf8)
        let layout = try JSONDecoder().decode(LiveActivityLayout.self, from: saved)
        #expect(layout.style == .classic && layout.plotRangeHours == 3 && layout.showRangeLines)
        #expect(layout.compact == nil)
    }

    /// A tap survives its trip through the intent's text parameter.
    @Test func aTapRoundTrips() {
        let tap = LiveActivityTap(screen: "abc-1", action: .adjust(up: true, coarse: false))
        #expect(LiveActivityTap(encoded: tap.encoded) == tap)
        #expect(LiveActivityTap(encoded: "nonsense") == nil)
        #expect(LiveActivityAction.cancelBolus.needsUnlock == false)
        #expect(LiveActivityAction.tap(3).needsUnlock)
    }
}
