import Testing
import Foundation
import TandemMessages
import faBolusCore
import faBolusDesign

@testable import faBolus

/// Regression net for the app-wide "never display a fabricated value" sweep that followed debug session
/// `tslim-reservoir-battery-zero`. That session fixed `reservoirUnits`/`batteryPercent`; this suite covers
/// the two OTHER fields carrying the identical latent defect, plus the trend arrow.
///
/// **IOB.** `PumpSnapshot.iobUnits: Double = 0` is non-optional with a zero default. `iobDate` already
/// existed as its receipt — but every consumer tested
/// `CalcInputFreshness.iobPresentation(of:) == .stale`, and the never-read case is `.hidden`, NOT
/// `.stale`. So the absent case fell through the staleness test as if it were FRESH: the HUD pill, the
/// details card, the Debug menu, both widgets and the Garmin wire all reported a confident `0.00 U` of
/// active insulin, in the live insulin colour, with no age caveat.
///
/// **Basal.** `basalRateUnitsPerHour: Double = 0` with `basalRateKnown: Bool = false` as its receipt.
/// The flag was set correctly by `PumpResponseApplier` and had **zero consumers** — so every surface
/// printed `0.00 U/hr` for a pump that had never answered op-41, which reads as "delivery stopped".
///
/// **Trend.** `trend` defaults to `GlucoseTrend.flat.rawValue`, so `GlucoseTrend.token(from:)` returned a
/// confident `"flat"` on the wire before any CGM reading existed — the exact "inferred trend presented as
/// a reported one" that `token(from:)`'s own doc comment says it was written to stop.
///
/// The contract is two-sided, and the second side is the safety-critical one:
///   - absent ⇒ unknown on every surface, and ABSENT on the wire, never a number;
///   - GENUINE zero ⇒ still exactly `0.00 U` / `0.00 U/hr`, because "no active insulin" and "basal
///     suspended" are real states the user must be able to see.
///
/// ORACLE TYPE: `specified` — the required distinction is stated directly by the owner ("make sure the
/// app does not show a false value like a zero when it does not have the data") and by the sibling
/// suite's guardrail ("absent DISTINGUISHABLE from zero — not one wrong answer replaced by another").
@Suite @MainActor
struct IobBasalUnknownDisplayTests {

    // MARK: - The snapshot must record whether the read ever landed

    @Test func aFreshSnapshotHasNoIobOrBasalReading() {
        let s = PumpSnapshot()
        #expect(s.iobDate == nil, "a never-read IOB must be marked unknown, not 0.00 U")
        #expect(s.iobUnitsIfRead == nil)
        #expect(!s.basalRateKnown, "a never-read basal must be marked unknown, not 0.00 U/hr")
        #expect(s.basalRateUnitsPerHourIfRead == nil)
    }

    @Test func aControlIQIobReplyStampsTheIobReadReceipt() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.iobUnitsIfRead == nil)
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 1400))
        #expect(b.snapshot.iobUnits == 1.4)
        #expect(b.snapshot.iobUnitsIfRead == 1.4, "op-109 must make the value trustworthy for display")
    }

    @Test func aCurrentBasalStatusReplyStampsTheBasalReadReceipt() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.basalRateUnitsPerHourIfRead == nil)
        b.injectStatusFrameForTesting(FakePumpTransport.currentBasalStatus(currentMilliunitsPerHour: 850))
        #expect(b.snapshot.basalRateUnitsPerHour == 0.85)
        #expect(b.snapshot.basalRateKnown)
        #expect(b.snapshot.basalRateUnitsPerHourIfRead == 0.85)
    }

    /// The load-bearing case, for both fields. A GENUINE zero reply still stamps its receipt, so it keeps
    /// displaying a real 0 — absence and zero are distinguishable in BOTH directions.
    @Test func aGenuineZeroReadIsStampedAndStaysDisplayableAsZero() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBasalStatus(currentMilliunitsPerHour: 0))
        #expect(b.snapshot.iobUnits == 0)
        #expect(b.snapshot.basalRateUnitsPerHour == 0)
        #expect(b.snapshot.iobUnitsIfRead == 0, "no active insulin is a CONFIRMED reading, not an absent one")
        #expect(
            b.snapshot.basalRateUnitsPerHourIfRead == 0,
            "a suspend / 0 U/hr temp rate is a CONFIRMED reading, not an absent one")
        #expect(PumpValuePresentation.text(b.snapshot.iobUnitsIfRead, format: "%.2f U") == "0.00 U")
        #expect(
            PumpValuePresentation.text(b.snapshot.basalRateUnitsPerHourIfRead, format: "%.2f U/hr")
                == "0.00 U/hr")
    }

    // MARK: - The `.hidden` case the surfaces used to swallow

    /// The root pattern behind the IOB half of this bug. `CalcInputPresentation.hidden` is documented as
    /// "no value at all to show (`--`)", but every consumer wrote `== .stale`, so the absent case scored
    /// as NOT stale and was drawn as live data. Pinned here so the enum's third case can't go back to
    /// being unreachable.
    @Test func anAbsentIobPresentsAsHiddenWhichIsNotStale() {
        #expect(CalcInputFreshness.iobPresentation(of: nil) == .hidden)
        #expect(CalcInputFreshness.iobPresentation(of: nil) != .stale, "the trap: `== .stale` reads absent as fresh")
        #expect(CalcInputFreshness.therapyPresentation(of: nil) == .hidden)
        // …while the DOSE path's own predicate has always treated a nil date as stale, which is why the
        // gate prompted "Active insulin not confirmed" about the very same term the row drew as confirmed.
        #expect(CalcInputFreshness.isIobStale(nil))
        #expect(PumpSnapshot().isIobStale())
    }

    // MARK: - The shared presentation funnel

    @Test func anUnreadIobRendersUnknownNotZero() {
        let unknown = PumpValuePresentation.make(nil, format: "%.2f U")
        #expect(unknown.valueText == PumpValuePresentation.unknownText)
        #expect(unknown.valueText != "0.00 U", "absence must never render as 'no active insulin'")
        #expect(!unknown.isKnown)
    }

    @Test func anUnreadBasalRendersUnknownNotZero() {
        let unknown = PumpValuePresentation.make(nil, format: "%.2f U/hr")
        #expect(unknown.valueText == PumpValuePresentation.unknownText)
        #expect(unknown.valueText != "0.00 U/hr", "absence must never render as 'delivery stopped'")
        #expect(!unknown.isKnown)
    }

    // MARK: - The App-Group carrier

    @Test func theWidgetSnapshotCarriesTheIobAndBasalReceipts() {
        let s = WidgetSnapshot()
        #expect(s.iobDate == nil, "a widget payload with no IOB read must render unknown")
        #expect(s.basalRateKnown == nil, "a widget payload with no basal read must render unknown")
    }

    @Test func aWidgetSnapshotRoundTripsTheIobAndBasalReceipts() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var s = WidgetSnapshot(iobUnits: 0, basalRateUnitsPerHour: 0)
        s.iobDate = when
        s.basalRateKnown = true
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded.iobDate == when)
        #expect(decoded.basalRateKnown == true)
        #expect(decoded.iobUnits == 0, "the CONFIRMED zero itself must survive the round trip")
        #expect(decoded.basalRateUnitsPerHour == 0)
    }

    /// A LEGACY payload written before this fix has no `basalRateKnown` key, so it must decode to
    /// UNKNOWN (`nil`), not to `false` and not to a trusted `0`. Fail-safe direction: showing "—" for one
    /// publish cycle is correct; showing a fabricated `0.00 U/hr` is not.
    @Test func aLegacyWidgetPayloadWithoutTheBasalReceiptDecodesAsUnknown() throws {
        let legacy = #"{"iobUnits":1.2,"basalRateUnitsPerHour":0.8,"trendArrow":"→"}"#
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.iobDate == nil)
        #expect(decoded.basalRateKnown == nil)
    }

    /// The publisher must carry the receipts across, or the widget island re-acquires the defect while the
    /// phone is correct.
    @Test func theWidgetPublisherCarriesBothReceipts() {
        var s = PumpSnapshot()
        let published = WidgetPublisher.makeSnapshot(
            s, history: [], staleAfterSec: 360, hideAfterSec: nil)
        #expect(published.iobDate == nil)
        #expect(published.basalRateKnown == false, "unread, positively stated — not a fabricated 0 U/hr")

        s.iobUnits = 0
        s.iobDate = Date(timeIntervalSince1970: 1_700_000_000)
        s.basalRateUnitsPerHour = 0
        s.basalRateKnown = true
        let confirmed = WidgetPublisher.makeSnapshot(
            s, history: [], staleAfterSec: 360, hideAfterSec: nil)
        #expect(confirmed.iobDate != nil)
        #expect(confirmed.basalRateKnown == true)
    }

    /// The widget gallery/preview placeholder must still show its sample IOB — the widgets now gate on
    /// `iobDate`, so an unstamped placeholder would render "—" in the picker.
    @Test func theWidgetPlaceholderStampsItsIobReceiptSoSampleValuesStillRender() {
        let p = WidgetSnapshot.placeholder
        #expect(p.iobUnits == 1.2)
        #expect(p.iobDate != nil, "an unstamped placeholder would show '—' in the widget gallery")
    }

    // MARK: - The remote / Garmin wire

    /// A remote cannot tell a real 0 from a filled-in one, so an unread value must be ABSENT on the wire.
    /// `RemoteCommand.units` (which carries IOB on a `.statusRead`) and `.basalRate` are both already
    /// `Double?`, and `validate()`'s range check passes nil through.
    @Test func theRemoteWireOmitsAnUnreadIobAndBasal() throws {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let unread = RemoteStatusComposer.compose(makeInputs(b.snapshot))
        #expect(unread.units == nil, "an unread IOB must be ABSENT on the wire, never 0")
        #expect(unread.basalRate == nil, "an unread basal must be ABSENT on the wire, never 0")
        // Absent must still be a VALID command — the wire fix must not make a statusRead unsendable.
        try unread.validate()

        b.injectStatusFrameForTesting(FakePumpTransport.controlIQIOB(iobMilliunits: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBasalStatus(currentMilliunitsPerHour: 0))
        let readZero = RemoteStatusComposer.compose(makeInputs(b.snapshot))
        #expect(readZero.units == 0, "a CONFIRMED zero IOB must still be sent as 0")
        #expect(readZero.basalRate == 0, "a CONFIRMED suspend must still be sent as 0")
        try readZero.validate()
    }

    /// No glucose reading ⇒ no trend to report. `PumpSnapshot.trend`'s default is
    /// `GlucoseTrend.flat.rawValue`, so before this the wire carried a confident `"flat"` with no
    /// `bgMgdl` at all.
    @Test func theRemoteWireOmitsTheTrendWhenThereIsNoGlucoseReading() {
        var s = PumpSnapshot()
        #expect(s.glucose == nil)
        #expect(s.trend == GlucoseTrend.flat.rawValue, "the fabricated default this test exists to contain")
        let noReading = RemoteStatusComposer.compose(makeInputs(s))
        #expect(noReading.trend == nil, "a flat arrow with no reading is an inferred trend sent as a reported one")

        // With a real reading the trend travels exactly as before — this must not suppress a real arrow.
        s.glucose = 124
        s.glucoseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = RemoteStatusComposer.compose(makeInputs(s))
        #expect(reading.trend == GlucoseTrend.flat.token)
    }

    // MARK: - GUARDRAIL: the dose path must be byte-identical

    /// Same guardrail the reservoir/battery fix left behind. The funnels are ADDITIVE computed
    /// properties: `iobUnits` and `basalRateUnitsPerHour` keep their non-optional types and zero
    /// defaults, so the FROZEN dose path sees byte-identically what it saw before. Making either
    /// optional-on-absence would flip a fail-closed pre-guard open.
    @Test func theSnapshotsDosePathFieldsKeepTheirTypesAndDefaults() {
        let s = PumpSnapshot()
        #expect(s.iobUnits == 0, "the frozen non-optional dose-path field keeps its 0 default")
        #expect(s.basalRateUnitsPerHour == 0)
        #expect(s.reservoirUnits == 0)
        #expect(s.batteryPercent == 0)
    }

    /// The IOB half of the fix must not silently relax the dose gate: an unread IOB has always been
    /// STALE for dosing purposes and must remain so. If this ever fails, the display fix has leaked into
    /// the calculator's freshness decision.
    @Test func anUnreadIobStillBlocksOrPromptsOnTheDosePath() {
        let unread = PumpSnapshot()
        #expect(unread.isIobStale(), "nil iobDate ⇒ stale ⇒ CalcInputGate prompts, unchanged")
        var read = PumpSnapshot()
        read.iobDate = Date()
        #expect(!read.isIobStale())
    }

    // MARK: - Helpers

    /// Hand-built inputs, mirroring `ReservoirBatteryUnknownDisplayTests.makeInputs` exactly (same fixed
    /// clock, same bypass of `AppModel`/`MockBackend`'s hardcoded presets) so only `snapshot` varies here.
    private func makeInputs(_ snapshot: PumpSnapshot) -> RemoteStatusInputs {
        RemoteStatusInputs(
            includeHistory: false, requestId: nil, snapshot: snapshot,
            activeNotifications: [], glucoseHistory: [], now: Date(timeIntervalSince1970: 1_700_000_000),
            remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
            supportsRemoteAlertDismiss: false, rawActiveNotifications: nil,
            settings: RemoteStatusSettings(
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
                alertCriticalOverridesDnd: false,
                garminComplicationSlots: ["iob", "reservoir", "battery"]))
    }
}
