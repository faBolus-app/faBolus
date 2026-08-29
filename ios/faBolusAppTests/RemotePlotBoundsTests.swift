import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The shared `RemoteCommandWireFixture` glucose-plot Y-axis bound channel split.
/// `glucosePlotFloor`/`glucosePlotCeiling` are the SHARED/phone-scoped bounds — this is the channel the
/// Mac reads. `smallScreenFloor`/`smallScreenCeiling` are the Watch/Garmin-facing resolved bounds: the
/// optional override when present, else the shared bounds. CRITICAL: the small-screen override must
/// NEVER leak into the shared getters, and neither channel may be routed through `watchChartRanges`/
/// `chartRanges` (the pre-existing time-range mirror the Mac already inherits).
@MainActor
@Suite(.serialized) struct RemotePlotBoundsTests {

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    @Test func freshModelDefaultsToTheSharedBaseline() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.glucosePlotFloor == GlucosePlotScale.defaultFloor)
        #expect(m.glucosePlotCeiling == GlucosePlotScale.defaultCeiling)
        #expect(m.smallScreenFloor == GlucosePlotScale.defaultFloor)
        #expect(m.smallScreenCeiling == GlucosePlotScale.defaultCeiling)
    }

    /// With no override on the wire, `smallScreenFloor`/`smallScreenCeiling` == the shared bounds.
    @Test func overrideAbsentSmallScreenEqualsShared() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.glucosePlotFloor = 50
        cmd.glucosePlotCeiling = 400
        m.handle(cmd)
        #expect(m.glucosePlotFloor == 50)
        #expect(m.glucosePlotCeiling == 400)
        #expect(m.smallScreenFloor == 50)
        #expect(m.smallScreenCeiling == 400)
    }

    /// The load-bearing test: with an override present, `smallScreen*` == the override AND the
    /// shared getters STILL == the phone values — the Mac (which reads `glucosePlotFloor`/
    /// `glucosePlotCeiling` directly) never receives the override.
    @Test func overridePresentSmallScreenUsesOverrideSharedStaysPhoneScoped() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.glucosePlotFloor = 40
        cmd.glucosePlotCeiling = 300
        cmd.glucosePlotFloorSmall = 50
        cmd.glucosePlotCeilingSmall = 400
        m.handle(cmd)
        // The Mac-facing channel: untouched by the override.
        #expect(m.glucosePlotFloor == 40)
        #expect(m.glucosePlotCeiling == 300)
        // The Watch/Garmin-facing channel: the override.
        #expect(m.smallScreenFloor == 50)
        #expect(m.smallScreenCeiling == 400)
    }

    /// Absent shared fields ⇒ the model keeps its safe default (never nil, never zero).
    @Test func legacyHostOmittingSharedBoundsKeepsSafeDefault() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = "Connected"
        cmd.bgMgdl = 120
        m.handle(cmd)
        #expect(m.glucosePlotFloor == GlucosePlotScale.defaultFloor)
        #expect(m.glucosePlotCeiling == GlucosePlotScale.defaultCeiling)
        #expect(m.smallScreenFloor == GlucosePlotScale.defaultFloor)
        #expect(m.smallScreenCeiling == GlucosePlotScale.defaultCeiling)
    }

    /// Turning the override OFF on a later push (both small fields become absent) reverts
    /// `smallScreen*` back to the shared bounds — a stale override never lingers.
    @Test func overrideClearedOnALaterPushRevertsToShared() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var withOverride = RemoteCommand(kind: .statusRead)
        withOverride.glucosePlotFloor = 40
        withOverride.glucosePlotCeiling = 300
        withOverride.glucosePlotFloorSmall = 50
        withOverride.glucosePlotCeilingSmall = 400
        m.handle(withOverride)
        #expect(m.smallScreenFloor == 50)

        var cleared = RemoteCommand(kind: .statusRead)
        cleared.glucosePlotFloor = 40
        cleared.glucosePlotCeiling = 300
        // glucosePlotFloorSmall/CeilingSmall left nil ⇒ "Same as phone" again.
        m.handle(cleared)
        #expect(m.glucosePlotFloorSmall == nil)
        #expect(m.glucosePlotCeilingSmall == nil)
        #expect(m.smallScreenFloor == 40)
        #expect(m.smallScreenCeiling == 300)
    }

    /// A hostile/out-of-set pair still resolves in-set via `GlucosePlotScale.resolve` (mirrors
    /// `AppSettings`'s own snap-at-init guarantee) rather than surfacing an invalid axis.
    @Test func outOfSetOverridePairSnapsInSet() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.glucosePlotFloor = 40
        cmd.glucosePlotCeiling = 300
        cmd.glucosePlotFloorSmall = 45  // not an actual option
        cmd.glucosePlotCeilingSmall = 320  // not an actual option
        m.handle(cmd)
        #expect(GlucosePlotScale.floorOptions.contains(m.smallScreenFloor))
        #expect(GlucosePlotScale.ceilingOptions.contains(m.smallScreenCeiling))
        #expect(m.smallScreenFloor < m.smallScreenCeiling)
    }

    /// Neither channel is ever routed through `watchChartRanges`/`chartRanges` — a push carrying
    /// ONLY `watchChartRanges` (the pre-existing time-range mirror) must not perturb the Y-axis bounds.
    @Test func watchChartRangesNeverPerturbsThePlotBoundChannels() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.watchChartRanges = [3, 6, 12, 24]
        m.handle(cmd)
        #expect(m.chartRanges == [3, 6, 12, 24])  // the time-range mirror DID update
        #expect(m.glucosePlotFloor == GlucosePlotScale.defaultFloor)  // …but the Y-axis bounds did not
        #expect(m.glucosePlotCeiling == GlucosePlotScale.defaultCeiling)
        #expect(m.smallScreenFloor == GlucosePlotScale.defaultFloor)
        #expect(m.smallScreenCeiling == GlucosePlotScale.defaultCeiling)
    }
}
