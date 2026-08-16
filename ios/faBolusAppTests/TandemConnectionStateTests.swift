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
        b.setConnectionForTesting(.connected)          // pretend we were linked…
        b.applyClientState(.poweredOff)                // …then the radio powers off
        #expect(b.snapshot.connection == .disconnected)   // must NOT stay .connected (the old default:break bug)
        #expect(!b.snapshot.isLinked)                     // so the bolus gate refuses delivery
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
        #expect(b.snapshot.connectionDetail == nil)   // "Disconnected" already says enough
    }

    @Test func reconnectClearsStaleReason() {
        let b = backend()
        b.applyClientState(.poweredOff)
        #expect(b.snapshot.connectionDetail == "Bluetooth is off")
        b.applyClientState(.ready)
        #expect(b.snapshot.connection == .connected)
        #expect(b.snapshot.connectionDetail == nil)   // stale "Bluetooth is off" must not linger
    }

    @Test func transportErrorPreservesItsReason() {
        struct LinkErr: LocalizedError { var errorDescription: String? { "Peer removed pairing" } }
        let b = backend()
        b.applyClientError(LinkErr())
        #expect(b.snapshot.connection == .disconnected)
        // D-03 (01.1-01): `applyClientError` now prefixes the localized description with the bridged
        // NSError `domain#code` (e.g. "CBErrorDomain#6 ..." for a real CoreBluetooth error) so the reason
        // is a stable, bucketable token instead of a bare human string — the original description still
        // appears verbatim as the suffix, which is the "preserves its reason" behavior this test pins.
        #expect(b.snapshot.connectionDetail?.hasSuffix("Peer removed pairing") == true)
        #expect(b.snapshot.connectionDetail?.contains("#") == true)
    }

    /// `.reconnectExhausted` (the kit's reconnect ladder gave up — `.planning/debug/pump-pairing-loop.md`)
    /// must read as `.error`, not a plain retryable `.disconnected`, and must carry the specific,
    /// actionable t:connect guidance — not fall through to `default:` with a nil detail (the gap this
    /// fix closes; `.reconnectExhausted` used to have no explicit case).
    @Test func reconnectExhaustedSurfacesAsErrorWithActionableGuidance() {
        let b = backend()
        b.setConnectionForTesting(.connected)             // pretend we were linked…
        b.applyClientState(.reconnectExhausted)            // …then the ladder gives up
        #expect(b.snapshot.connection == .error)
        #expect(!b.snapshot.isLinked)                      // so the bolus gate refuses delivery
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
