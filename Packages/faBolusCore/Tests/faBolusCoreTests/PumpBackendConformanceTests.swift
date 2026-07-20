import XCTest
@testable import faBolusCore

/// A minimal `PumpBackend` conformance harness. It proves the protocol is implementable with no
/// pump-specific dependencies (the whole point of the seam) and doubles as a **template**: a new
/// backend can start from this shape. Contributors: keep this green and add cases exercising your
/// backend's capabilities.
@MainActor
final class PumpBackendConformanceTests: XCTestCase {

    /// A tiny in-memory backend used to validate the contract.
    final class StubBackend: PumpBackend {
        let capabilities: PumpCapabilities
        var snapshot = PumpSnapshot()
        var glucoseHistory: [GlucoseReading] = []
        var iobHistory: [IOBSample] = []
        var bolusMarkers: [BolusMarker] = []
        var activeNotifications: [PumpAlert] = [PumpAlert(id: 1, kind: .alert, title: "Low insulin")]
        var alertDebug = "stub"
        var pairingCode = ""
        var hasStoredPairing = false
        private(set) var lastBolusCancelled = false
        var onChange: (@MainActor () -> Void)?

        init(capabilities: PumpCapabilities = .full) { self.capabilities = capabilities }
        func dismissNotification(_ alert: PumpAlert) async {
            activeNotifications.removeAll { $0.id == alert.id && $0.kind == alert.kind }
        }
        func forgetPairing() {}
        func connect() async { snapshot.connection = .connected }
        func disconnect() { snapshot.connection = .disconnected }
        func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
            var r = BolusRecommendation(); r.carbsGrams = carbsGrams; r.recommendedUnits = carbsGrams / 10; return r
        }
        func deliverBolus(units: Double) async throws -> Double {
            guard snapshot.connection == .connected else { throw BolusError.notConnected }
            guard units <= snapshot.maxBolusUnits else { throw BolusError.exceedsMax(snapshot.maxBolusUnits) }
            return units
        }
        func cancelBolus() async {}
    }

    func testLifecycleAndDelivery() async throws {
        let b = StubBackend()
        await b.connect()
        XCTAssertEqual(b.snapshot.connection, .connected)
        let delivered = try await b.deliverBolus(units: 1.5)
        XCTAssertEqual(delivered, 1.5)
        let rec = await b.recommendBolus(carbsGrams: 30, bgMgdl: 150)
        XCTAssertEqual(rec.recommendedUnits, 3.0, accuracy: 0.0001)
    }

    func testDeliverGuards() async {
        let b = StubBackend()   // not connected
        await XCTAssertThrowsErrorAsync(try await b.deliverBolus(units: 1.0))
    }

    func testDismissRemovesAlert() async {
        let b = StubBackend()
        XCTAssertEqual(b.activeNotifications.count, 1)
        await b.dismissNotification(b.activeNotifications[0])
        XCTAssertTrue(b.activeNotifications.isEmpty)
    }

    /// A backend can be wrapped in a BackendDescriptor + built via its factory.
    func testBackendDescriptorFactory() {
        let d = BackendDescriptor(id: "stub", name: "Stub") { StubBackend() }
        XCTAssertEqual(d.id, "stub")
        _ = d.make()   // builds without throwing
    }
}

/// Small async throwing assertion helper (XCTAssertThrowsError has no async overload).
@MainActor
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                 _ message: String = "expected an error",
                                 file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail(message, file: file, line: line) } catch { /* expected */ }
}
