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
@Suite struct BatteryChargingCarrierTests {

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
}
