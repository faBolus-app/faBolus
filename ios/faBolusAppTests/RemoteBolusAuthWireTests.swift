import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P15 G3 (§2.3): the per-surface bolus-auth wire round-trip on the shared `RemoteCommandWireFixture`. Pins the
/// **fail-closed** default (a cold launch / glance with no push, and a legacy host that omits the fields,
/// both keep bolusing hidden) and that a push arms it, with read-only still winning.
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
        #expect(!m.watchBolusEnabled)
        #expect(!m.garminBolusEnabled)
        #expect(!m.bolusPasscodeRequired)
        #expect(!m.watchBolusAllowed)               // no push yet ⇒ bolus hidden
    }

    @Test func legacyHostWithoutTheFieldsStaysDisabled() {
        // A host predating §2.3 omits the enables entirely; the remote must NOT infer "enabled".
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead); cmd.message = "Connected"; cmd.remotesReadOnly = false
        m.handle(cmd)
        #expect(!m.watchBolusAllowed)
    }

    @Test func pushArmsWatchBolusButReadOnlyStillWins() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var on = RemoteCommand(kind: .statusRead)
        on.message = "Connected"; on.remotesReadOnly = false
        on.watchBolusEnabled = true; on.garminBolusEnabled = true; on.bolusPasscodeRequired = true
        m.handle(on)
        #expect(m.watchBolusEnabled && m.garminBolusEnabled && m.bolusPasscodeRequired)
        #expect(m.watchBolusAllowed)                // enabled + not read-only ⇒ allowed

        var ro = RemoteCommand(kind: .statusRead)
        ro.message = "Connected"; ro.remotesReadOnly = true; ro.watchBolusEnabled = true
        m.handle(ro)
        #expect(!m.watchBolusAllowed)               // read-only wins over the enable
    }
}
