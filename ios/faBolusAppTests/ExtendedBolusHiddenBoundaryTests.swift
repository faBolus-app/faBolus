import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// LOCK-04 boundary test (Phase 8, 08-01). Proves `TandemBackend.deliverExtendedBolus(...)` — the
/// extended (combo) bolus delivery path — still delivers exactly the consented units through a fake
/// transport with ZERO UI surface present. Mirrors `StackingGuardDeliverInvariantTests`'
/// `makeDeliveringBackend` harness. `extendedBolusEnabled` is now a force-set-false init pin, which
/// makes `BolusEntryView.extendedBolusSection` auto-hide (it already gated on
/// `settings.extendedBolusEnabled`) — this phase removes no `BolusEntryView` code, only the shared
/// "Bolus screen" Settings toggle. `AppModel.deliverExtendedBolus` / `GatedPumpWrite.deliverExtendedBolus`
/// / `TandemBackend.deliverExtendedBolus` stay byte-identical (D-01/D-03).
@Suite(.serialized) @MainActor
struct ExtendedBolusHiddenBoundaryTests {

    private let bolusId = 9101
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// Same shape as `StackingGuardDeliverInvariantTests.makeDeliveringBackend` — a backend whose
    /// time-sync + permission already succeed, scripted to a matching bolus status so a full-completion
    /// delivery settles.
    private func makeDeliveringBackend(deliveredMilliunits: UInt32) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
        return (backend, fake)
    }

    /// The REAL extended-bolus deliver path through the fake transport still delivers exactly the
    /// consented total — split now/later — with zero UI constructed anywhere in this test.
    @Test func deliverExtendedBolusStillDeliversTheConsentedTotalWithNoUIPresent() async throws {
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3000)
        let delivered = try await backend.deliverExtendedBolus(totalUnits: 3.0, nowUnits: 1.0, durationMinutes: 60,
                                                               carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 3.0)                      // exactly the consented total, not the now/later split
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake                                        // keep the fake alive for the duration of the assertion
    }

    /// `AppSettings.extendedBolusEnabled` is force-set OFF unconditionally at init, regardless of any
    /// pre-existing stored value — the auto-hide gate `BolusEntryView.extendedBolusSection` reads.
    @Test @MainActor func extendedBolusEnabledIsForceSetOffRegardlessOfAnyStoredValue() {
        let suiteName = "ExtendedBolusHiddenBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "extendedBolusEnabled")   // simulate a pre-Phase-8 stored value

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.extendedBolusEnabled == false)
    }
}
