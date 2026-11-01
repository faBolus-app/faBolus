import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// A legacy WidgetSnapshot missing batteryCharging must decode to false — never a fabricated charging
/// badge on an old payload.
@Suite(.serialized) struct BatteryChargingCarrierTests {

    // MARK: - WidgetSnapshot (widgets/complications)

    @Test func widgetSnapshotBatteryChargingRoundTripsTrue() throws {
        var snap = WidgetSnapshot(glucose: 120)
        snap.batteryCharging = true
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(back.batteryCharging == true)
    }

    @Test func widgetSnapshotLegacyPayloadMissingBatteryChargingDecodesToFalse() throws {
        // Legacy payload predating batteryCharging — must decode, not throw, and never fabricate a
        // charging badge for an older widget-extension binary reading a newer app's snapshot... or
        // vice versa (an old snapshot the current extension reads).
        let legacy = #"{"glucose":124}"#
        let legacyData = Data(legacy.utf8)
        let legacySnap = try JSONDecoder().decode(WidgetSnapshot.self, from: legacyData)
        #expect(legacySnap.batteryCharging == false)
    }

    @Test func widgetSnapshotMemberwiseInitDefaultsBatteryChargingFalse() {
        let snap = WidgetSnapshot(glucose: 120)
        #expect(snap.batteryCharging == false)
    }

    // MARK: - RemoteCommandWireFixture.publishSnapshot() forwarding (Watch-render gap closure)

    /// The BASE `RemoteCommandWireFixture.publishSnapshot()` must forward ingested `batteryCharging`
    /// into the WidgetSnapshot it writes, not silently drop it back to the false default.
    @MainActor
    @Test func remoteClientModelPublishSnapshotForwardsBatteryChargingIntoWidgetSnapshot() {
        let model = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 42
        cmd.batteryCharging = true
        model.handle(cmd)
        #expect(model.batteryCharging == true)  // sanity: ingest side already verified

        model.publishSnapshot()
        let snap = WidgetStore.load()
        #expect(snap?.batteryPercent == 42)
        #expect(
            snap?.batteryCharging == true,
            "the Watch's WidgetSnapshot must carry the real charging state, not the false default")
    }

    /// The fail-closed counterpart: a legacy/absent wire key must publish `batteryCharging == false`,
    /// never a stale `true`.
    @MainActor
    @Test func remoteClientModelPublishSnapshotPublishesFalseWhenNeverToldCharging() {
        let model = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 17
        model.handle(cmd)  // batteryCharging absent on the wire

        model.publishSnapshot()
        let snap = WidgetStore.load()
        #expect(snap?.batteryCharging == false)
    }

    // MARK: - RemoteCommandWireFixture.handle ingest is fail-closed, never keep-last, on an absent key

    /// The regression this review fix targets: previously `if let c = cmd.batteryCharging {
    /// batteryCharging = c }` kept the LAST-KNOWN value when a later `statusRead` omitted the key —
    /// so a true->absent transition left a STALE "Charging" claim on iPhone-remote/Mac. It must now
    /// reset to `false`, mirroring `faBolusGarmin/source/app/AppState.mc`'s unconditional re-evaluate.
    @MainActor
    @Test func absentBatteryChargingKeyResetsAPreviouslyTrueValueToFalse() {
        let model = RemoteCommandWireFixture(link: FakeLink())
        var chargingCmd = RemoteCommand(kind: .statusRead)
        chargingCmd.batteryCharging = true
        model.handle(chargingCmd)
        #expect(model.batteryCharging == true)

        var droppedKeyCmd = RemoteCommand(kind: .statusRead)  // batteryCharging left nil (dropped/legacy)
        droppedKeyCmd.batteryPercent = 55
        model.handle(droppedKeyCmd)
        #expect(
            model.batteryCharging == false,
            "an absent key must NOT keep the last-known 'Charging' claim (fail-closed fix)")
    }

    /// A fresh model that never received the field stays fail-closed `false`.
    @MainActor
    @Test func absentBatteryChargingKeyOnAFreshModelStaysFalse() {
        let model = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 90
        model.handle(cmd)
        #expect(model.batteryCharging == false)
    }

    /// An explicit `false` on the wire must still read as not-charging (not just "absent -> false").
    @MainActor
    @Test func explicitFalseBatteryChargingKeyReadsAsNotCharging() {
        let model = RemoteCommandWireFixture(link: FakeLink())
        var chargingCmd = RemoteCommand(kind: .statusRead)
        chargingCmd.batteryCharging = true
        model.handle(chargingCmd)

        var offCmd = RemoteCommand(kind: .statusRead)
        offCmd.batteryCharging = false
        model.handle(offCmd)
        #expect(model.batteryCharging == false)
    }
}
