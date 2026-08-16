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

    // MARK: - Phase 09.6-07 (D-03.1, D-04): watch-diagnostics-over-WC `.diagnosticsRead`

    /// `.diagnosticsRead` must be provably delivery-inert: never a pump-mutating command, never
    /// freshness-gated (it carries no dose input, so late arrival is harmless).
    func testDiagnosticsReadIsDeliveryInert() {
        XCTAssertFalse(RemoteCommand.Kind.diagnosticsRead.mutatesPumpState)
        XCTAssertFalse(RemoteCommand.Kind.diagnosticsRead.isFreshnessSensitive)
    }

    /// A `.diagnosticsRead` REPLY (diagnosticsText set) round-trips losslessly over both wire shapes
    /// (JSON Data and the [String:Any] dictionary WatchConnectivity/Garmin actually transport), and
    /// `schemaVersion` stays unchanged — Swift-only additive field, exactly like `eatingProb`.
    func testDiagnosticsReadRoundTrips() throws {
        var cmd = RemoteCommand(kind: .diagnosticsRead)
        cmd.diagnosticsText = "Phone reachable: yes\nDirect-CGM failover: idle"
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.diagnosticsText, cmd.diagnosticsText)
        XCTAssertEqual(decoded.version, RemoteCommand.schemaVersion)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back.diagnosticsText, cmd.diagnosticsText)
    }

    /// A bare `.diagnosticsRead` REQUEST (the phone's ask) carries no `diagnosticsText` — decoding a
    /// legacy/bare payload must yield `nil`, never a crash or a fabricated empty string.
    func testDiagnosticsReadBareRequestDecodesWithNilText() throws {
        let bare = try RemoteCommand.decode(try RemoteCommand(kind: .diagnosticsRead).encoded())
        XCTAssertNil(bare.diagnosticsText)
        XCTAssertEqual(bare.version, RemoteCommand.schemaVersion)
    }

    /// `diagnosticsText` is subject to the SAME length cap every other string field uses — an
    /// oversized value must fail `validate()` on the untrusted decode path, not silently truncate or
    /// pass through.
    func testDiagnosticsReadOversizedTextFailsValidation() {
        var cmd = RemoteCommand(kind: .diagnosticsRead)
        cmd.diagnosticsText = String(repeating: "x", count: RemoteCommand.maxStringLength + 1)
        XCTAssertThrowsError(try cmd.validate()) { error in
            XCTAssertEqual(error as? RemoteCommand.ValidationError, .oversizedString("diagnosticsText"))
        }
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
}
