import Testing
import Foundation
import faBolusCore
import TandemBLE
@testable import faBolus

/// Pins that an identity-not-established control refusal surfaces a distinct actionable message and never
/// auto-retries. A generic fallback would hide that the kit blocked the write because trusted identity is missing.
@Suite(.serialized) @MainActor
struct AppModelControlErrorMappingTests {

    @MainActor
    private final class IdentityGateThrowingBackend: PumpBackend {
        private let mock = MockBackend()

        var capabilities: PumpCapabilities { mock.capabilities }
        var snapshot: PumpSnapshot { mock.snapshot }
        var glucoseHistory: [GlucoseReading] { mock.glucoseHistory }
        var iobHistory: [IOBSample] { mock.iobHistory }
        var bolusMarkers: [BolusMarker] { mock.bolusMarkers }
        var activeNotifications: [PumpAlert] { mock.activeNotifications }
        var alertDebug: String { mock.alertDebug }
        func dismissNotification(_ alert: PumpAlert) async { await mock.dismissNotification(alert) }
        var pairingCode: String {
            get { mock.pairingCode }
            set { mock.pairingCode = newValue }
        }
        var hasStoredPairing: Bool { mock.hasStoredPairing }
        func forgetPairing() { mock.forgetPairing() }
        func connect() async { await mock.connect() }
        func disconnect() { mock.disconnect() }
        func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
            await mock.recommendBolus(carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        }
        func deliverBolus(units: Double, carbsGrams: Double?, bgMgdl: Int?, iobUnits: Double?) async throws -> Double {
            try await mock.deliverBolus(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl, iobUnits: iobUnits)
        }
        func cancelBolus() async { await mock.cancelBolus() }
        var lastBolusCancelled: Bool { mock.lastBolusCancelled }
        var onChange: (@MainActor () -> Void)? {
            get { mock.onChange }
            set { mock.onChange = newValue }
        }
        var commitBolusId: (@MainActor (Int) async -> Bool)? {
            get { mock.commitBolusId }
            set { mock.commitBolusId = newValue }
        }

        /// The seam under test: throws the EXACT error the kit's trusted-identity send gate raises for
        /// the tracer opcode (0xCE, `SetSleepScheduleRequest`) — the identical error type
        /// `TandemBackend.sendControl` propagates when `PumpBLEClient.send` refuses pre-write.
        private(set) var suspendDeliveryInvocationCount = 0
        func suspendDelivery() async throws {
            suspendDeliveryInvocationCount += 1
            throw PumpBLEClient.ClientError.identityNotEstablished(opcode: 0xCE)
        }
    }

    /// Mirrors `AppModelBehaviorTests.withCleanSettings`: `suspendDelivery` routes through the
    /// `controlInterlock` gate, which requires the backend's capability set to include
    /// `supportsAnyAdvancedControl` (the wrapped `MockBackend()` defaults to a Mobi, `.mobiAdvanced` —
    /// satisfying this) — plus `phoneReadOnly == false`, `childModeEnabled == false`, and
    /// `appMode == .advanced` (the funnel's mode-gate default floor).
    private func withCleanSettings(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let ro = s.phoneReadOnly, child = s.childModeEnabled
        let mode = s.appMode
        s.phoneReadOnly = false
        s.childModeEnabled = false
        s.appMode = .advanced
        defer {
            s.phoneReadOnly = ro
            s.childModeEnabled = child
            s.appMode = mode
        }
        await body()
    }

    @Test func identityNotEstablishedMapsToAnActionableMessage() async {
        await withCleanSettings {
            let backend = IdentityGateThrowingBackend()
            let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
            let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)

            await model.suspendDelivery()

            #expect(
                model.lastError == "Pump identity is still being confirmed — try again shortly.",
                "the identity-gate refusal must map to the distinct actionable message, not the generic fallback")
        }
    }

    @Test func identityNotEstablishedDoesNotTriggerAnAutomaticRetry() async {
        await withCleanSettings {
            let backend = IdentityGateThrowingBackend()
            let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("appmodel-ledger-\(UUID().uuidString).json")
            let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)

            await model.suspendDelivery()

            #expect(
                backend.suspendDeliveryInvocationCount == 1,
                "performControl must invoke the throwing op exactly once — no automatic retry")
        }
    }
}
