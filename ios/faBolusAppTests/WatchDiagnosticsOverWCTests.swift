import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.6-07 (D-03.1, D-04): simulated end-to-end round-trip for the watch-diagnostics-over-WC
/// channel — NO live WatchConnectivity, no paired watch. A `.diagnosticsRead` reply is built with the
/// exact same pure builder the watch uses (`WatchSelfDiagnostics.watchBody`), encoded, decoded (the
/// SAME validated decode path an untrusted transport uses), and handed to `PhoneRemoteHost.handle` —
/// proving every layer between "watch composes its own text" and "phone stores it" without hardware.
@Suite(.serialized) @MainActor
struct WatchDiagnosticsOverWCTests {
    /// `PhoneRemoteHost.model` is `weak` — the caller must keep `AppModel` alive for the host's
    /// lifetime (exactly like the real app's `App.swift`, which owns both). Returning the tuple (not
    /// just the host) is what makes that retention visible at each call site.
    private func makeHost() -> (host: PhoneRemoteHost, model: AppModel) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wd-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: url)
        return (PhoneRemoteHost(model: model), model)
    }

    /// A decoded `.diagnosticsRead` REPLY (built by the watch's own pure builder) surfaces through
    /// `lastWatchDiagnosticsText`, with the device name already redacted at source.
    @Test func decodedDiagnosticsReplySurfacesThroughLastWatchDiagnosticsText() throws {
        let (host, model) = makeHost()
        _ = model   // keep AppModel alive for the host's weak reference (see makeHost doc)
        #expect(host.lastWatchDiagnosticsText == nil)

        let watchText = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                        benchPumpStatus: "Paired", benchDeviceName: "Zev's Mobi")
        var reply = RemoteCommand(kind: .diagnosticsRead)
        reply.diagnosticsText = watchText
        // The SAME validated decode path an untrusted WatchConnectivity payload goes through.
        let decoded = try RemoteCommand.decodeValidated(try reply.encoded())

        host.handle(decoded)

        #expect(host.lastWatchDiagnosticsText == watchText)
        #expect(host.lastWatchDiagnosticsText?.contains("Zev's Mobi") == false)
        #expect(host.lastWatchDiagnosticsText?.contains("watch-") == true)
    }

    /// A bare `.diagnosticsRead` REQUEST (no `diagnosticsText` set — this is what the PHONE itself
    /// sends) must never set `lastWatchDiagnosticsText`, even if fed to `handle` directly.
    @Test func bareDiagnosticsRequestDoesNotSetLastWatchDiagnosticsText() throws {
        let (host, model) = makeHost()
        _ = model
        let bareRequest = try RemoteCommand.decodeValidated(try RemoteCommand(kind: .diagnosticsRead).encoded())

        host.handle(bareRequest)

        #expect(host.lastWatchDiagnosticsText == nil)
    }

    /// A bare request arriving AFTER a real reply must not clobber the already-stored text (only a
    /// reply that actually carries text may update the store).
    @Test func bareDiagnosticsRequestDoesNotClobberPreviouslyStoredText() throws {
        let (host, model) = makeHost()
        _ = model
        var reply = RemoteCommand(kind: .diagnosticsRead)
        reply.diagnosticsText = "Phone reachable: yes\nDirect-CGM failover: idle"
        host.handle(try RemoteCommand.decodeValidated(try reply.encoded()))
        #expect(host.lastWatchDiagnosticsText == reply.diagnosticsText)

        host.handle(try RemoteCommand.decodeValidated(try RemoteCommand(kind: .diagnosticsRead).encoded()))

        #expect(host.lastWatchDiagnosticsText == reply.diagnosticsText)
    }

    /// `requestWatchDiagnostics()` issues an outbound send attempt (a bare, non-mutating
    /// `.diagnosticsRead` request) — observed via the existing `sentCountForDiagnostics` counter, the
    /// same read-only accessor `WCDiagnostics` already relies on.
    @Test func requestWatchDiagnosticsIssuesAnOutboundSendAttempt() {
        let (host, model) = makeHost()
        _ = model
        let before = host.sentCountForDiagnostics

        host.requestWatchDiagnostics()

        #expect(host.sentCountForDiagnostics == before + 1)
    }
}
