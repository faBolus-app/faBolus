import XCTest
@testable import faBolusCore

/// The phone↔remote contract must round-trip losslessly (JSON Data and [String:Any]) so the Apple
/// Watch, Garmin, and host all agree. If a field is added to RemoteCommand, add it here too.
final class RemoteCommandTests: XCTestCase {

    func testVersionMatchesSchema() {
        XCTAssertEqual(RemoteCommand(kind: .statusRead).version, RemoteCommand.schemaVersion)
    }

    /// S8: the pure new-alert diff a remote uses to actively surface a newly-arrived alert.
    func testNewAlertIdentitiesDetectsFreshAndReplacement() {
        let a = RemoteCommand.RemoteAlert(id: 27, kind: 3, title: "Failed connection")
        let b = RemoteCommand.RemoteAlert(id: 2, kind: 2, title: "Occlusion")
        // First arrival (nothing previous) → new.
        XCTAssertEqual(RemoteCommand.newAlertIdentities(previous: [], current: [a]), ["3-27"])
        // Already seen → nothing new.
        XCTAssertTrue(RemoteCommand.newAlertIdentities(previous: ["3-27"], current: [a]).isEmpty)
        // Equal-count REPLACEMENT (a clears, b arrives — same size) → b registers as new.
        XCTAssertEqual(RemoteCommand.newAlertIdentities(previous: ["3-27"], current: [b]), ["2-2"])
        // Identity is (kind, id): same id + different kind is distinct.
        XCTAssertEqual(RemoteCommand.RemoteAlert(id: 2, kind: 1, title: "x").identity, "1-2")
    }

    func testStatusReadRoundTripData() throws {
        let cmd = RemoteCommand(kind: .statusRead, units: 1.25,
                                bgMgdl: 142, message: "Connected", trend: "up45",
                                carbRatio: 10, isf: 40, targetBg: 110, maxBolusUnits: 25,
                                reservoirUnits: 142, batteryPercent: 80, lastBolusUnits: 2.0,
                                glucoseAgeSec: 120, history: [110, 120, 130],
                                alerts: [.init(id: 2, kind: 3, title: "High glucose")],
                                bolusMode: "carbs", bolusIncrement: 0.05, carbIncrement: 5,
                                screenOrder: ["glance", "alerts"], defaultScreen: "glance")
        var withMode = cmd
        withMode.activeMode = "simple"   // P14 S4: pin the active-mode field on the wire
        let decoded = try RemoteCommand.decode(try withMode.encoded())
        XCTAssertEqual(decoded, withMode)
        XCTAssertEqual(decoded.activeMode, "simple")
        XCTAssertEqual(decoded.history, [110, 120, 130])
        XCTAssertEqual(decoded.alerts?.first?.kind, 3)
        XCTAssertEqual(decoded.trend, "up45")
    }

    /// B2 (S1+O3): the controller-identity fields round-trip on the wire (JSON + dictionary), and the
    /// variant token is the FROZEN rawValue.
    func testControllerVariantRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controllerVariant = ControllerVariant.controlIQPro.rawValue
        cmd.controlIQEnabled = true
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.controllerVariant, "controlIQPro")
        XCTAssertEqual(decoded.controlIQEnabled, true)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.controllerVariant, "controlIQPro")
        XCTAssertEqual(back.controlIQEnabled, true)
        // Absent ⇒ nil (legacy host); a remote maps nil → .none / false (no disclosure).
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(bare.controllerVariant)
        XCTAssertNil(bare.controlIQEnabled)
    }

    func testDictionaryRoundTrip() throws {
        // Transport for WatchConnectivity + Connect IQ is [String:Any].
        let cmd = RemoteCommand(kind: .bolusRequest, carbsGrams: 30, bgMgdl: 150)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back, cmd)
        XCTAssertEqual(back.kind, .bolusRequest)
        XCTAssertEqual(back.carbsGrams, 30)
    }

    func testBolusStatusEcho() throws {
        let cmd = RemoteCommand(kind: .bolusStatus, requestId: "abc",
                                status: .cancelled, deliveredUnits: 0.8, message: "Cancelled · 0.80 U")
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.status, .cancelled)
        XCTAssertEqual(decoded.deliveredUnits, 0.8)
        XCTAssertEqual(decoded.requestId, "abc")
    }

    func testDismissAlertCommand() throws {
        let cmd = RemoteCommand(kind: .dismissAlert, alertId: 2, alertKind: 3)
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.alertId, 2)
        XCTAssertEqual(decoded.alertKind, 3)
    }

    /// Phase 4 (mmol/L display-unit support, D-04/Pattern 2): the additive-optional
    /// `glucoseDisplayUnit` wire token round-trips (JSON + dictionary), and its absence on a legacy
    /// payload decodes to `nil` (⇒ consumers default to mgdl) WITHOUT touching `schemaVersion`.
    func testGlucoseDisplayUnitRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.glucoseDisplayUnit = GlucoseUnit.mmol.wireToken
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.glucoseDisplayUnit, "mmol")
        XCTAssertEqual(decoded.version, RemoteCommand.schemaVersion)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.glucoseDisplayUnit, "mmol")

        // Absent on a legacy/bare payload ⇒ nil (default mgdl), schemaVersion still 1.
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(bare.glucoseDisplayUnit)
        XCTAssertEqual(bare.version, RemoteCommand.schemaVersion)
    }

    // MARK: - Phase 09.13-02 (glucose plot height customization, D-06/D-07) — plot bound wire fields

    /// D-06: all four additive-optional plot-bound Int fields round-trip (JSON + dictionary); an
    /// encode without setting them omits all four keys, and decoding that bare payload yields nil for
    /// all four (legacy-safe), WITHOUT touching `schemaVersion`.
    func testGlucosePlotBoundsRoundTripAndOmitWhenAbsent() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.glucosePlotFloor = 40
        cmd.glucosePlotCeiling = 300
        cmd.glucosePlotFloorSmall = 50
        cmd.glucosePlotCeilingSmall = 400
        let encoded = try cmd.encoded()
        let decoded = try RemoteCommand.decode(encoded)
        XCTAssertEqual(decoded.glucosePlotFloor, 40)
        XCTAssertEqual(decoded.glucosePlotCeiling, 300)
        XCTAssertEqual(decoded.glucosePlotFloorSmall, 50)
        XCTAssertEqual(decoded.glucosePlotCeilingSmall, 400)
        XCTAssertEqual(decoded.version, RemoteCommand.schemaVersion)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.glucosePlotFloor, 40)
        XCTAssertEqual(back.glucosePlotCeilingSmall, 400)

        // Not set ⇒ omitted from the wire entirely (byte-compatible with a pre-09.13 peer).
        let bareEncoded = try RemoteCommand(kind: .statusRead).encoded()
        let bareJSON = String(data: bareEncoded, encoding: .utf8) ?? ""
        for key in ["glucosePlotFloor", "glucosePlotCeiling", "glucosePlotFloorSmall", "glucosePlotCeilingSmall"] {
            XCTAssertFalse(bareJSON.contains(key), "\(key) must be omitted from the wire when unset")
        }
        let bare = try RemoteCommand.decode(bareEncoded)
        XCTAssertNil(bare.glucosePlotFloor)
        XCTAssertNil(bare.glucosePlotCeiling)
        XCTAssertNil(bare.glucosePlotFloorSmall)
        XCTAssertNil(bare.glucosePlotCeilingSmall)
        XCTAssertEqual(bare.version, RemoteCommand.schemaVersion)
    }

    // MARK: - Phase 09.9-04 (D-05): cartridge-ready DISPLAY signal

    /// The additive-optional `cartridgeReady` field round-trips (JSON + dictionary) both when true and
    /// when explicitly false, and never touches `schemaVersion` — mirrors `canBolus` exactly.
    func testCartridgeReadyRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.cartridgeReady = true
        var decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.cartridgeReady, true)
        XCTAssertEqual(decoded.version, RemoteCommand.schemaVersion)
        var back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.cartridgeReady, true)

        // An explicit false (cartridge mid change/load/prime) round-trips too — never dropped/coerced.
        cmd.cartridgeReady = false
        decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.cartridgeReady, false)
        back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.cartridgeReady, false)
    }

    /// A legacy/bare payload without the `cartridgeReady` key decodes to `nil` — NO SIGNAL, never a
    /// fabricated "not ready" that could mislead a remote into showing a false block.
    func testCartridgeReadyAbsentOnLegacyPayloadDecodesToNil() throws {
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(bare.cartridgeReady)
        XCTAssertEqual(bare.version, RemoteCommand.schemaVersion)
    }

    // MARK: - Phase 09.27-03 (D-04/D-05): batteryCharging remote-wire propagation

    /// The additive-optional `batteryCharging` field round-trips (JSON + dictionary) when true, and
    /// never touches `schemaVersion` — mirrors `cartridgeReady` exactly.
    func testBatteryChargingRoundTrips() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.batteryCharging = true
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.batteryCharging, true)
        XCTAssertEqual(decoded.version, RemoteCommand.schemaVersion)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.batteryCharging, true)
    }

    /// A legacy/bare payload without the `batteryCharging` key decodes to `nil` — a remote must map
    /// this to NOT charging (fail-closed), never a fabricated charging state (D-05).
    func testBatteryChargingAbsentOnLegacyPayloadDecodesToNil() throws {
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(bare.batteryCharging)
        XCTAssertEqual(bare.version, RemoteCommand.schemaVersion)
    }

    // MARK: - CX-G-08 (14-09): dismissAck kind + supportsDismissAck capability

    /// The new `dismissAck` kind round-trips (JSON + dictionary) carrying the reused
    /// requestId/alertId/alertKind fields, and is neither pump-mutating nor freshness-sensitive
    /// (checkpoint #1: it is an observational phone→watch ack, never a pump write).
    func testDismissAckRoundTripsAndIsNeitherMutatingNorFreshnessSensitive() throws {
        var cmd = RemoteCommand(kind: .dismissAck, requestId: "req-1")
        cmd.alertId = 3
        cmd.alertKind = 1
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.kind, .dismissAck)
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.alertId, 3)
        XCTAssertEqual(decoded.alertKind, 1)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.kind, .dismissAck)
        XCTAssertEqual(back.alertId, 3)
        XCTAssertFalse(RemoteCommand.Kind.dismissAck.mutatesPumpState,
                        "an ack is observational, never a pump write")
        XCTAssertFalse(RemoteCommand.Kind.dismissAck.isFreshnessSensitive,
                        "a dismiss ack is insulin-neutral, never freshness-gated")
    }

    /// A well-formed dismissAck (alertId + alertKind present) passes `validate()` — the cross-field
    /// rejection (missing alertId/alertKind) is pinned separately in RemoteCommandValidationTests.
    func testWellFormedDismissAckPassesValidate() throws {
        var cmd = RemoteCommand(kind: .dismissAck, requestId: "req-2")
        cmd.alertId = 5
        cmd.alertKind = 2
        XCTAssertNoThrow(try cmd.validate())
    }

    /// `supportsDismissAck` round-trips (JSON + dictionary) and, absent on a legacy payload, decodes to
    /// nil — the watch's safe default is the 14-08 fallback, never a fabricated "ack-mode" claim.
    func testSupportsDismissAckRoundTripsAndAbsentDecodesToNil() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.supportsDismissAck = true
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.supportsDismissAck, true)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.supportsDismissAck, true)
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .statusRead).encoded())
        XCTAssertNil(bare.supportsDismissAck)
    }
}
