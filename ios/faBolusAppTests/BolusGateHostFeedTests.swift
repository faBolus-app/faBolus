import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P12 (group D) — the phone host feeds `BolusGate` from its own `PumpSnapshot` + `AccessPolicy`. Pins
/// that `AppModel.bolusGate` maps the live snapshot correctly (the pure gate logic is covered by
/// `BolusGateTests`; this covers the host wiring the phone `BolusEntryView` now depends on).
@Suite(.serialized) @MainActor
struct BolusGateHostFeedTests {
    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bg-\(UUID().uuidString).json")
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }
    /// Clean gate state so a sibling test can't leave child/read-only set; advanced-control on (the Mobi
    /// MockBackend needs it for the funnel's capability gate, matching the shipped UI).
    private func withClean(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.phoneReadOnly, adv = s.advancedControlEnabled, rro = s.remotesReadOnly
        s.childModeEnabled = false; s.phoneReadOnly = false; s.advancedControlEnabled = true; s.remotesReadOnly = false
        await body()
        s.childModeEnabled = child; s.phoneReadOnly = ro; s.advancedControlEnabled = adv; s.remotesReadOnly = rro
    }

    @Test func connectedInBoundsAllows() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let g = model.bolusGate(amount: 2.0, minimum: 0.05)
            #expect(g.canBolus)
            #expect(g.reason == nil)
        }
    }

    @Test func neverConnectedReportsPumpNotLinked() async {
        await withClean {
            let (model, _) = makeModel()   // stays .disconnected — no pump link
            let g = model.bolusGate(amount: 2.0, minimum: 0.05)
            #expect(!g.canBolus)
            #expect(g.reason == .pumpNotLinked)
        }
    }

    @Test func overMaxReportsAboveMax() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let g = model.bolusGate(amount: 999, minimum: 0.05)   // MockBackend max is 25 U
            #expect(!g.canBolus)
            #expect(g.reason == .aboveMax(backend.snapshot.maxBolusUnits))
        }
    }

    /// Phase 09.9 D-01: the phone bolus affordance inherits the no-cartridge hard block through the
    /// existing `cartridgeReadyForBolus` → `BolusGate.evaluate(cartridgeReady:)` wire — no per-surface code.
    @Test func midCartridgeChangeReportsNoCartridge() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            try? await backend.enterChangeCartridgeMode()   // sets cartridgeLoadState = 0 (CHANGE_CARTRIDGE)
            let g = model.bolusGate(amount: 2.0, minimum: 0.05)
            #expect(!g.canBolus)
            #expect(g.reason == .noCartridge)
        }
    }

    // MARK: P12 increment 4 — statusCommand emits the semantic bolus availability over the wire

    @Test func statusCommandEmitsCanBolusWhenConnected() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            let cmd = model.statusCommand(includeHistory: false)
            #expect(cmd.canBolus == true)
            #expect(cmd.bolusBlockReason == nil)
        }
    }

    @Test func statusCommandEmitsPumpNotLinkedWhenDisconnected() async {
        await withClean {
            let (model, _) = makeModel()   // never connected → .disconnected
            let cmd = model.statusCommand(includeHistory: false)
            #expect(cmd.canBolus == false)
            #expect(cmd.bolusBlockReason == "pumpNotLinked")
        }
    }

    @Test func statusCommandEmitsAccessDeniedWhenRemotesReadOnly() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            AppSettings.shared.remotesReadOnly = true
            let cmd = model.statusCommand(includeHistory: false)
            #expect(cmd.canBolus == false)
            #expect(cmd.bolusBlockReason == "accessDenied")
        }
    }

    /// Phase 09.9 D-01/D-05: the no-cartridge block propagates to every remote (watch/Garmin/Mac) through
    /// the existing `cmd.canBolus`/`cmd.bolusBlockReason` wire — no bespoke per-surface build.
    @Test func statusCommandEmitsNoCartridgeWhenCartridgeIsLoading() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()
            try? await backend.enterChangeCartridgeMode()   // sets cartridgeLoadState = 0 (CHANGE_CARTRIDGE)
            let cmd = model.statusCommand(includeHistory: false)
            #expect(cmd.canBolus == false)
            #expect(cmd.bolusBlockReason == "noCartridge")
        }
    }

    // MARK: P15 G5 (§2.3) — the optional remote-only dose ceiling clamps the REMOTE `BolusGate` maximum only

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    @Test func remoteCeilingClampsRemoteBolusGateMaxButNotThePhone() async {
        await withClean {
            let (model, backend) = makeModel()
            await backend.connect()                                   // MockBackend max bolus is 25 U
            let saved = AppSettings.shared.remoteBolusCeiling
            defer { AppSettings.shared.remoteBolusCeiling = saved }

            // No ceiling ⇒ the published remote max is the pump's own max (behavior-preserving passthrough).
            AppSettings.shared.remoteBolusCeiling = nil
            #expect(model.statusCommand(includeHistory: false).maxBolusUnits == backend.snapshot.maxBolusUnits)

            // Ceiling of 5 U ⇒ the remotes gate on 5, not the pump's 25.
            AppSettings.shared.remoteBolusCeiling = 5
            let cmd = model.statusCommand(includeHistory: false)
            #expect(cmd.maxBolusUnits == 5.0)

            // Fed into a real remote client, its `BolusGate` now refuses a 10 U dose (over the 5 U ceiling,
            // under the pump's 25 U max) — the clamp reaches the remote surface's own gate.
            let remote = RemoteCommandWireFixture(link: FakeLink())
            remote.handle(cmd)
            let rg = remote.bolusGate(amount: 10, minimum: 0.05)
            #expect(!rg.canBolus)
            #expect(rg.reason == .aboveMax(5.0))

            // The PHONE's own gate is unaffected: a 10 U dose (over the 5 U remote ceiling, under the 25 U
            // pump max) is still allowed on the phone surface.
            let phone = model.bolusGate(amount: 10, minimum: 0.05)
            #expect(phone.canBolus)
            #expect(phone.reason == nil)
        }
    }
}
