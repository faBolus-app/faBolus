import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Decay-to-unknown on the two surfaces that live outside faBolusCore: the App-Group widget carrier
/// (`WidgetSnapshot`, a deliberate mirror — the widget extension does not link faBolusCore) and the
/// remote wire (`RemoteStatusComposer`). The pure model-level contract is pinned in
/// `faBolusCoreTests/PumpValueDecayTests`; this suite pins the mirror, the wire, and the END-TO-END
/// consequence on a remote.
///
/// Every decay assertion here is paired with a matched still-fresh assertion and a matched genuine-zero
/// assertion, because the gate is AGE and must never become a gate on VALUE.
///
/// Debug session `pump-value-decay-to-unknown`.
@Suite struct PumpValueDecayWireAndWidgetTests {

    private static let now = Date(timeIntervalSince1970: 1_000_000)

    /// Minimal in-memory transport so a `RemoteCommandWireFixture` can be built without a real link.
    /// The test drives `handle(_:)` directly (the same entry point `onReceive` calls), so nothing here
    /// is invoked — it only satisfies the initializer. Same helper shape as `CrossSurfaceStalenessTests`.
    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// A widget snapshot with the published policy pinned to a 120 s window, so the boundary is
    /// unambiguous and independent of the global `GlucoseFreshness` default.
    private static func widgetSnap(
        reservoirUnits: Double = 142, reservoirAge: TimeInterval? = 10,
        batteryPercent: Int = 84, batteryAge: TimeInterval? = 10,
        iobUnits: Double = 1.4, iobAge: TimeInterval? = 10,
        staleAfterSec: TimeInterval? = 120, iobStaleAfterSec: TimeInterval? = 300,
        updatedAt: Date = now
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            iobUnits: iobUnits,
            reservoirUnits: reservoirUnits, batteryPercent: batteryPercent,
            reservoirDate: reservoirAge.map { now.addingTimeInterval(-$0) },
            batteryDate: batteryAge.map { now.addingTimeInterval(-$0) },
            updatedAt: updatedAt,
            staleAfterSec: staleAfterSec, hideAfterSec: nil,
            iobStaleAfterSec: iobStaleAfterSec,
            iobDate: iobAge.map { now.addingTimeInterval(-$0) })
    }

    // MARK: - Widget carrier mirror

    @Test func widgetReservoirDecaysPastThePublishedWindow() {
        let s = Self.widgetSnap(reservoirAge: 130)
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == nil)
    }

    @Test func widgetReservoirStillShowsInsideThePublishedWindow() {
        let s = Self.widgetSnap(reservoirAge: 110)
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == 142)
    }

    @Test func widgetGenuineEmptyCartridgeStillReadsZero() {
        let s = Self.widgetSnap(reservoirUnits: 0, reservoirAge: 110)
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == 0)
    }

    @Test func widgetBatteryDecaysPastThePublishedWindow() {
        let s = Self.widgetSnap(batteryAge: 130)
        #expect(s.batteryPercentIfFresh(asOf: Self.now) == nil)
    }

    @Test func widgetBatteryStillShowsInsideThePublishedWindow() {
        let s = Self.widgetSnap(batteryAge: 110)
        #expect(s.batteryPercentIfFresh(asOf: Self.now) == 84)
    }

    @Test func widgetGenuineDeadBatteryStillReadsZero() {
        let s = Self.widgetSnap(batteryPercent: 0, batteryAge: 110)
        #expect(s.batteryPercentIfFresh(asOf: Self.now) == 0)
    }

    @Test func widgetNeverReadStaysUnknown() {
        let s = Self.widgetSnap(reservoirAge: nil, batteryAge: nil)
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == nil)
        #expect(s.batteryPercentIfFresh(asOf: Self.now) == nil)
    }

    @Test func widgetFutureDatedReceiptNeverPresentsAsFresh() {
        let s = Self.widgetSnap(
            reservoirAge: -(WidgetSnapshot.futureSkewTolerance + 60),
            batteryAge: -(WidgetSnapshot.futureSkewTolerance + 60))
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == nil)
        #expect(s.batteryPercentIfFresh(asOf: Self.now) == nil)
    }

    /// The widget's decay window must be the PUBLISHED one, not a second hardcoded default — otherwise a
    /// user who set `glucoseStaleMinutes` to 20 would see the tile decay at 6 while the phone did not.
    @Test func widgetDecayHonorsThePublishedWindowNotAHardcodedDefault() {
        // 200 s old: decayed under the pinned 120 s policy…
        #expect(Self.widgetSnap(reservoirAge: 200).reservoirUnitsIfFresh(asOf: Self.now) == nil)
        // …and still current under a wider published policy, same age.
        let wide = WidgetSnapshot(
            reservoirUnits: 142,
            reservoirDate: Self.now.addingTimeInterval(-200),
            updatedAt: Self.now, staleAfterSec: 20 * 60, hideAfterSec: nil)
        #expect(wide.reservoirUnitsIfFresh(asOf: Self.now) == 142)
    }

    /// **FINDING IN ITS OWN RIGHT — the widget equivalent of the originally reported bug.**
    ///
    /// Before this change the widget's only pump-value freshness gate was `isConnectionStale`, which keys
    /// off `updatedAt` — **publish** time, not **read** time. So an app that is alive and re-publishing
    /// every ~20 s while the pump link is dead kept `connectionStale == false` indefinitely, and the
    /// widget went on presenting the last pump values it ever received as current. `updatedAt` is
    /// re-stamped by every publish regardless of whether any pump read succeeded, so no amount of waiting
    /// would ever have tripped it. That is exactly the fabricated-certainty defect the owner reported on
    /// the phone, reproduced in the widget process by a gate that measures the wrong clock.
    ///
    /// The TTL is not wrong, it just answers a different question ("did the HOST stop publishing"). Both
    /// gates now apply; this test pins the case only the new one can catch.
    @Test func aLivePublishingHostWithADeadPumpLinkStillDecaysTheValue() {
        let liveHostDeadPump = Self.widgetSnap(
            reservoirAge: 130, batteryAge: 130, iobAge: 600, updatedAt: Self.now)
        #expect(
            !liveHostDeadPump.isConnectionStale(asOf: Self.now),
            "the host is publishing, so the publish-time TTL cannot fire — no matter how long the pump stays quiet")
        #expect(liveHostDeadPump.reservoirUnitsIfFresh(asOf: Self.now) == nil, "but the read is old")
        #expect(liveHostDeadPump.batteryPercentIfFresh(asOf: Self.now) == nil)
        #expect(liveHostDeadPump.iobUnitsIfFresh(asOf: Self.now) == nil)

        // And the reverse gap stays closed: a host killed right after a fresh read trips the TTL, and
        // the read receipt ages with it (no publish can re-stamp `updatedAt` without re-reading), so
        // both gates fire together. There is no state where the TTL fires but the value reads current.
        let killedHost = WidgetSnapshot(
            reservoirUnits: 142,
            reservoirDate: Self.now.addingTimeInterval(-(WidgetSnapshot.connectionStaleAfter + 60)),
            updatedAt: Self.now.addingTimeInterval(-(WidgetSnapshot.connectionStaleAfter + 60)),
            staleAfterSec: 120, hideAfterSec: nil)
        #expect(killedHost.isConnectionStale(asOf: Self.now))
        #expect(killedHost.reservoirUnitsIfFresh(asOf: Self.now) == nil)
    }

    // MARK: - Widget timeline crossings

    @Test func decayCrossingsAreScheduledForPresentReceiptsOnly() {
        let s = Self.widgetSnap(reservoirAge: 10, batteryAge: 40, iobAge: 25)
        let crossings = s.pumpValueDecayCrossings(asOf: Self.now)
        #expect(crossings.count == 3)
        #expect(crossings.contains(Self.now.addingTimeInterval(-10 + 120)), "reservoir, glucose window")
        #expect(crossings.contains(Self.now.addingTimeInterval(-40 + 120)), "battery, glucose window")
        #expect(
            crossings.contains(Self.now.addingTimeInterval(-25 + 300)),
            "IOB crossing must use the IOB window (300), not the glucose one (120)")
    }

    @Test func aNeverReadValueHasNoDecayCrossing() {
        // Already unknown — there is nothing to cross into.
        let s = Self.widgetSnap(reservoirAge: nil, batteryAge: nil, iobAge: nil)
        #expect(s.pumpValueDecayCrossings(asOf: Self.now).isEmpty)
    }

    @Test func aFutureDatedReceiptHasNoDecayCrossing() {
        let skew = WidgetSnapshot.futureSkewTolerance + 60
        let s = Self.widgetSnap(reservoirAge: -skew, batteryAge: -skew, iobAge: -skew)
        #expect(s.pumpValueDecayCrossings(asOf: Self.now).isEmpty)
    }

    // MARK: - Widget carrier: active insulin uses its OWN window

    @Test func widgetIobDecaysPastTheIobWindow() {
        #expect(Self.widgetSnap(iobAge: 310).iobUnitsIfFresh(asOf: Self.now) == nil)
    }

    @Test func widgetIobStillShowsInsideTheIobWindow() {
        #expect(Self.widgetSnap(iobAge: 290).iobUnitsIfFresh(asOf: Self.now) == 1.4)
    }

    @Test func widgetGenuineZeroActiveInsulinStillReadsZero() {
        #expect(Self.widgetSnap(iobUnits: 0, iobAge: 290).iobUnitsIfFresh(asOf: Self.now) == 0)
    }

    /// **The anti-drift test.** IOB must age on the published IOB window, never on the glucose window.
    /// This snapshot is 300 s old with a 120 s glucose window and a 600 s IOB window: gating on the wrong
    /// one would report decayed. Reservoir at the same age DOES decay, which is what makes the two
    /// windows observably different rather than coincidentally equal.
    @Test func widgetIobIgnoresTheGlucoseWindowAndUsesTheIobWindow() {
        let s = Self.widgetSnap(
            reservoirAge: 300, iobAge: 300, staleAfterSec: 120, iobStaleAfterSec: 600)
        #expect(s.iobUnitsIfFresh(asOf: Self.now) == 1.4, "300 s < the 600 s IOB window → still current")
        #expect(s.reservoirUnitsIfFresh(asOf: Self.now) == nil, "300 s > the 120 s glucose window → decayed")
    }

    /// A pre-fix payload already on disk carries no IOB window, so the reading's freshness cannot be
    /// established — fail safe to unknown rather than presenting it, exactly as `reservoirDate`'s own
    /// additive-optional decode does. The ~20 s publish heartbeat replaces it almost immediately.
    @Test func aLegacyPayloadWithoutTheIobWindowRendersIobUnknown() {
        let legacy = Self.widgetSnap(iobAge: 10, iobStaleAfterSec: nil)
        #expect(legacy.iobUnitsIfFresh(asOf: Self.now) == nil)
        // …and contributes no crossing, since there is no window to cross.
        #expect(legacy.pumpValueDecayCrossings(asOf: Self.now).count == 2)
        // The glucose-window fields are unaffected by the missing IOB window.
        #expect(legacy.reservoirUnitsIfFresh(asOf: Self.now) == 142)
    }

    @Test func theWidgetCarrierRoundTripsTheIobWindow() throws {
        let s = Self.widgetSnap(iobStaleAfterSec: 300)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded.iobStaleAfterSec == 300)
        #expect(decoded.iobUnitsIfFresh(asOf: Self.now) == 1.4)
    }

    // MARK: - The remote wire

    /// Same hand-built `RemoteStatusSettings` idiom as `RemoteStatusComposerRawSnapshotTests` — bypasses
    /// `AppModel`/`MockBackend`'s capability presets so the fixed clock is the only input that matters.
    private static func settings() -> RemoteStatusSettings {
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
            alertCriticalOverridesDnd: false, garminComplicationSlots: ["iob", "reservoir", "battery"])
    }

    /// `requestId` is pinned by default because `RemoteCommand.init` defaults it to a fresh
    /// `UUID().uuidString`. That is deliberate nondeterminism in production (each statusRead reply needs
    /// its own id) but it would mask the property `composeIsPureAndReadsInputsNowNeverTheWallClock`
    /// actually tests, by making two composes unequal for a reason that has nothing to do with clocks.
    /// Pinning it here lets that test compare the WHOLE struct instead of a hand-picked field list — so it
    /// catches any field that starts reading the clock, not only the ones anticipated when it was written.
    private static func compose(
        reservoirUnits: Double = 142, reservoirAge: TimeInterval = 10,
        batteryPercent: Int = 84, batteryAge: TimeInterval = 10,
        iobUnits: Double = 1.4, iobAge: TimeInterval = 10,
        carbRatio: Double = 12, isf: Int = 45, targetBg: Int = 110, therapyAge: TimeInterval = 10,
        requestId: String? = "fixed-request-id-for-determinism"
    ) -> RemoteCommand {
        var snap = PumpSnapshot()
        snap.connection = .connected
        snap.reservoirUnits = reservoirUnits
        snap.reservoirDate = now.addingTimeInterval(-reservoirAge)
        snap.batteryPercent = batteryPercent
        snap.batteryDate = now.addingTimeInterval(-batteryAge)
        snap.iobUnits = iobUnits
        snap.iobDate = now.addingTimeInterval(-iobAge)
        snap.carbRatio = carbRatio
        snap.isf = isf
        snap.targetBg = targetBg
        snap.therapyParamsDate = now.addingTimeInterval(-therapyAge)
        return RemoteStatusComposer.compose(
            RemoteStatusInputs(
                includeHistory: false, requestId: requestId, snapshot: snap,
                activeNotifications: [], glucoseHistory: [], now: now,
                remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
                supportsRemoteAlertDismiss: false, rawActiveNotifications: nil, settings: settings()))
    }

    /// **The wire is PRESENCE-gated, never FRESHNESS-gated — owner decision.** An aged value still
    /// travels, and its age travels with it. Freshness gating was implemented here and reverted: because
    /// `faBolusGarmin` keeps the last value on an absent key, omitting an aged value cannot decay the
    /// receiver — it only strips information from a number the receiver goes on displaying. See
    /// `omissionIsTheWrongLeverWhichIsWhyTheWireSendsValuePlusAge` below for the mechanism.
    ///
    /// This is deliberately the OPPOSITE of what the phone does for its own screens. The phone decides for
    /// the phone; the wire ships data plus provenance and each receiver decides for itself.
    @Test func anAgedValueStillTravelsOnTheWireTogetherWithItsAge() {
        let day = 24.0 * 3600
        let cmd = Self.compose(reservoirAge: day, batteryAge: day, iobAge: day, therapyAge: day)

        #expect(cmd.reservoirUnits == 142, "an aged reservoir still travels — the receiver decides")
        #expect(cmd.batteryPercent == 84)
        #expect(cmd.units == 1.4, "aged IOB still travels")
        #expect(cmd.carbRatio == 12, "aged therapy still travels")

        // …and every one of them carries the age that makes the value judgeable.
        let expected = Int(Self.now.addingTimeInterval(-day).timeIntervalSince1970)
        #expect(cmd.reservoirEpochSec == expected)
        #expect(cmd.batteryEpochSec == expected)
        #expect(cmd.iobEpochSec == expected)
        #expect(cmd.therapyEpochSec == expected)
    }

    @Test func aFreshValueTravelsWithItsAgeToo() {
        let cmd = Self.compose()
        #expect(cmd.reservoirUnits == 142)
        #expect(cmd.batteryPercent == 84)
        let expected = Int(Self.now.addingTimeInterval(-10).timeIntervalSince1970)
        #expect(cmd.reservoirEpochSec == expected)
        #expect(cmd.batteryEpochSec == expected)
    }

    /// A NEVER-READ value is still absent, and so is its stamp. Presence gating is the one gate the wire
    /// does apply, and this is the case it exists for (debug `tslim-reservoir-battery-zero`): a remote
    /// cannot tell a real 0 from a fabricated one, so absence must mean absence.
    @Test func aNeverReadValueIsAbsentOnTheWireAndSoIsItsStamp() {
        var snap = PumpSnapshot()
        snap.connection = .connected
        let cmd = RemoteStatusComposer.compose(
            RemoteStatusInputs(
                includeHistory: false, requestId: "fixed", snapshot: snap,
                activeNotifications: [], glucoseHistory: [], now: Self.now,
                remoteMax: 25, canBolus: true, bolusBlockReason: nil, bolusPasscodeRequired: false,
                supportsRemoteAlertDismiss: false, rawActiveNotifications: nil, settings: Self.settings()))
        #expect(cmd.reservoirUnits == nil)
        #expect(cmd.batteryPercent == nil)
        #expect(cmd.reservoirEpochSec == nil, "no read ⇒ no stamp; a stamp would imply a value")
        #expect(cmd.batteryEpochSec == nil)
    }

    /// An age stamp must never be sent WITHOUT its value, or a receiver could compute a freshness for
    /// something it does not have. The two travel as a pair in both directions.
    @Test func aStampNeverTravelsWithoutItsValueNorAValueWithoutItsStamp() {
        for cmd in [Self.compose(), Self.compose(reservoirAge: 24 * 3600)] {
            #expect((cmd.reservoirUnits == nil) == (cmd.reservoirEpochSec == nil))
            #expect((cmd.batteryPercent == nil) == (cmd.batteryEpochSec == nil))
        }
    }

    @Test func aGenuineZeroTravelsOnTheWireAsZeroNotAbsent() {
        let cmd = Self.compose(reservoirUnits: 0, batteryPercent: 0, iobUnits: 0)
        #expect(cmd.reservoirUnits == 0, "an empty cartridge must reach the remote as 0, never as absent")
        #expect(cmd.batteryPercent == 0)
        #expect(cmd.units == 0, "0 U of active insulin is a real reading — the remote must receive it as 0")
    }

    /// The asymmetry, on the wire: `0` is a real reservoir/battery/IOB reading and must travel, but a
    /// therapy `0` is physically impossible and has always meant unread — so it stays absent even when
    /// the read is fresh. Both conventions survive.
    @Test func aZeroTherapyValueStaysAbsentOnTheWireEvenWhenFresh() {
        let cmd = Self.compose(carbRatio: 0, isf: 0, targetBg: 0, therapyAge: 10)
        #expect(cmd.carbRatio == nil)
        #expect(cmd.isf == nil)
        #expect(cmd.targetBg == nil)
    }

    /// The new stamps must satisfy `RemoteCommand.validate()` — same `Int32.max` ceiling as every other
    /// epoch, because `Int` is 32-bit on watchOS and Monkey C's `Lang.Number` is signed 32-bit.
    @Test func theNewAgeStampsValidateAndRoundTrip() throws {
        let cmd = Self.compose()
        try cmd.validate()
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(cmd))
        #expect(decoded.reservoirEpochSec == cmd.reservoirEpochSec)
        #expect(decoded.batteryEpochSec == cmd.batteryEpochSec)

        var bad = cmd
        bad.reservoirEpochSec = Int(Int32.max) + 1
        #expect(throws: (any Error).self) { try bad.validate() }
        var zero = cmd
        zero.batteryEpochSec = 0  // reads as "absent" to a receiver, so it must be refused at the source
        #expect(throws: (any Error).self) { try zero.validate() }
    }

    /// `compose` must stay pure — it reads `inputs.now`, never `Date()`. Age gating was the easiest way to
    /// break that; the gating is gone now but the stamps still touch the clock's data, so the guard stays.
    /// Compares the WHOLE struct (see the `compose` helper's note on the pinned `requestId`) so it catches
    /// any field that starts reading the wall clock, not just the ones anticipated here.
    @Test func composeIsPureAndReadsInputsNowNeverTheWallClock() {
        #expect(Self.compose() == Self.compose())
        #expect(Self.compose(reservoirAge: 24 * 3600) == Self.compose(reservoirAge: 24 * 3600))
        // Two composes of DIFFERENT ages must differ, or the equality above would be vacuous.
        #expect(Self.compose(reservoirAge: 10) != Self.compose(reservoirAge: 20))
    }

    /// **THE FINDING THAT DECIDED THE WIRE DESIGN — keep this test even though its original premise is
    /// gone.** It no longer asserts that the host omits an aged value (it does not, any more); it asserts
    /// the MECHANISM that made omission the wrong lever, which is the reasoning that must survive.
    ///
    /// `faBolusGarmin`'s statusRead handler is uniformly `var rv = fltRange(data["reservoirUnits"], …);
    /// if (rv != null) { reservoir = rv; }` — keep-last on an absent key, and necessarily so, because
    /// absent also means "legacy host" and "partial reply". `RemoteCommandWireFixture` mirrors that
    /// handler, so this test states what any remote actually does.
    ///
    /// The consequence: had the host gated the wire on freshness, the watch would have gone on displaying
    /// the same stale number — now with no value update AND no age to judge it by. Omission removes
    /// information without decaying anything. That is why the owner chose value-plus-age instead
    /// (`anAgedValueStillTravelsOnTheWireTogetherWithItsAge`), and why reintroducing wire gating would be a
    /// regression rather than a tightening.
    ///
    /// If this test ever fails because the fixture began CLEARING on absence, do not fix the test: that is
    /// a behaviour change on the remote, and it would blank real values on every legacy or partial reply.
    @MainActor @Test func omissionIsTheWrongLeverWhichIsWhyTheWireSendsValuePlusAge() {
        let watch = RemoteCommandWireFixture(link: FakeLink())

        // A fresh reading arrives and the remote adopts it.
        watch.handle(Self.compose(reservoirUnits: 142, batteryPercent: 84))
        #expect(watch.reservoirUnits == 142)
        #expect(watch.batteryPercent == 84)

        // Now simulate what wire-side freshness gating WOULD have sent: the same reply with both values
        // omitted. Built by hand — the host deliberately no longer produces this.
        var gated = Self.compose()
        gated.reservoirUnits = nil
        gated.batteryPercent = nil
        gated.reservoirEpochSec = nil
        gated.batteryEpochSec = nil
        watch.handle(gated)

        #expect(
            watch.reservoirUnits == 142,
            "keep-last on absent: the remote STILL shows the old number — omission decays nothing")
        #expect(watch.batteryPercent == 84)

        // And what the host actually sends instead: the value it has, plus the age that makes it
        // judgeable. Same displayed number, but now the receiver has what it needs to decide for itself.
        let day = 24.0 * 3600
        let actual = Self.compose(reservoirAge: day, batteryAge: day)
        watch.handle(actual)
        #expect(watch.reservoirUnits == 142)
        #expect(
            actual.reservoirEpochSec != nil && actual.batteryEpochSec != nil,
            "the age is what the gated variant threw away — this is the whole difference")
    }
}

/// Walk up from this file to the repo root, so a source scan does not depend on the CWD a test host runs in.
private func repoRoot() -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
}

/// **Carrier integrity for `WidgetSnapshot` — three parts that must agree, one of which no compiler checks.**
///
/// `WidgetSnapshot` hand-writes `init(from:)` (so every field, not just the `Optional`-typed ones, falls
/// back to its `init` default on a missing key) while letting `encode(to:)` be SYNTHESIZED. That split is
/// deliberate and correct, but it creates three distinct ways to half-add a field, and they fail very
/// differently:
///
///  1. `CodingKeys` case with NO stored property → kills the SYNTHESIZED encoder
///     ("type 'WidgetSnapshot' does not conform to protocol 'Encodable'"). Loud, but a BUILD failure, so
///     no test can catch it — and notably a decoder-only test would not either, because the hand-written
///     decoder still compiles fine on its own. This one was shipped once, in the change that added
///     `iobStaleAfterSec` (debug `pump-value-decay-to-unknown`): the doc comment landed, the declaration
///     did not, and the `CodingKeys` case and decode line both referenced it.
///  2. Stored property with NO `CodingKeys` case → silently never persisted.
///  3. Stored property never decoded in `init(from:)` → **silently resets to its `init` default on every
///     decode.** No compile error, no crash, no test failure unless something asserts the round trip. This
///     is the genuinely invisible one, and the reason this guard scans rather than just round-trips a
///     sample: a round-trip test only covers the fields it happens to set.
///
/// Kept as a source scan because (1) is not observable at runtime at all, and (3) is only observable for
/// fields a test remembers to populate. Same idiom as `WidgetCoreDelegationGuardTests`.
@Suite struct WidgetSnapshotCarrierIntegrityGuardTests {

    private static let carrier = "Shared/WidgetShared.swift"

    /// Nested types (`WidgetSnapshot.Point`) get their OWN synthesized `Codable`; their properties are not
    /// part of the outer struct's key set, so they must not be counted.
    private static func excisingNestedTypes(_ text: String) -> String {
        var out: [String] = []
        var depth = 0
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count
            if !skipping, line.contains("public struct "), !line.contains("WidgetSnapshot") {
                skipping = true
                depth = opens - closes
                continue
            }
            if skipping {
                depth += opens - closes
                if depth <= 0 { skipping = false }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func identifier(after prefix: String, in line: String) -> String? {
        guard let r = line.range(of: prefix) else { return nil }
        let rest = line[r.upperBound...].drop { $0 == " " }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !name.isEmpty, rest.dropFirst(name.count).first == ":" else { return nil }
        return String(name)
    }

    @Test func everyStoredPropertyHasACodingKeyAndADecodeLineAndViceVersa() throws {
        let src = try String(contentsOf: repoRoot().appendingPathComponent(Self.carrier), encoding: .utf8)
        guard let structStart = src.range(of: "public struct WidgetSnapshot"),
            let structEnd = src.range(of: "\n}\n", range: structStart.upperBound..<src.endIndex)
        else {
            Issue.record("could not locate the WidgetSnapshot struct in \(Self.carrier) — did it move?")
            return
        }
        let own = Self.excisingNestedTypes(String(src[structStart.lowerBound..<structEnd.lowerBound]))
        let lines = own.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Stored properties only: a computed property has a `{` on its declaration line.
        var stored: Set<String> = []
        for line in lines where !line.contains("{") {
            if let name = Self.identifier(after: "public var ", in: line) { stored.insert(name) }
        }

        // CodingKeys cases.
        guard let keysStart = own.range(of: "private enum CodingKeys"),
            let keysBodyStart = own.range(of: "CodingKey {", range: keysStart.lowerBound..<own.endIndex),
            let keysEnd = own.range(of: "}", range: keysBodyStart.upperBound..<own.endIndex)
        else {
            Issue.record("could not locate the CodingKeys enum — did it move?")
            return
        }
        let keys = Set(
            own[keysBodyStart.upperBound..<keysEnd.lowerBound]
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
                .filter { $0 != "case" })

        // Decode lines in the hand-written `init(from:)`.
        var decoded: Set<String> = []
        for line in lines where line.contains("= try c.decode") {
            let name = line.drop { $0 == " " }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { decoded.insert(String(name)) }
        }

        #expect(stored.count > 25, "parse looks wrong — found only \(stored.count) stored properties")

        // (1) The failure mode that kills the synthesized encoder — a build error no test can reach,
        //     which is exactly why it is asserted here at the source level instead.
        #expect(
            keys.subtracting(stored).isEmpty,
            "CodingKeys case(s) with no stored property — this breaks the SYNTHESIZED encoder: \(keys.subtracting(stored).sorted())"
        )
        // (2) Silently never persisted.
        #expect(
            stored.subtracting(keys).isEmpty,
            "stored propert(ies) with no CodingKeys case — never persisted: \(stored.subtracting(keys).sorted())")
        // (3) The invisible one: silently resets to its init default on every decode.
        #expect(
            stored.subtracting(decoded).isEmpty,
            "stored propert(ies) never decoded in init(from:) — silently reset to the init default on every decode: \(stored.subtracting(decoded).sorted())"
        )
    }
}

/// **FINDING IN ITS OWN RIGHT — a decay that never re-renders is not a decay.**
///
/// Age-gated values need a periodic tick to reach the screen. `StatusPillsView` already had one
/// (`TimelineView(.periodic(by: 20))`, added for the CGM age label); `PumpDetailsCard` and the Debug
/// menu's live-snapshot rows had NO time input at all, so they re-rendered only when the snapshot VALUE
/// changed — which is precisely what stops happening when a read goes quiet. Without the ticks added for
/// debug `pump-value-decay-to-unknown` the feature would have silently half-worked: correct on one
/// surface, invisible on two, and with no failing test anywhere to say so.
///
/// A source scan is the proof here because these are SwiftUI view bodies: the app test target cannot
/// render them, and the property under test is structural ("this surface has a clock"), not behavioural.
/// Same idiom as `WidgetCoreDelegationGuardTests` and `GlucoseStatusGlyphGuardTests`.
@Suite struct DecayingSurfacesHaveAClockGuardTests {

    /// Repo-root-relative paths of every in-app surface that renders an age-gated pump value.
    private static let surfaces = [
        "ios/faBolus/Views/StatusPillsView.swift",
        "ios/faBolus/Views/MainHUDView.swift",
        "ios/faBolus/Views/DebugMenuView.swift"
    ]

    @Test func everySurfaceRenderingAnAgeGatedPumpValueHasAPeriodicClock() throws {
        let root = repoRoot()
        var scanned = 0
        var missing: [String] = []
        for rel in Self.surfaces {
            guard let src = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            else { continue }
            scanned += 1
            // The age-gated funnels are the marker for "this file decays something".
            guard src.contains("IfFresh(now:") else { continue }
            if !src.contains("TimelineView(.periodic") {
                missing.append(
                    "\(rel) calls an …IfFresh(now:) funnel but has no TimelineView(.periodic …) to re-render it")
            }
        }
        #expect(
            scanned == Self.surfaces.count,
            "source scan found only \(scanned) of \(Self.surfaces.count) surfaces — paths moved?")
        #expect(missing.isEmpty, "\(missing)")
    }

    /// The complement: a surface must not pass wall-clock `Date()` into an age gate. In a `TimelineView`
    /// the whole point is to gate on `ctx.date`; in a widget, on the entry date. `Date()` would defeat
    /// both — and in a widget it is prep time, not display time.
    @Test func noSurfacePassesWallClockIntoAnAgeGate() throws {
        let root = repoRoot()
        let all =
            Self.surfaces + [
                "ios/faBolusWidgets/StatusWidget.swift",
                "ios/faBolusWidgets/GlucoseWidget.swift"
            ]
        var violations: [String] = []
        for rel in all {
            guard let src = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            else { continue }
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("IfFresh(") && line.contains("Date()") {
                violations.append("\(rel):\(i + 1) passes wall-clock Date() into an age gate")
            }
        }
        #expect(violations.isEmpty, "\(violations)")
    }
}
