import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The per-surface bolus-auth wire round-trip on the shared `RemoteCommandWireFixture`. Pins the
/// **fail-closed** default (a cold launch / glance with no push, and a legacy host that omits the fields,
/// both keep bolusing hidden) and that a push arms it, with read-only still winning. Expressed on the
/// Garmin surface — the Apple-Watch sibling (`watchBolusEnabled`/`watchBolusAllowed`) was retired
/// end-to-end; this behavior is otherwise surface-symmetric.
@MainActor
@Suite(.serialized) struct RemoteBolusAuthWireTests {

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    @Test func freshModelFailsClosed() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(!m.garminBolusEnabled)
        #expect(!m.bolusPasscodeRequired)
        #expect(!m.garminBolusAllowed)  // no push yet ⇒ bolus hidden
    }

    @Test func legacyHostWithoutTheFieldsStaysDisabled() {
        // A host predating §2.3 omits the enables entirely; the remote must NOT infer "enabled".
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = "Connected"
        cmd.remotesReadOnly = false
        m.handle(cmd)
        #expect(!m.garminBolusAllowed)
    }

    @Test func pushArmsGarminBolusButReadOnlyStillWins() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var on = RemoteCommand(kind: .statusRead)
        on.message = "Connected"
        on.remotesReadOnly = false
        on.garminBolusEnabled = true
        on.bolusPasscodeRequired = true
        m.handle(on)
        #expect(m.garminBolusEnabled && m.bolusPasscodeRequired)
        #expect(m.garminBolusAllowed)  // enabled + not read-only ⇒ allowed

        var ro = RemoteCommand(kind: .statusRead)
        ro.message = "Connected"
        ro.remotesReadOnly = true
        ro.garminBolusEnabled = true
        m.handle(ro)
        #expect(!m.garminBolusAllowed)  // read-only wins over the enable
    }
}
