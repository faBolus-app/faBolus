import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// P14 S9. The absolute 25 U max-bolus cap is a HARD block enforced at the funnel AND in every backend
/// through the one shared `Interlocks.clampMaxBolusLimit`, so a requested limit above 25 U can never take
/// effect — on ANY backend. Before S9 the `MockBackend` skipped the clamp entirely and only `TandemBackend`
/// enforced it. Distinct from the per-bolus DELIVERY block (`deliverBolus` throws), which is unchanged.
@Suite(.serialized) @MainActor
struct MaxBolusClampTests {

    /// The gap S9 closes: MockBackend used to store the raw value unclamped.
    @Test func mockBackendClampsTheMaxBolusLimit() async throws {
        let mock = MockBackend()
        try await mock.setMaxBolus(units: 30)
        #expect(mock.snapshot.maxBolusUnits == 25.0)
        try await mock.setMaxBolus(units: 8)          // a legitimate value is untouched
        #expect(mock.snapshot.maxBolusUnits == 8.0)
    }

    /// End-to-end through the app funnel: even asking for an absurd limit yields ≤ 25 U at the backend.
    @Test func appFunnelCapsTheLimitEndToEnd() async {
        let s = AppSettings.shared
        let savedAdv = s.advancedControlEnabled
        s.advancedControlEnabled = true               // .setMaxBolus is advanced-gated; Mock is .mobiAdvanced
        defer { s.advancedControlEnabled = savedAdv }
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxbolus-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.setMaxBolus(units: 999)
        #expect(backend.snapshot.maxBolusUnits == 25.0)
    }

    /// The pump-facing proof: the actual `SetMaxBolusLimitRequest` bytes TandemBackend writes are capped to
    /// 25 U (25000 mU) even when 30 U is requested. The fake records the write before the (unscripted)
    /// courtesy response await, so `try?` is safe — we assert on the recorded cargo.
    @Test func tandemBackendClampsTheWrittenLimit() async {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.connected)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        try? await backend.setMaxBolus(units: 30)
        let sent = fake.lastSent(SetMaxBolusLimitRequest.props.opCode)
        #expect(sent != nil, "a max-bolus-limit write must have gone out")
        #expect(sent?.cargo == SetMaxBolusLimitRequest(maxBolusMilliunits: 25000).cargo,
                "the WRITTEN limit must be capped to 25 U (25000 mU) even when 30 U is requested")
    }
}
