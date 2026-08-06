import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P12 (defect group D) — the remote-client seams that feed the shared `BolusGate`, and the Mac bolus
/// surface's use of them.
///
/// The Mac's `canDeliver` used to check only reachability + amount bounds; it ignored the relayed pump
/// state entirely, so under phone-pushed read-only or a dropped pump link it showed a live, tappable
/// Bolus button that the host then rejected (the A-05 show-then-fail class). It now routes through
/// `BolusGate.evaluate`, fed by `RemoteClientModel.pumpConnected` (link health) and the new
/// `.bolusInFlight` (a dose already running), plus the read-only flag as the access decision.
///
/// The gate's own precedence/logic is pinned in faBolusCore `BolusGateTests`. The Mac's entry view has no
/// unit-test seam, so `macGate` below mirrors `MacBolusEntryView.gate` exactly (the model-fed axes) and
/// this suite pins (a) the two `RemoteClientModel` seams across every connection string and (b) that the
/// Mac feed yields the right reason for each blocking condition. These seams are shared by the Apple
/// Watch and the remote-iPhone client too, so pinning them here guards those surfaces' later migrations.
@MainActor
@Suite(.serialized) struct RemoteClientBolusGateTests {

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Drive a status push carrying the host's connection string (`PumpConnectionState.rawValue`) and,
    /// optionally, the read-only flag — the same entry point the link's `onReceive` calls.
    private func model(connection: String, readOnly: Bool = false) -> RemoteClientModel {
        let m = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = connection
        cmd.remotesReadOnly = readOnly
        m.handle(cmd)
        return m
    }

    /// Mirrors `MacBolusEntryView.gate` (the model-fed axes): the Mac reads link + in-flight + read-only
    /// off the relayed state and passes them straight to the shared gate.
    private func macGate(_ m: RemoteClientModel, amount: Double, isCarbs: Bool = false)
        -> (canBolus: Bool, reason: BolusBlockReason?) {
        let access: AccessPolicy.AccessDecision = m.readOnly ? .deny(.remotesReadOnly) : .allow
        let maxV = isCarbs ? 200 : (m.maxBolusUnits > 0 ? m.maxBolusUnits : 25)
        return BolusGate.evaluate(reachable: m.reachable, linked: m.pumpConnected,
                                  bolusInFlight: m.bolusInFlight, amount: amount,
                                  minimum: isCarbs ? 1 : 0.05, maximum: maxV, access: access)
    }

    // MARK: seams

    @Test func linkAndInFlightSeamsMapEveryConnectionString() {
        // Before any push, nothing is linked and nothing is in flight.
        let fresh = RemoteClientModel(link: FakeLink())
        #expect(!fresh.pumpConnected); #expect(!fresh.bolusInFlight)

        // Connected: linked, not in flight.
        let connected = model(connection: PumpConnectionState.connected.rawValue)
        #expect(connected.pumpConnected); #expect(!connected.bolusInFlight)

        // Delivering: still linked (a dose is running), AND in flight — the two axes are independent.
        let bolusing = model(connection: PumpConnectionState.bolusing.rawValue)
        #expect(bolusing.pumpConnected); #expect(bolusing.bolusInFlight)

        // Every down state: neither linked nor in flight.
        for down in [PumpConnectionState.disconnected, .scanning, .connecting, .error] {
            let m = model(connection: down.rawValue)
            #expect(!m.pumpConnected, "\(down.rawValue) must not read as linked")
            #expect(!m.bolusInFlight, "\(down.rawValue) must not read as in-flight")
        }
    }

    // MARK: Mac feed

    @Test func connectedInBoundsAllows() {
        let g = macGate(model(connection: PumpConnectionState.connected.rawValue), amount: 2.0)
        #expect(g.canBolus); #expect(g.reason == nil)
    }

    @Test func droppedPumpLinkBlocksWithReason() {
        // The pre-fix Mac allowed this (it checked only reachability) — the concrete tightening.
        let g = macGate(model(connection: PumpConnectionState.disconnected.rawValue), amount: 2.0)
        #expect(!g.canBolus); #expect(g.reason == .pumpNotLinked)
    }

    @Test func readOnlyBlocksWithReason() {
        // The other pre-fix hole: read-only was ignored, so the Mac showed a tappable button host-rejected.
        let g = macGate(model(connection: PumpConnectionState.connected.rawValue, readOnly: true), amount: 2.0)
        #expect(!g.canBolus); #expect(g.reason == .accessDenied(.remotesReadOnly))
    }

    @Test func inFlightBlocksWithReason() {
        let g = macGate(model(connection: PumpConnectionState.bolusing.rawValue), amount: 2.0)
        #expect(!g.canBolus); #expect(g.reason == .bolusInFlight)
    }

    @Test func unreachableDominates() {
        // Reachable is the most fundamental gate: even a connected+in-bounds dose can't send if the phone
        // is out of range.
        let m = model(connection: PumpConnectionState.connected.rawValue)
        m.reachable = false
        let g = macGate(m, amount: 2.0)
        #expect(!g.canBolus); #expect(g.reason == .remoteUnreachable)
    }

    @Test func belowMinimumStaysQuietBounds() {
        // An empty/too-small field disables via a bounds reason (the button stays disabled, no nag label).
        let g = macGate(model(connection: PumpConnectionState.connected.rawValue), amount: 0)
        #expect(!g.canBolus); #expect(g.reason == .belowMinimum(0.05))
    }
}
