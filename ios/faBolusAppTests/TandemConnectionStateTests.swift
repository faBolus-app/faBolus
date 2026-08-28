import Testing
import Foundation
import TandemBLE
import faBolusCore
@testable import faBolus

/// P12 (app-boundary connection-state surfacing). The kit forwards CoreBluetooth states the app used to
/// DROP (`default: break`) or FLATTEN. Two safety-relevant consequences: a radio power-off could leave a
/// STALE "Connected" showing, and a transport error's reason never reached the passive HUD viewer.
///
/// `applyClientState` / `applyClientError` are the delegate bodies factored out so the state→snapshot
/// mapping is testable without a live `PumpBLEClient` (a `CBCentralManager`). These pin: every radio-down
/// state fails closed to `.disconnected` with a user-facing reason (never fabricates connected), the
/// reason clears on reconnect, and a transport error preserves its description.
@Suite(.serialized) @MainActor
struct TandemConnectionStateTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    @Test func poweredOffNeverStaysConnectedAndSurfacesReason() {
        let b = backend()
        b.setConnectionForTesting(.connected)  // pretend we were linked…
        b.applyClientState(.poweredOff)  // …then the radio powers off
        #expect(b.snapshot.connection == .disconnected)  // must NOT stay .connected (the old default:break bug)
        #expect(!b.snapshot.isLinked)  // so the bolus gate refuses delivery
        #expect(b.snapshot.connectionDetail == "Bluetooth is off")
    }

    @Test func unauthorizedAndUnsupportedAndResettingSurfaceReasons() {
        let b = backend()
        b.applyClientState(.unauthorized)
        #expect(b.snapshot.connection == .disconnected)
        #expect(b.snapshot.connectionDetail?.contains("permission") == true)
        b.applyClientState(.unsupported)
        #expect(b.snapshot.connectionDetail?.contains("unavailable") == true)
        b.applyClientState(.resetting)
        #expect(b.snapshot.connectionDetail == "Bluetooth is resetting…")
    }

    @Test func plainDisconnectHasNoFabricatedReason() {
        let b = backend()
        b.applyClientState(.disconnected)
        #expect(b.snapshot.connection == .disconnected)
        #expect(b.snapshot.connectionDetail == nil)  // "Disconnected" already says enough
    }

    @Test func reconnectClearsStaleReason() {
        let b = backend()
        b.applyClientState(.poweredOff)
        #expect(b.snapshot.connectionDetail == "Bluetooth is off")
        b.applyClientState(.ready)
        // CR-01 (R2-01): bare BLE `.ready` now publishes the not-yet-usable `.connecting` (the usable
        // `.connected` is published only at the polling/onPaired moment). The stale reason must still clear.
        #expect(b.snapshot.connection == .connecting)
        #expect(b.snapshot.connectionDetail == nil)  // stale "Bluetooth is off" must not linger
    }

    @Test func transportErrorPreservesItsReason() {
        struct LinkErr: LocalizedError { var errorDescription: String? { "Peer removed pairing" } }
        let b = backend()
        // debug pump-background-disconnect (CRITERION 1 & 2, 2026-08-20): `applyClientError` no longer
        // DOWNGRADES the connection state — `applyClientState` owns it, and a live/recovering link must never
        // be flipped to `.disconnected` by a transport error (that fired a spurious disconnect banner on every
        // momentary drop). It now only ENRICHES the reason on a link that is ALREADY down, for the passive HUD
        // viewer. So drive it from a plain `.disconnected` (the state a real terminal drop lands in via
        // `applyClientState`) and pin that the machine-token reason is still captured. The "must NOT downgrade
        // a live/recovering link" half is pinned by `transportErrorNeverDowngradesALiveOrRecoveringLink`.
        b.setConnectionForTesting(.disconnected)
        b.applyClientError(LinkErr())
        #expect(b.snapshot.connection == .disconnected)
        // D-03 (01.1-01): `applyClientError` prefixes the localized description with the bridged NSError
        // `domain#code` (e.g. "CBErrorDomain#6 ..." for a real CoreBluetooth error) so the reason is a
        // stable, bucketable token instead of a bare human string — the original description still appears
        // verbatim as the suffix, which is the "preserves its reason" behavior this test pins.
        #expect(b.snapshot.connectionDetail?.hasSuffix("Peer removed pairing") == true)
        #expect(b.snapshot.connectionDetail?.contains("#") == true)
    }

    /// debug pump-background-disconnect (CRITERION 1 & 2, 2026-08-20). The kit fires `didError` on an
    /// unintended drop BEFORE its paired `didChange(.connecting)`, and fires `didError` with NO state change
    /// at all on a bare read/notify error while still `.ready`. `applyClientError` must therefore NOT
    /// downgrade a LIVE or RECOVERING link to `.disconnected` — doing so would surface a transient
    /// `.disconnected` that trips `SafetyEdge.raise` on every momentary drop (CRITERION 1) and promotes a
    /// transient read/notify hiccup into a spurious disconnect (CRITERION 2, the H2 read-path). The kit's
    /// `applyClientState` is the sole authority for the connection state.
    @Test func transportErrorNeverDowngradesALiveOrRecoveringLink() {
        let b = backend()
        struct LinkErr: LocalizedError { var errorDescription: String? { "read failed" } }
        // Live link + a transport error (e.g. a read/notify hiccup that does NOT tear the link down): the
        // displayed connection must stay `.connected` — the kit still owns the live link.
        b.setConnectionForTesting(.connected)
        b.applyClientError(LinkErr())
        #expect(b.snapshot.connection == .connected, "a read/notify error must NOT fabricate a disconnect while linked")
        // Mid-reconnect (`.connecting`) + a transport error (the kit's didError-before-didChange ordering on
        // a drop): must NOT flip to `.disconnected` — the reconnect window has to stay `.connecting`.
        b.setConnectionForTesting(.connecting)
        b.applyClientError(LinkErr())
        #expect(
            b.snapshot.connection == .connecting,
            "the reconnect window must stay .connecting, never flicker .disconnected")
    }

    /// The reconnect-window ordering the kit actually produces on a genuine drop: `applyClientError` (the
    /// kit's `didError`) fires FIRST while still `.connected`, then `applyClientState(.connecting)`. The
    /// observed `snapshot.connection` sequence must never pass through `.disconnected`/`.error`, so
    /// `SafetyEdge` (fed the consecutive pairs) never raises during the reconnect window — and a recovery
    /// (`.ready`) clears while an exhaustion (`.reconnectExhausted`) is the one edge that raises.
    @Test func genuineDropSequenceStaysConnectingAndOnlyExhaustionRaises() {
        let b = backend()
        struct DropErr: LocalizedError { var errorDescription: String? { "peer disconnected" } }
        b.setConnectionForTesting(.connected)
        var observed: [PumpConnectionState] = [b.snapshot.connection]
        b.applyClientError(DropErr())  // kit's didError — fires before the .connecting didChange
        observed.append(b.snapshot.connection)
        b.applyClientState(.connecting)  // kit's didChange(.connecting)
        observed.append(b.snapshot.connection)
        // No down state anywhere in the reconnect window…
        #expect(!observed.contains(.disconnected))
        #expect(!observed.contains(.error))
        #expect(b.snapshot.connection == .connecting)
        // …so every consecutive edge is quiet until a terminal transition.
        var prev = observed.first
        for now in observed.dropFirst() {
            #expect(SafetyEdge.connection(prev: prev, now: now) != .raise)
            prev = now
        }
        // Recovery clears; a from-scratch drop→exhaust raises exactly once at the give-up.
        #expect(SafetyEdge.connection(prev: .connecting, now: .connected) == .clear)
        b.applyClientState(.reconnectExhausted)
        #expect(b.snapshot.connection == .error)
        #expect(SafetyEdge.connection(prev: .connecting, now: .error) == .raise)
    }

    /// `.reconnectExhausted` (the kit's reconnect ladder gave up — `.planning/debug/pump-pairing-loop.md`)
    /// must read as `.error`, not a plain retryable `.disconnected`, and must carry the specific,
    /// actionable t:connect guidance — not fall through to `default:` with a nil detail (the gap this
    /// fix closes; `.reconnectExhausted` used to have no explicit case).
    @Test func reconnectExhaustedSurfacesAsErrorWithActionableGuidance() {
        let b = backend()
        b.setConnectionForTesting(.connected)  // pretend we were linked…
        b.applyClientState(.reconnectExhausted)  // …then the ladder gives up
        #expect(b.snapshot.connection == .error)
        #expect(!b.snapshot.isLinked)  // so the bolus gate refuses delivery
        #expect(b.snapshot.connectionDetail?.contains("t:connect") == true)
    }

    /// Kit ordering: `reconnectTick()`'s `state = .reconnectExhausted` assignment fires `didChange`
    /// synchronously (the `didSet`) BEFORE `notify { didError(.reconnectLoopDetected) }` runs — so
    /// `applyClientState`'s actionable message is already set by the time `applyClientError` sees the
    /// paired error. `PumpBLEClient.ClientError` isn't `LocalizedError`, so bridging it to `NSError` the
    /// way every other transport error is handled would silently overwrite that message with Swift's
    /// unhelpful boilerplate ("The operation couldn't be completed…") — pin that it doesn't.
    @Test func reconnectLoopDetectedErrorDoesNotClobberTheGuidance() {
        let b = backend()
        b.applyClientState(.reconnectExhausted)
        let detailBefore = b.snapshot.connectionDetail
        #expect(detailBefore != nil)
        b.applyClientError(PumpBLEClient.ClientError.reconnectLoopDetected)
        #expect(b.snapshot.connection == .error)
        #expect(b.snapshot.connectionDetail == detailBefore)
    }
}
