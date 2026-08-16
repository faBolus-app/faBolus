import XCTest
@testable import faBolusCore

/// Phase 09.6-07 (D-03.1, D-04): pure builder + redaction + presentation pins for
/// `WatchSelfDiagnostics` — the watch's own diagnostics text, requested by the phone over WC and
/// replied by the watch (`RemoteCommand.Kind.diagnosticsRead`). No live transport, no BLE, no paired
/// watch — every case here is fabricated plain values in, string out.
final class WatchSelfDiagnosticsTests: XCTestCase {

    // MARK: - watchBody

    func testWatchBodyReachableAndDirectCgmIdle() {
        let body = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false)
        XCTAssertTrue(body.contains("Phone reachable: yes"))
        XCTAssertTrue(body.contains("Direct-CGM failover: idle"))
    }

    func testWatchBodyUnreachableAndDirectCgmActive() {
        let body = WatchSelfDiagnostics.watchBody(reachable: false, directCgmActive: true)
        XCTAssertTrue(body.contains("Phone reachable: no"))
        XCTAssertTrue(body.contains("Direct-CGM failover: active"))
    }

    /// No bench status supplied ⇒ no "Bench pump" line at all (not a placeholder line) — this field
    /// is genuinely absent on every non-bench build.
    func testWatchBodyOmitsBenchLineWhenNoBenchStatusSupplied() {
        let body = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false)
        XCTAssertFalse(body.contains("Bench pump"))
    }

    /// A supplied bench device name is NEVER rendered verbatim — it is reduced to a deterministic
    /// `watch-XXXX` token (T-09.6-01).
    func testWatchBodyRedactsBenchDeviceNameToStableToken() {
        let body = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                   benchPumpStatus: "Paired", benchDeviceName: "Zev's Mobi")
        XCTAssertFalse(body.contains("Zev's Mobi"), "raw device name must never appear verbatim")
        XCTAssertTrue(body.contains("Paired"))
        XCTAssertTrue(body.contains("watch-"), "must render a watch-XXXX redaction token")
    }

    /// The token is deterministic: the SAME name always yields the SAME token, across independent
    /// calls (SHA-256, not Swift's process-randomized `Hasher`) — so repeated diagnostics pulls can be
    /// correlated without ever reconstructing the original name.
    func testWatchBodyDeviceNameTokenIsDeterministicAcrossCalls() {
        let first = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                    benchPumpStatus: "Paired", benchDeviceName: "Bench Pump A")
        let second = WatchSelfDiagnostics.watchBody(reachable: false, directCgmActive: true,
                                                     benchPumpStatus: "Paired", benchDeviceName: "Bench Pump A")
        func extractToken(_ s: String) -> String? {
            guard let range = s.range(of: "watch-") else { return nil }
            return String(s[range.lowerBound...].prefix(14))
        }
        XCTAssertEqual(extractToken(first), extractToken(second))
    }

    /// A different name yields a different token (not a constant placeholder).
    func testWatchBodyDifferentDeviceNamesYieldDifferentTokens() {
        let a = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                benchPumpStatus: "Paired", benchDeviceName: "Bench Pump A")
        let b = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                benchPumpStatus: "Paired", benchDeviceName: "Bench Pump B")
        XCTAssertNotEqual(a, b)
    }

    /// A bench status with no device name still renders the status line, with no leftover token/paren.
    func testWatchBodyBenchStatusWithoutDeviceNameRendersPlainStatus() {
        let body = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: false,
                                                   benchPumpStatus: "Idle (not paired)", benchDeviceName: nil)
        XCTAssertTrue(body.contains("Bench pump: Idle (not paired)"))
        XCTAssertFalse(body.contains("watch-"))
    }

    /// No therapy/glucose value can ever appear — `watchBody` accepts no such parameter, so a supplied
    /// bench status string is the only free-text surface, and it must not smuggle a glucose-shaped
    /// numeric label through even coincidentally in the fixed lines this builder itself emits.
    func testWatchBodyFixedLinesCarryNoGlucoseOrTherapyLabel() {
        let body = WatchSelfDiagnostics.watchBody(reachable: true, directCgmActive: true)
        for forbidden in ["mg/dL", "mmol", "IOB", "bolus", "carb"] {
            XCTAssertFalse(body.localizedCaseInsensitiveContains(forbidden),
                            "watchBody's own fixed lines must never mention \(forbidden)")
        }
    }

    // MARK: - phoneSection

    func testPhoneSectionOptInOffRendersHeaderAndPrompt() {
        let section = WatchSelfDiagnostics.phoneSection(body: "Phone reachable: yes", enabled: false)
        XCTAssertTrue(section.contains("[Watch self]"))
        XCTAssertTrue(section.contains("Share local diagnostics"))
        // Never leak a body while the opt-in is off, even if one happened to be supplied.
        XCTAssertFalse(section.contains("Phone reachable: yes"))
    }

    func testPhoneSectionEnabledButNoBodyYetRendersExplicitPlaceholder() {
        let section = WatchSelfDiagnostics.phoneSection(body: nil, enabled: true)
        XCTAssertTrue(section.contains("[Watch self]"))
        XCTAssertTrue(section.contains("— (not currently reachable)"))
    }

    func testPhoneSectionEnabledWithEmptyBodyRendersExplicitPlaceholder() {
        let section = WatchSelfDiagnostics.phoneSection(body: "", enabled: true)
        XCTAssertTrue(section.contains("[Watch self]"))
        XCTAssertTrue(section.contains("— (not currently reachable)"))
    }

    func testPhoneSectionEnabledWithBodyPassesItThroughVerbatim() {
        let body = "Phone reachable: yes\nDirect-CGM failover: idle"
        let section = WatchSelfDiagnostics.phoneSection(body: body, enabled: true)
        XCTAssertTrue(section.contains("[Watch self]"))
        XCTAssertTrue(section.contains(body))
    }

    /// The header is never omitted (Pitfall 4) — all three states share the same first two lines.
    func testPhoneSectionHeaderNeverOmittedAcrossAllStates() {
        let off = WatchSelfDiagnostics.phoneSection(body: nil, enabled: false)
        let onEmpty = WatchSelfDiagnostics.phoneSection(body: nil, enabled: true)
        let onPresent = WatchSelfDiagnostics.phoneSection(body: "x", enabled: true)
        for section in [off, onEmpty, onPresent] {
            XCTAssertTrue(section.contains("[Watch self]"))
        }
    }
}
