import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that a Mobi identity is torn down before pairing completes (disconnected, no saved secret), and
/// that a t:slim still pairs and delivers. `isMobi` may be true for that momentary window; the pin is the abort outcome, not that the flag never flips.
@Suite(.serialized) @MainActor
struct MobiRejectAtPairingBoundaryTests {
    private func makeModel(isMobi: Bool) -> AppModel {
        let backend = MockBackend(isMobi: isMobi)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobi-reject-\(UUID().uuidString).json")
        return AppModel(source: backend, ledgerStoreURL: url)
    }

    /// Clean gate state (no child lock / read-only) so the positive-path delivery below exercises only
    /// the seam under test — mirrors `GarminVenu3sOnlyBoundaryTests.withClean`.
    private func withClean(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, phoneRO = s.phoneReadOnly
        s.childModeEnabled = false; s.phoneReadOnly = false
        await body()
        s.childModeEnabled = child; s.phoneReadOnly = phoneRO
    }

    @Test func mobiNamedPeripheralIsRejectedBeforePairingCompletes() {
        let model = makeModel(isMobi: true)

        // Sanity: the momentary-true fact the discovery callback produces — not itself the assertion under test.
        #expect(model.snapshot.pumpModel == .mobi)

        model.rejectMobiIfDetected()

        // The OUTCOME: torn down, not a pending/connected/bolusing state a UI could act on.
        #expect(model.snapshot.connection == .disconnected)
        // No pairing-completion-gated code ever ran (`evaluateSavePinOffer()` only fires on
        // `.connected`/`.bolusing`), so no save-PIN offer / new PairingStore secret exists.
        #expect(model.savePinPrompt == nil)
        #expect(model.savedPin == nil)
        // The DRAFT reject message is surfaced through the existing `lastError` display path.
        #expect(model.lastError == MobiRejectCopy.mobiNotSupported)

        // Idempotent: a second observer firing again (e.g. a second `.onChange` trigger site) is a
        // harmless no-op, not a second distinct teardown with different side effects.
        model.rejectMobiIfDetected()
        #expect(model.snapshot.connection == .disconnected)
    }

    /// Companion positive path: the reject gate must not regress the kept t:slim path.
    @Test func tslimStillPairsAndDelivers() async {
        await withClean {
            let model = makeModel(isMobi: false)

            // The reject helper is a no-op for a non-Mobi identity — safe to call unconditionally from
            // every observer trigger without affecting the t:slim path.
            model.rejectMobiIfDetected()
            #expect(model.snapshot.connection == .disconnected)

            await model.connect()
            #expect(model.snapshot.connection == .connected)

            await model.deliverBolus(units: 1.0)
            #expect(model.lastError == nil)
        }
    }
}
