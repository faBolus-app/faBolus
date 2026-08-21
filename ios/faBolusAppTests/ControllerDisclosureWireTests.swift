import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// B2 (S1+O3): the controller-disclosure wire round-trip on the shared `RemoteCommandWireFixture`. A remote
/// receives the pump's controller identity (`controllerVariant`) + runtime on/off (`controlIQEnabled`)
/// and reconstructs the `ControllerDescriptor` locally, deriving the SAME auto-correction disclosure the
/// phone shows — no prose crosses the wire. Pins: fail-safe defaults (fresh model / legacy host omitting
/// the fields ⇒ no disclosure), a push arms it, the runtime-off gate suppresses it, and an unknown token
/// falls back to `.none` without crashing. Facts only — nothing here gates a dose.
@MainActor
@Suite(.serialized) struct ControllerDisclosureWireTests {

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    @Test func freshModelShowsNoDisclosure() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.controllerVariant == .none)
        #expect(!m.controlIQEnabled)
        #expect(m.autoCorrectionAmbient == nil)
        #expect(m.autoCorrectionLockout == nil)
    }

    @Test func legacyHostOmittingTheFieldsShowsNoDisclosure() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead); cmd.message = "Connected"; cmd.bgMgdl = 210
        m.handle(cmd)
        #expect(m.controllerVariant == .none)        // absent ⇒ safe default, not inferred
        #expect(m.autoCorrectionAmbient == nil)
        #expect(m.autoCorrectionLockout == nil)
    }

    @Test func pushArmsBothDisclosuresAndNamesTheController() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = "Connected"; cmd.bgMgdl = 210; cmd.trend = "flat"   // 210 ≥ 180 ⇒ lockout fires regardless of trend
        cmd.controllerVariant = ControllerVariant.controlIQPro.rawValue
        cmd.controlIQEnabled = true
        m.handle(cmd)
        #expect(m.controllerVariant == .controlIQPro)
        #expect(m.controlIQEnabled)
        // Same faBolusCore derivation the phone uses; both strings present and mention the descriptor name.
        let name = ControllerDescriptor.for(.controlIQPro).displayName
        #expect(m.autoCorrectionAmbient?.contains(name) == true)
        #expect(m.autoCorrectionLockout?.contains(name) == true)
    }

    @Test func controlIQOffSuppressesTheDisclosure() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = "Connected"; cmd.bgMgdl = 210
        cmd.controllerVariant = ControllerVariant.controlIQPro.rawValue
        cmd.controlIQEnabled = false                 // capable variant, but OFF at runtime
        m.handle(cmd)
        #expect(m.controllerVariant == .controlIQPro)
        #expect(m.autoCorrectionAmbient == nil)      // mechanism gate: nothing renders while off
        #expect(m.autoCorrectionLockout == nil)
    }

    @Test func unknownTokenFallsBackToNone() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = "Connected"; cmd.bgMgdl = 210
        cmd.controllerVariant = "controlIQPlus"      // not the frozen token ⇒ unknown
        cmd.controlIQEnabled = true
        m.handle(cmd)
        #expect(m.controllerVariant == .none)        // never crash, never a wrong controller
        #expect(m.autoCorrectionAmbient == nil)
    }
}
