import Testing
import Foundation
import TandemMessages
import faBolusCore
import faBolusDesign
@testable import faBolus

/// Regression net for debug session `tslim-reservoir-battery-zero`, ROOT CAUSE 2 — INDEPENDENT of the
/// exclusion-learning defect and a defect in its own right.
///
/// `PumpSnapshot.reservoirUnits: Double = 0` and `batteryPercent: Int = 0` were non-optional with a
/// ZERO default and no record of whether the op-37 / op-145 reply had ever arrived. So a read that was
/// never answered rendered as `0 U` and `0%` — clinically meaningful values (empty cartridge, dead
/// battery) fabricated out of absence. The battery surface was worse than the text: 0 selected the
/// `battery.0` EMPTY glyph and `usesLowTint: percent <= 20` painted a low-battery warning.
///
/// The contract these tests pin is two-sided, and the second side is the safety-critical one:
///   - absent  -> unknown, on every surface, never a number;
///   - GENUINE zero -> still exactly `0 U` / `0%`, because an empty cartridge and a dead battery are
///     real states the user must see.
///
/// ORACLE TYPE: `specified` — the required distinction is stated directly in the session's guardrails
/// ("your fix must make absent DISTINGUISHABLE from zero — not replace one wrong answer with another").
@Suite @MainActor
struct ReservoirBatteryUnknownDisplayTests {

    // MARK: - The snapshot must record whether the read ever landed

    @Test func aFreshSnapshotHasNoReservoirOrBatteryReadReceipt() {
        let s = PumpSnapshot()
        #expect(s.reservoirDate == nil, "a never-read reservoir must be marked unknown, not 0 U")
        #expect(s.batteryDate == nil, "a never-read battery must be marked unknown, not 0%")
    }

    @Test func anInsulinStatusReplyStampsTheReservoirReadReceipt() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.reservoirDate == nil)
        b.injectStatusFrameForTesting(FakePumpTransport.insulinStatus(unitsRemaining: 142))
        #expect(b.snapshot.reservoirUnits == 142)
        #expect(b.snapshot.reservoirDate != nil, "op-37 must stamp the read receipt so display can trust the value")
    }

    @Test func aCurrentBatteryReplyStampsTheBatteryReadReceipt() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.batteryDate == nil)
        b.injectStatusFrameForTesting(FakePumpTransport.currentBatteryV2(percent: 78))
        #expect(b.snapshot.batteryPercent == 78)
        #expect(b.snapshot.batteryDate != nil, "op-145 must stamp the read receipt so display can trust the value")
    }

    /// The load-bearing case. A GENUINE empty cartridge / dead battery still stamps the receipt, so it
    /// keeps displaying a real 0 — absence and zero are now distinguishable in BOTH directions.
    @Test func aGenuineZeroReadIsStampedAndStaysDisplayableAsZero() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(FakePumpTransport.insulinStatus(unitsRemaining: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBatteryV2(percent: 0))
        #expect(b.snapshot.reservoirUnits == 0)
        #expect(b.snapshot.batteryPercent == 0)
        #expect(b.snapshot.reservoirDate != nil, "an empty cartridge is a CONFIRMED reading, not an absent one")
        #expect(b.snapshot.batteryDate != nil, "a dead battery is a CONFIRMED reading, not an absent one")
        #expect(ReservoirPresentation.make(units: b.snapshot.reservoirUnitsIfRead).valueText == "0 U")
        #expect(
            BatteryChargingPresentation.make(percent: b.snapshot.batteryPercentIfRead, charging: false).valueText
                == "0%")
    }

    // MARK: - The pure presentation helpers

    @Test func anUnreadReservoirRendersUnknownNotZero() {
        let unknown = ReservoirPresentation.make(units: nil)
        #expect(unknown.valueText == ReservoirPresentation.unknownText)
        #expect(unknown.valueText != "0 U", "absence must never render as an empty cartridge")
        #expect(!unknown.isKnown)
    }

    @Test func aReadReservoirRendersItsValue() {
        #expect(ReservoirPresentation.make(units: 142).valueText == "142 U")
        #expect(ReservoirPresentation.make(units: 0).valueText == "0 U")
        #expect(ReservoirPresentation.make(units: 1).valueText == "1 U")
        #expect(ReservoirPresentation.make(units: 142).isKnown)
    }

    @Test func anUnreadBatteryRendersUnknownWithNoFalseLowWarningAndNoEmptyGlyph() {
        let unknown = BatteryChargingPresentation.make(percent: nil, charging: false)
        #expect(unknown.valueText == ReservoirPresentation.unknownText)
        #expect(unknown.valueText != "0%", "absence must never render as a dead battery")
        #expect(!unknown.usesLowTint, "an unknown battery must not paint a low-battery warning")
        #expect(!unknown.showsChargingText)
        #expect(
            unknown.symbolName != "battery.0",
            "the empty-battery glyph asserts a dead battery — an unknown battery must not use it")
    }

    /// Boundary neighbours around the low-tint threshold, so the optional overload can't quietly change
    /// the KNOWN-value behaviour the non-optional one already guarantees.
    @Test func theOptionalOverloadMatchesTheKnownValueOverloadExactly() {
        for percent in [0, 1, 5, 6, 19, 20, 21, 37, 38, 62, 63, 87, 88, 99, 100] {
            for charging in [true, false] {
                let known = BatteryChargingPresentation.make(percent: percent, charging: charging)
                let optionalPercent: Int? = percent
                let viaOptional = BatteryChargingPresentation.make(percent: optionalPercent, charging: charging)
                #expect(known == viaOptional, "percent \(percent) charging \(charging) must be unchanged")
            }
        }
    }

    // MARK: - Every surface honours the receipt

    @Test func theWidgetSnapshotCarriesTheReadReceipts() {
        let s = WidgetSnapshot()
        #expect(s.reservoirDate == nil, "a widget payload with no reservoir read must render unknown")
        #expect(s.batteryDate == nil, "a widget payload with no battery read must render unknown")
    }

    @Test func aWidgetSnapshotRoundTripsTheReadReceipts() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var s = WidgetSnapshot(reservoirUnits: 0, batteryPercent: 0)
        s.reservoirDate = when
        s.batteryDate = when
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded.reservoirDate == when)
        #expect(decoded.batteryDate == when)
    }

    /// A LEGACY payload written before this fix has no receipt keys, so it must decode to unknown —
    /// fail-safe. Showing `—` for one publish cycle is correct; showing a fabricated `0 U` is not.
    @Test func aLegacyWidgetPayloadWithoutReceiptsDecodesAsUnknown() throws {
        let legacy = #"{"reservoirUnits":142,"batteryPercent":80,"trendArrow":"→"}"#
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.reservoirDate == nil)
        #expect(decoded.batteryDate == nil)
    }

    /// The remote/Garmin wire already types these as `Double?`. An unread value must travel as ABSENT,
    /// never as a fabricated 0 — the watch cannot tell a real 0 from a filled-in one.
    @Test func theRemoteWireOmitsAnUnreadReservoirAndBattery() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.reservoirDate == nil)
        let unread = RemoteStatusComposer.compose(makeInputs(b.snapshot))
        #expect(unread.reservoirUnits == nil, "an unread reservoir must be ABSENT on the wire, never 0")
        #expect(unread.batteryPercent == nil, "an unread battery must be ABSENT on the wire, never 0")

        b.injectStatusFrameForTesting(FakePumpTransport.insulinStatus(unitsRemaining: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.currentBatteryV2(percent: 0))
        let readZero = RemoteStatusComposer.compose(makeInputs(b.snapshot))
        #expect(readZero.reservoirUnits == 0, "a CONFIRMED empty cartridge must still be sent as 0")
        #expect(readZero.batteryPercent == 0, "a CONFIRMED dead battery must still be sent as 0")
    }

    // MARK: - GUARDRAIL: the dose path must be byte-identical

    /// `StackingGuard.insufficientReservoir` is a dose-path pre-guard that reads the NON-optional
    /// `reservoirUnits` and uses a NEGATIVE sentinel for "no valid reading". This fix adds a receipt
    /// ALONGSIDE that field and does not touch it, so the guard's behaviour must be unchanged — in
    /// particular the unread case (`0`) must keep DISCLOSING, never fall silent. A `.none` here would be
    /// a fail-OPEN regression.
    @Test func theStackingGuardPreGuardIsUnchangedByTheReceiptAddition() {
        #expect(StackingGuard.insufficientReservoir(enteredUnits: 5, reservoirUnits: 3) != .none)
        #expect(StackingGuard.insufficientReservoir(enteredUnits: 3, reservoirUnits: 3) == .none)
        #expect(StackingGuard.insufficientReservoir(enteredUnits: 1, reservoirUnits: 0) != .none)
        #expect(StackingGuard.insufficientReservoir(enteredUnits: 1, reservoirUnits: -1) == .none)
    }

    /// The receipt must not be reachable as a dose input: adding it may not change what the calculator
    /// or the bolus gate see. Pinned by construction — `reservoirUnits`/`batteryPercent` keep their
    /// types and defaults.
    @Test func theSnapshotsDosePathFieldsKeepTheirTypesAndDefaults() {
        let s = PumpSnapshot()
        #expect(s.reservoirUnits == 0, "the frozen non-optional dose-path field keeps its 0 default")
        #expect(s.batteryPercent == 0, "the frozen non-optional dose-path field keeps its 0 default")
    }

    // MARK: - Helpers

    /// Hand-built inputs, mirroring `RemoteStatusComposerRawSnapshotTests` exactly (same fixed clock,
    /// same bypass of `AppModel`/`MockBackend`'s hardcoded presets) so only `snapshot` varies here.
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
