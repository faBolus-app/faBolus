import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Remote/Mac bolus UI must hide when the relayed pump is disconnected, read-only, or already in
/// flight — not show a tappable button the host then rejects. The shared `RemoteCommandWireFixture`
/// seams feed `BolusGate`.
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
    private func model(connection: String, readOnly: Bool = false) -> RemoteCommandWireFixture {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.message = connection
        cmd.remotesReadOnly = readOnly
        m.handle(cmd)
        return m
    }

    /// Mirrors `MacBolusEntryView.gate` (the model-fed axes): the Mac reads link + in-flight + read-only
    /// off the relayed state and passes them straight to the shared gate.
    private func macGate(_ m: RemoteCommandWireFixture, amount: Double, isCarbs: Bool = false)
        -> (canBolus: Bool, reason: BolusBlockReason?)
    {
        let access: AccessPolicy.AccessDecision = m.readOnly ? .deny(.remotesReadOnly) : .allow
        let maxV = isCarbs ? 200 : (m.maxBolusUnits > 0 ? m.maxBolusUnits : 25)
        return BolusGate.evaluate(
            reachable: m.reachable, linked: m.pumpConnected,
            bolusInFlight: m.bolusInFlight, amount: amount,
            minimum: isCarbs ? 1 : 0.05, maximum: maxV, access: access)
    }

    // MARK: seams

    @Test func linkAndInFlightSeamsMapEveryConnectionString() {
        // Before any push, nothing is linked and nothing is in flight.
        let fresh = RemoteCommandWireFixture(link: FakeLink())
        #expect(!fresh.pumpConnected)
        #expect(!fresh.bolusInFlight)

        // Connected: linked, not in flight.
        let connected = model(connection: PumpConnectionState.connected.rawValue)
        #expect(connected.pumpConnected)
        #expect(!connected.bolusInFlight)

        // Delivering: still linked (a dose is running), AND in flight — the two axes are independent.
        let bolusing = model(connection: PumpConnectionState.bolusing.rawValue)
        #expect(bolusing.pumpConnected)
        #expect(bolusing.bolusInFlight)

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
        #expect(g.canBolus)
        #expect(g.reason == nil)
    }

    @Test func droppedPumpLinkBlocksWithReason() {
        // The pre-fix Mac allowed this (it checked only reachability) — the concrete tightening.
        let g = macGate(model(connection: PumpConnectionState.disconnected.rawValue), amount: 2.0)
        #expect(!g.canBolus)
        #expect(g.reason == .pumpNotLinked)
    }

    @Test func readOnlyBlocksWithReason() {
        // The other pre-fix hole: read-only was ignored, so the Mac showed a tappable button host-rejected.
        let g = macGate(model(connection: PumpConnectionState.connected.rawValue, readOnly: true), amount: 2.0)
        #expect(!g.canBolus)
        #expect(g.reason == .accessDenied(.remotesReadOnly))
    }

    @Test func inFlightBlocksWithReason() {
        let g = macGate(model(connection: PumpConnectionState.bolusing.rawValue), amount: 2.0)
        #expect(!g.canBolus)
        #expect(g.reason == .bolusInFlight)
    }

    @Test func unreachableDominates() {
        // Reachable is the most fundamental gate: even a connected+in-bounds dose can't send if the phone
        // is out of range.
        let m = model(connection: PumpConnectionState.connected.rawValue)
        m.reachable = false
        let g = macGate(m, amount: 2.0)
        #expect(!g.canBolus)
        #expect(g.reason == .remoteUnreachable)
    }

    @Test func belowMinimumStaysQuietBounds() {
        // An empty/too-small field disables via a bounds reason (the button stays disabled, no nag label).
        let g = macGate(model(connection: PumpConnectionState.connected.rawValue), amount: 0)
        #expect(!g.canBolus)
        #expect(g.reason == .belowMinimum(0.05))
    }

    // MARK: shared bolusGate / bolusAvailability (remote-iPhone open button + sheet; seeds the watch)

    @Test func availabilityReflectsSurfaceGatesNotAmount() {
        // The "open bolus" affordance's gate — independent of any entered amount.
        #expect(model(connection: PumpConnectionState.connected.rawValue).bolusAvailability.canBolus)
        #expect(model(connection: PumpConnectionState.disconnected.rawValue).bolusAvailability.reason == .pumpNotLinked)
        #expect(model(connection: PumpConnectionState.bolusing.rawValue).bolusAvailability.reason == .bolusInFlight)
        #expect(
            model(connection: PumpConnectionState.connected.rawValue, readOnly: true)
                .bolusAvailability.reason == .accessDenied(.remotesReadOnly))
        let unreachable = model(connection: PumpConnectionState.connected.rawValue)
        unreachable.reachable = false
        #expect(unreachable.bolusAvailability.reason == .remoteUnreachable)
    }

    @Test func bolusGateChecksAmountBoundsInUnits() {
        let m = model(connection: PumpConnectionState.connected.rawValue)  // maxBolusUnits default 25
        #expect(m.bolusGate(amount: 2.0, minimum: 0.05).canBolus)
        #expect(m.bolusGate(amount: 0.0, minimum: 0.05).reason == .belowMinimum(0.05))
        #expect(m.bolusGate(amount: 99, minimum: 0.05).reason == .aboveMax(25))
    }

    // MARK: asSnapshot maps the RELAYED pump link, not client reachability (clobber fix)

    // MARK: - Capability channel — supportsRemoteAlertDismiss mirror ("Clear" vs "Snooze")

    @Test func alertDismissCapabilityMirrorsAndDefaultsSafe() {
        // Safe default before any push: false ⇒ the remote shows "Snooze" (honest — a t:slim dismiss
        // only snoozes locally, so the label must not promise a pump clear).
        #expect(!RemoteCommandWireFixture(link: FakeLink()).canDismissAlertOnPump)

        // A statusRead carrying the capability sets the mirror (Mobi ⇒ true ⇒ "Clear").
        let m = RemoteCommandWireFixture(link: FakeLink())
        var on = RemoteCommand(kind: .statusRead)
        on.supportsRemoteAlertDismiss = true
        m.handle(on)
        #expect(m.canDismissAlertOnPump)

        // Absent field keeps the last-known value (keep-current idiom) — a later push that omits it must
        // not silently flip the label back.
        var absent = RemoteCommand(kind: .statusRead)
        absent.message = PumpConnectionState.connected.rawValue
        m.handle(absent)
        #expect(m.canDismissAlertOnPump)

        // A push can narrow it to false (a t:slim host), flipping the label to "Snooze".
        var off = RemoteCommand(kind: .statusRead)
        off.supportsRemoteAlertDismiss = false
        m.handle(off)
        #expect(!m.canDismissAlertOnPump)
    }

    @Test func asSnapshotUsesRelayedConnectionNotReachability() {
        // In range but the pump link dropped → must read as disconnected, not "connected" (the old bug
        // derived connection from reachability, so a real pump-link drop was hidden while in range).
        let dropped = model(connection: PumpConnectionState.disconnected.rawValue)
        dropped.reachable = true
        #expect(dropped.asSnapshot.connection == .disconnected)
        // Out of range but the last relayed pump state was connected → show the relayed state, not a
        // fabricated .disconnected (client reachability is surfaced separately by the Reconnecting banner).
        let outOfRange = model(connection: PumpConnectionState.connected.rawValue)
        outOfRange.reachable = false
        #expect(outOfRange.asSnapshot.connection == .connected)
    }
}
