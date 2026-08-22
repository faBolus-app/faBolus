import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 9 (mobi-all-advanced-t-slim-control-last-highest-risk), Plan 01 (MOBI-01/MOBI-03, D-02/D-03/
/// D-10): the app-target boundary test that pins the reject-at-pairing safety gate's contract — a Mobi
/// is torn down before pairing completes, and the kept t:slim path still pairs + delivers. Mirrors
/// `CgmShareOnlyBoundaryTests.swift`/`GarminVenu3sOnlyBoundaryTests.swift`'s MockBackend-driven,
/// construction-time exercise style (no live BLE, no simulator).
///
/// `MockBackend(isMobi:)` seeds `snapshot.isMobi`/`snapshot.pumpModelName` at construction time
/// (`MockBackend.swift:96-97`) and `AppModel.init` copies `source.snapshot` straight into
/// `self.snapshot` (`AppModel.swift:876`) — so `AppModel(source: MockBackend(isMobi: true))` reproduces
/// exactly the moment the protected `TandemBackend` discovery callback synchronously sets
/// `snapshot.pumpModel == .mobi`, BEFORE any pairing negotiation. Per RESEARCH Pitfall 3, the test below
/// asserts the OUTCOME the observe-and-abort produces (disconnected, no saved pairing secret, no
/// pairing-completion-gated state reached) — it deliberately does NOT assert `isMobi` never becomes
/// true, since the code legitimately flips it true for this "momentary link" window (owner-accepted).
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

        // Sanity: the momentary-true fact the discovery callback produces (RESEARCH Pitfall 3) — NOT
        // itself the assertion under test.
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

    /// Companion positive-path (D-10): main still pairs + delivers a bolus on a t:slim-identified
    /// `MockBackend` — the reject gate must not regress the kept t:slim path.
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
