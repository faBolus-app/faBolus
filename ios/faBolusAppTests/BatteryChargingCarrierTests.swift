import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.27-02 (D-04/D-05): the Codable absent->false drift-guard for `batteryCharging` on BOTH
/// App-Group carriers — `FaBolusGlucoseAttributes.ContentState` (Live Activity) and `WidgetSnapshot`
/// (widgets/complications). Mirrors `CiqSuspendWireTests
/// .contentStateSuspendFieldsRoundTripAndDefaultFailClosedOnALegacyPayload`'s round-trip + legacy-
/// payload pattern exactly. A legacy/older snapshot that predates this field must decode to
/// `batteryCharging == false` — never a fabricated charging badge on an old payload (D-05).
/// `.serialized`: the two `publishSnapshot()` tests added for the Watch-render gap closure write to
/// the SAME real App-Group `WidgetStore` key other tests could theoretically share — mirrors
/// `WidgetStalenessTests`/`ModeAutomationPrecedenceTests`'s `.serialized` precedent for any suite
/// that touches `WidgetStore` directly.
@Suite(.serialized) struct BatteryChargingCarrierTests {

    // MARK: - ContentState (Live Activity)

    @Test func contentStateBatteryChargingRoundTripsTrue() throws {
        var state = FaBolusGlucoseAttributes.ContentState()
        state.batteryCharging = true
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: data)
        #expect(back.batteryCharging == true)
    }

    @Test func contentStateLegacyPayloadMissingBatteryChargingDecodesToFalse() throws {
        // Legacy payload predating batteryCharging — must decode, not throw, and never fabricate
        // a charging badge for an in-flight Live Activity started under an older build.
        let legacy = #"{"glucose":100}"#
        let legacyData = Data(legacy.utf8)
        let legacyState = try JSONDecoder().decode(FaBolusGlucoseAttributes.ContentState.self, from: legacyData)
        #expect(legacyState.batteryCharging == false)
    }

    @Test func contentStateMemberwiseInitDefaultsBatteryChargingFalse() {
        let state = FaBolusGlucoseAttributes.ContentState()
        #expect(state.batteryCharging == false)
    }

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

    // MARK: - RemoteClientModel.publishSnapshot() forwarding (Watch-render gap closure)

    /// Minimal in-memory transport so a `RemoteClientModel` can be exercised without a real link —
    /// mirrors `CrossSurfaceStalenessTests.FakeLink` / `ControllerDisclosureWireTests.FakeLink`.
    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// 09.27-VERIFICATION.md Truth #11 gap closure: the BASE `RemoteClientModel.publishSnapshot()`
    /// (which the Watch relies on — it does not override `publishSnapshot`, unlike `MacRemoteModel`)
    /// must forward the ingested `batteryCharging` into the `WidgetSnapshot` it writes to the App
    /// Group, not silently drop it back to the `false` default.
    @MainActor
    @Test func remoteClientModelPublishSnapshotForwardsBatteryChargingIntoWidgetSnapshot() {
        let model = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 42
        cmd.batteryCharging = true
        model.handle(cmd)
        #expect(model.batteryCharging == true)   // sanity: ingest side already verified by WR-01 tests

        model.publishSnapshot()
        let snap = WidgetStore.load()
        #expect(snap?.batteryPercent == 42)
        #expect(snap?.batteryCharging == true, "the Watch's WidgetSnapshot must carry the real charging state, not the false default")
    }

    /// The fail-closed counterpart: a legacy/absent wire key must publish `batteryCharging == false`,
    /// never a stale `true` (mirrors the WR-01 fail-closed fix on the ingest side).
    @MainActor
    @Test func remoteClientModelPublishSnapshotPublishesFalseWhenNeverToldCharging() {
        let model = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 17
        model.handle(cmd)   // batteryCharging absent on the wire

        model.publishSnapshot()
        let snap = WidgetStore.load()
        #expect(snap?.batteryCharging == false)
    }

    // MARK: - WR-01: RemoteClientModel.handle ingest is fail-closed, never keep-last, on an absent key

    /// The regression this review fix targets: previously `if let c = cmd.batteryCharging {
    /// batteryCharging = c }` kept the LAST-KNOWN value when a later `statusRead` omitted the key —
    /// so a true->absent transition left a STALE "Charging" claim on iPhone-remote/Mac. It must now
    /// reset to `false`, mirroring `faBolusGarmin/source/app/AppState.mc`'s unconditional re-evaluate.
    @MainActor
    @Test func absentBatteryChargingKeyResetsAPreviouslyTrueValueToFalse() {
        let model = RemoteClientModel(link: FakeLink())
        var chargingCmd = RemoteCommand(kind: .statusRead)
        chargingCmd.batteryCharging = true
        model.handle(chargingCmd)
        #expect(model.batteryCharging == true)

        var droppedKeyCmd = RemoteCommand(kind: .statusRead)   // batteryCharging left nil (dropped/legacy)
        droppedKeyCmd.batteryPercent = 55
        model.handle(droppedKeyCmd)
        #expect(model.batteryCharging == false, "an absent key must NOT keep the last-known 'Charging' claim (WR-01 fail-closed fix)")
    }

    /// A fresh model that never received the field stays fail-closed `false` (D-03's default,
    /// unaffected by this fix — kept as an explicit regression pin).
    @MainActor
    @Test func absentBatteryChargingKeyOnAFreshModelStaysFalse() {
        let model = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryPercent = 90
        model.handle(cmd)
        #expect(model.batteryCharging == false)
    }

    /// An explicit `false` on the wire must still read as not-charging (not just "absent -> false").
    @MainActor
    @Test func explicitFalseBatteryChargingKeyReadsAsNotCharging() {
        let model = RemoteClientModel(link: FakeLink())
        var chargingCmd = RemoteCommand(kind: .statusRead)
        chargingCmd.batteryCharging = true
        model.handle(chargingCmd)

        var offCmd = RemoteCommand(kind: .statusRead)
        offCmd.batteryCharging = false
        model.handle(offCmd)
        #expect(model.batteryCharging == false)
    }
}
