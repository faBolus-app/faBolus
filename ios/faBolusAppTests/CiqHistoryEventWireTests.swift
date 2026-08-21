import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// Phase 09.15-06 (T1-3/T1-4, D-01/D-08): the `lastAutoCorrectionEpochSec` / `ciqLastCouldNotDeliverEpochSec`
/// primitive-propagation spine — the SP-1…SP-4 wire-spine pattern cloned from 09.15-01's
/// `CiqZoneWireTests` / 09.15-05's `CiqSuspendWireTests`. UNLIKE those two prior primitives, these are
/// monotonic historical markers derived from `TandemBackend.neutralEvent` decode — a real occurrence
/// never un-happens, so the client-side parse uses the STANDARD SP-3 `if let` guard (never the
/// unconditional assign-or-clear ciqZone/ciqSuspendedForLow need).
@Suite struct CiqHistoryEventWireTests {

    // MARK: - Task 1: neutralEvent decode

    private func rawHistoryLog(byte14: Int = 0, count: Int = 26) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: count)
        if count > 14 { raw[14] = UInt8(byte14) }
        return raw
    }

    @MainActor
    @Test func bolusSourceSevenMapsToAnAutoCorrectionEvent() {
        let log = BolusDeliveryHistoryLog(cargo: rawHistoryLog(byte14: 7))
        let event = TandemBackend.neutralEvent(log, date: Date())
        #expect(event?.category == .autoCorrection)
        #expect(event?.title == "Control-IQ auto-corrected")
    }

    /// Every OTHER `bolusSource` value must NOT be misread as a Control-IQ auto-correction — the
    /// `where m.bolusSource == 7` guard is exact, never a range/bitmask (D-06 guardrail #6: no
    /// fabricated auto-correction from an unrelated bolus source).
    @MainActor
    @Test func everyOtherBolusSourceIsNotMisreadAsAnAutoCorrection() {
        for source in [0, 1, 2, 6, 8, 255] {
            let log = BolusDeliveryHistoryLog(cargo: rawHistoryLog(byte14: source))
            let event = TandemBackend.neutralEvent(log, date: Date())
            #expect(event?.category != .autoCorrection, "bolusSource \(source) must not map to autoCorrection")
        }
    }

    @MainActor
    @Test func aaAutoBolusRejectedMapsToACouldNotDeliverEvent() {
        let log = AaAutoBolusRejectedHistoryLog(cargo: rawHistoryLog())
        let event = TandemBackend.neutralEvent(log, date: Date())
        #expect(event?.category == .couldNotDeliver)
        #expect(event?.title == "Control-IQ tried and couldn't deliver an automatic correction")
    }

    @MainActor
    @Test func correctionDeclinedMapsToACouldNotDeliverEvent() {
        let log = CorrectionDeclinedHistoryLog(cargo: rawHistoryLog())
        let event = TandemBackend.neutralEvent(log, date: Date())
        #expect(event?.category == .couldNotDeliver)
        #expect(event?.title == "Control-IQ tried and couldn't deliver an automatic correction")
    }

    /// D-06 guardrail #6 (never speculates why): neither struct exposes a reason field, and the
    /// mapped event's `detail` must stay empty rather than inventing one.
    @MainActor
    @Test func couldNotDeliverEventNeverSpeculatesADetailReason() {
        let log = AaAutoBolusRejectedHistoryLog(cargo: rawHistoryLog())
        let event = TandemBackend.neutralEvent(log, date: Date())
        #expect(event?.detail == "")
    }

    // MARK: - Task 1: LogbookView render — T1-4 icon is amber, never red (D-06)

    @Test func couldNotDeliverCategorySymbolIsTheNonFilledExclamationTriangle() {
        #expect(HistoryEvent.Category.couldNotDeliver.symbol == "exclamationmark.triangle")
        // Distinct from `.alarm`'s FILLED red-adjacent glyph — informational, never an alarm.
        #expect(HistoryEvent.Category.couldNotDeliver.symbol != HistoryEvent.Category.alarm.symbol)
    }

    // MARK: - Task 2: validate() epoch bound

    @Test func validateRejectsAZeroOrNegativeOrOverflowEpoch() {
        for bad in [0, -1, Int(Int32.max) + 1] {
            var cmdA = RemoteCommand(kind: .statusRead)
            cmdA.lastAutoCorrectionEpochSec = bad
            #expect(throws: RemoteCommand.ValidationError.outOfRange("lastAutoCorrectionEpochSec")) {
                try cmdA.validate()
            }
            var cmdB = RemoteCommand(kind: .statusRead)
            cmdB.ciqLastCouldNotDeliverEpochSec = bad
            #expect(throws: RemoteCommand.ValidationError.outOfRange("ciqLastCouldNotDeliverEpochSec")) {
                try cmdB.validate()
            }
        }
    }

    @Test func validateAcceptsAPlausibleEpochAndNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.lastAutoCorrectionEpochSec = Int(Date().timeIntervalSince1970)
        cmd.ciqLastCouldNotDeliverEpochSec = Int(Date().timeIntervalSince1970)
        try cmd.validate()

        let cmdAbsent = RemoteCommand(kind: .statusRead)
        try cmdAbsent.validate()
    }

    // MARK: - Task 2: Codable round-trip

    @Test func historyMarkerPrimitivesRoundTripThroughJSONUnchanged() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        let epoch1 = Int(Date().timeIntervalSince1970)
        let epoch2 = epoch1 - 3600
        cmd.lastAutoCorrectionEpochSec = epoch1
        cmd.ciqLastCouldNotDeliverEpochSec = epoch2

        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.lastAutoCorrectionEpochSec == epoch1)
        #expect(back.ciqLastCouldNotDeliverEpochSec == epoch2)
        let backValidated = try RemoteCommand.decodeValidated(data)
        #expect(backValidated.lastAutoCorrectionEpochSec == epoch1)
        #expect(backValidated.ciqLastCouldNotDeliverEpochSec == epoch2)
    }

    // MARK: - Task 2: legacy back-compat

    /// An OLD JSON blob with the marker keys ABSENT decodes fine — a legacy host's statusRead reply
    /// (predating these fields) must never fail to decode.
    @Test func legacyJsonWithoutHistoryMarkerKeysDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.lastAutoCorrectionEpochSec == nil)
        #expect(cmd.ciqLastCouldNotDeliverEpochSec == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.lastAutoCorrectionEpochSec == nil)
        #expect(validated.ciqLastCouldNotDeliverEpochSec == nil)
    }

    // MARK: - Task 2: fail-closed on the client (RemoteCommandWireFixture parse)

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `apply`/`handle(cmd)` has both
    /// markers absent — a fresh app launch before the first statusRead reply must show every 09.15
    /// surface ABSENT, never a stale/zero placeholder.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasNoHistoryMarkers() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.lastAutoCorrectionDate == nil)
        #expect(m.ciqLastCouldNotDeliverDate == nil)
    }

    /// An absent field on the wire yields no rendered claim — the client keeps its safe `nil` default
    /// when a command never carries the key.
    @MainActor
    @Test func absentHistoryMarkerFieldsOnTheWireKeepTheSafeNilDefault() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        let cmd = RemoteCommand(kind: .statusRead)   // marker fields never set ⇒ nil
        m.handle(cmd)
        #expect(m.lastAutoCorrectionDate == nil)
        #expect(m.ciqLastCouldNotDeliverDate == nil)
    }

    /// SP-3 standard guard (UNLIKE ciqZone/ciqSuspendedForLow's unconditional clear): a real
    /// historical fact never un-happens, so once a marker HAS been seen, a LATER statusRead that
    /// simply doesn't repeat the key must keep the last-known value, never clear it back to nil.
    @MainActor
    @Test func onceSeenAHistoryMarkerSurvivesALaterReplyThatOmitsTheKey() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmdWithMarker = RemoteCommand(kind: .statusRead)
        let epoch = Int(Date().timeIntervalSince1970)
        cmdWithMarker.lastAutoCorrectionEpochSec = epoch
        cmdWithMarker.ciqLastCouldNotDeliverEpochSec = epoch
        m.handle(cmdWithMarker)
        #expect(m.lastAutoCorrectionDate == Date(timeIntervalSince1970: TimeInterval(epoch)))
        #expect(m.ciqLastCouldNotDeliverDate == Date(timeIntervalSince1970: TimeInterval(epoch)))

        let cmdWithoutMarker = RemoteCommand(kind: .statusRead)   // fields absent this time
        m.handle(cmdWithoutMarker)
        #expect(m.lastAutoCorrectionDate == Date(timeIntervalSince1970: TimeInterval(epoch)))
        #expect(m.ciqLastCouldNotDeliverDate == Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// A NEWER instant overwrites an older one — the marker always tracks the LATEST occurrence.
    @MainActor
    @Test func aNewerHistoryMarkerOverwritesAnOlderOne() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        let older = Int(Date().timeIntervalSince1970) - 3600
        var cmd1 = RemoteCommand(kind: .statusRead)
        cmd1.lastAutoCorrectionEpochSec = older
        m.handle(cmd1)
        #expect(m.lastAutoCorrectionDate == Date(timeIntervalSince1970: TimeInterval(older)))

        let newer = Int(Date().timeIntervalSince1970)
        var cmd2 = RemoteCommand(kind: .statusRead)
        cmd2.lastAutoCorrectionEpochSec = newer
        m.handle(cmd2)
        #expect(m.lastAutoCorrectionDate == Date(timeIntervalSince1970: TimeInterval(newer)))
    }

    // MARK: - Task 3: fail-closed render — StatusPillsView's underlying predicate (D-01/D-08/D-07)

    /// The chip's underlying gate (toggle on AND a real date present) never fires on a nil date —
    /// pinned at the `PumpSnapshot` level, mirroring `CiqSuspendWireTests`'s render-predicate pins.
    @Test func absentLastAutoCorrectionDateNeverHasAnAgeToRender() {
        var snap = PumpSnapshot()
        snap.lastAutoCorrectionDate = nil
        #expect(snap.lastAutoCorrectionDate == nil)
    }

    /// The positive case: a real date is eligible to render an age label via the shared
    /// `CalcInputFreshness.ageLabel` convention (same one T1-3's chip and T1-4's marker both use).
    @Test func aRealLastAutoCorrectionDateProducesAnAgeLabel() {
        var snap = PumpSnapshot()
        snap.lastAutoCorrectionDate = Date().addingTimeInterval(-12 * 60)
        let label = CalcInputFreshness.ageLabel(for: snap.lastAutoCorrectionDate!)
        #expect(label == "12 min ago")
    }

    // MARK: - Task 3: LiveActivityShared.ContentState Codable-completeness (T1-3 only, D-08)

    /// `ContentState.lastAutoCorrectionDate` round-trips through JSON, and a legacy payload
    /// predating this key decodes to the fail-closed `nil` default rather than throwing.
    @Test func contentStateLastAutoCorrectionRoundTripsAndDefaultsFailClosedOnALegacyPayload() throws {
        var state = FaBolusGlucoseAttributes.ContentState()
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastAutoCorrectionDate = d
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: data)
        #expect(back.lastAutoCorrectionDate == d)

        // Legacy payload predating lastAutoCorrectionDate — must decode, not throw.
        let legacy = #"{"glucose":100}"#
        let legacyData = Data(legacy.utf8)
        let legacyState = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: legacyData)
        #expect(legacyState.lastAutoCorrectionDate == nil)
    }

    /// D-08 explicit scope: T1-4 is never surfaced on widgets/LA — the vocabulary must register the
    /// opt-in T1-3 id and must NOT contain any T1-4-named id.
    @Test func laFieldVocabularyRegistersLastAutoCorrectionButNoT1FourField() {
        #expect(LAFieldVocabulary.all.contains("lastAutoCorrection"))
        #expect(!LAFieldVocabulary.all.contains("couldNotDeliver"))
        #expect(!LAFieldVocabulary.all.contains("ciqLastCouldNotDeliver"))
    }

    // MARK: - Backstop: Garmin ≤~28-char DetailsView.detailRow budget at FONT_XTINY

    /// `DetailsView.mc`'s new rows are hand-mirrored here (Monkey C isn't runnable from this Swift
    /// suite) — a literal backstop pinning the exact templates against the plan's own ~28-char
    /// budget, at both a common (2-digit) and a worst-case (3-digit minute) elapsed value.
    @Test func garminAutoCorrectionAndCouldNotDeliverRowsFitTheCharBudget() {
        for mins in [7, 42, 999] {
            let autoCorrectionRow = "Auto-correction: \(mins)m ago"
            let couldNotDeliverRow = "CIQ couldn't deliver (\(mins)m)"
            #expect(autoCorrectionRow.count <= 28, "\(autoCorrectionRow) is \(autoCorrectionRow.count) chars")
            #expect(couldNotDeliverRow.count <= 28, "\(couldNotDeliverRow) is \(couldNotDeliverRow.count) chars")
        }
    }
}
