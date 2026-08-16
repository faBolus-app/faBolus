import Testing
import Foundation
@testable import faBolus

/// Phase 09.6-05 (Task 2, Part C-3b, D-03.3, T-09.6-03): makes the "WatchDebugView adds NO new
/// pairing/connect/control capability" rule self-enforcing.
///
/// `WatchPumpClient` (watch's direct-to-pump client, bench-only per `STATUS.md`/C9) is compiled only
/// into the watch target, and only when `FABOLUS_WATCH_DIRECT_PUMP=1` — this suite (in the iOS app
/// test target) cannot import or instantiate it. So the *rule* — "no control-path signature was
/// added/removed/altered by this plan, and the new bench diagnostics screen never calls one" — is
/// verified the same way `SettingsReachabilityGuardTests`/`LiveActivityBoundaryTests` verify their
/// own source-level invariants: a `#filePath`-rooted directory walk to the watch source files,
/// `String(contentsOf:)`, and a regex/substring scan. No BLE, no watch simulator, no live pump.
struct WatchDirectBleScopeGuardTests {

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/WatchDirectBleScopeGuardTests.swift`) until `watch/faBolusWatch`
    /// exists — same technique as `SettingsReachabilityGuardTests.viewsDirURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("watch/faBolusWatch")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Function-signature extraction

    /// Extracts every `func`/`static func` SIGNATURE (name + parameter list + optional return type,
    /// no body) from a Swift source string, whitespace-normalized to a single-space-separated string
    /// so formatting-only changes (line wraps, extra blank lines) don't trip the guard — only an
    /// actual signature change does.
    private static func functionSignatures(in source: String) -> Set<String> {
        let pattern = #"(?:static\s+)?func\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^{}]*\)(?:\s*->\s*[^{\n]+?)?\s*(?=\{)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var out: Set<String> = []
        for m in matches {
            let raw = ns.substring(with: m.range)
            let normalized = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            out.insert(normalized)
        }
        return out
    }

    /// Pinned baseline, recorded from `watch/faBolusWatch/direct-pump/WatchPumpClient.swift` as it
    /// stood BEFORE Phase 09.6-05 (which added only a read-only computed property,
    /// `statusForDiagnostics` — not a `func` — so this set is unchanged by this plan). Any future
    /// plan that removes or alters one of these signatures turns this guard RED; adding a brand-new
    /// function is still permitted (additive-only superset check, not exact-set equality).
    private static let pinnedBaselineSignatures: Set<String> = [
        "static func isValidPairingCode(_ code: String) -> Bool",
        "func pair(code: String)",
        "func connectResume()",
        "func disconnect()",
        "func forget()",
        "func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State)",
        "func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int)",
        "func pumpClientDidBecomeReady(_ c: PumpBLEClient)",
        "func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic)",
        "func pumpClient(_ c: PumpBLEClient, didError error: Error)",
    ]

    @Test func watchPumpClientControlPathSignaturesAreAdditiveOnlyVsPinnedBaseline() throws {
        guard let source = Self.readSource("watch/faBolusWatch/direct-pump/WatchPumpClient.swift") else {
            Issue.record("could not resolve watch/faBolusWatch/direct-pump/WatchPumpClient.swift from #filePath=\(#filePath)")
            return
        }
        let current = Self.functionSignatures(in: source)
        // A path-resolution bug must fail loudly, not pass vacuously (mirrors
        // SettingsReachabilityGuardTests/LiveActivityBoundaryTests' own file-resolution sanity checks).
        #expect(current.count >= Self.pinnedBaselineSignatures.count,
                "found fewer function signatures than the pinned baseline — path resolution likely broke")
        for baseline in Self.pinnedBaselineSignatures {
            #expect(current.contains(baseline),
                    "WatchPumpClient control-path signature removed or altered: \(baseline)")
        }
    }

    // MARK: - WatchDebugView: reads a status accessor, adds no control affordance

    @Test func watchDebugViewReadsStatusAccessorAndCallsNoControlPathMethod() throws {
        guard let source = Self.readSource("watch/faBolusWatch/Views/WatchDebugView.swift") else {
            Issue.record("could not resolve watch/faBolusWatch/Views/WatchDebugView.swift from #filePath=\(#filePath)")
            return
        }
        #expect(source.contains("statusForDiagnostics"), "WatchDebugView must read the read-only status accessor")
        // None of WatchPumpClient's control-path methods may be invoked from this read-only screen.
        for controlCall in ["pump.pair(", "pump.connectResume(", "pump.forget(", "pump.disconnect("] {
            #expect(!source.contains(controlCall),
                    "WatchDebugView must not call the control-path method \(controlCall) — read-only screen (D-04)")
        }
    }

    @Test func watchDebugViewAddsNoMoreInteractiveControlThanWatchDirectView() throws {
        guard let debugSource = Self.readSource("watch/faBolusWatch/Views/WatchDebugView.swift"),
              let directSource = Self.readSource("watch/faBolusWatch/direct-pump/WatchDirectView.swift") else {
            Issue.record("could not resolve WatchDebugView.swift / WatchDirectView.swift from #filePath=\(#filePath)")
            return
        }
        // WatchDirectView is the existing control surface (Pair/Re-pair/Forget buttons) — it MUST have
        // at least one Button to make the comparison meaningful (guards against a vacuous pass if that
        // view is ever gutted).
        let directButtonCount = directSource.components(separatedBy: "Button").count - 1
        #expect(directButtonCount > 0, "WatchDirectView has no Button — the comparison baseline is vacuous")
        // WatchDebugView must add STRICTLY NO interactive control (Button) of its own — it is
        // read-only by construction, not merely "no more than" WatchDirectView's count.
        let debugButtonCount = debugSource.components(separatedBy: "Button").count - 1
        #expect(debugButtonCount == 0, "WatchDebugView must contain zero Button controls — read-only bench screen")
    }
}
