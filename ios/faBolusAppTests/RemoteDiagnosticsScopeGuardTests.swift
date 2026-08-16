import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.6-07 (Task 2, D-03.1, D-04, T-09.6-06): makes the "the new `.diagnosticsRead` wire member
/// is provably delivery-inert" rule self-enforcing, modeled on `WatchDirectBleScopeGuardTests`'
/// `#filePath`-rooted source scan technique.
///
/// (a) Type-level: `.diagnosticsRead` is non-mutating + non-freshness-sensitive, and the FULL
/// exhaustive mutating-kind set (via `RemoteCommand.Kind.allCases`, added in this plan) equals a
/// pinned baseline that does NOT contain `.diagnosticsRead` — any future widening of the
/// `mutatesPumpState` true-branch turns this guard RED.
///
/// (b) Handler-body scope: `PhoneRemoteHost.swift`'s `.diagnosticsRead` case region is resolved by a
/// `#filePath`-rooted repo-root walk and scanned for the text-store accessor (must be present) and
/// every dose/control/dismiss entry point + an async `Task` launch + a status re-push (must be
/// absent).
///
/// (c) Integration: `DebugMenuView.swift` actually wires the `[Watch self]` section into the ordered
/// `sections` array (source scan) — proves the ninth surface isn't merely built but reachable.
struct RemoteDiagnosticsScopeGuardTests {

    // MARK: - (a) Type-level inertness

    /// Pinned from `RemoteCommand.Kind`'s `mutatesPumpState` true branch as it stood going INTO this
    /// plan (unchanged by it) — `.diagnosticsRead` is added to the FALSE branch, so this set is
    /// untouched. Any future case moved into the true branch, or added there, turns this RED.
    private static let pinnedMutatingBaseline: Set<RemoteCommand.Kind> = [
        .bolusRequest, .bolusConfirm, .cancelBolus, .suspendPump, .resumePump,
        .dismissAlert, .bolusApprovalRequest, .bolusApprovalResponse, .sealed,
    ]

    @Test func diagnosticsReadIsInertAndExhaustiveMutatingSetMatchesPinnedBaseline() {
        #expect(RemoteCommand.Kind.diagnosticsRead.mutatesPumpState == false)
        #expect(RemoteCommand.Kind.diagnosticsRead.isFreshnessSensitive == false)

        let actualMutating = Set(RemoteCommand.Kind.allCases.filter { $0.mutatesPumpState })
        #expect(actualMutating == Self.pinnedMutatingBaseline,
                "the exhaustive mutating-kind set drifted from the pinned baseline")
        #expect(!actualMutating.contains(.diagnosticsRead),
                ".diagnosticsRead must never be classified as pump-mutating")
    }

    // MARK: - Source resolution (mirrors WatchDirectBleScopeGuardTests.repoRootURL)

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/RemoteDiagnosticsScopeGuardTests.swift`) until `ios/faBolus/Data`
    /// exists.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Data")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - (b) Handler-body scope

    /// Extracts the source between a `case <label>:` line and the NEXT `case `/`default:` at the same
    /// (8-space) indentation — i.e. everything that case body actually executes, no more.
    private static func caseRegion(in source: String, caseLabel: String) -> String? {
        guard let labelRange = source.range(of: "case \(caseLabel):") else { return nil }
        let after = source[labelRange.upperBound...]
        var endIndex = after.endIndex
        for terminator in ["\n        case ", "\n        default:"] {
            if let r = after.range(of: terminator), r.lowerBound < endIndex { endIndex = r.lowerBound }
        }
        return String(after[..<endIndex])
    }

    @Test func diagnosticsReadHandlerCaseRegionIsDoseFree() throws {
        guard let source = Self.readSource("ios/faBolus/Data/PhoneRemoteHost.swift") else {
            Issue.record("could not resolve ios/faBolus/Data/PhoneRemoteHost.swift from #filePath=\(#filePath)")
            return
        }
        guard let region = Self.caseRegion(in: source, caseLabel: ".diagnosticsRead") else {
            Issue.record("could not find a `.diagnosticsRead` case region in PhoneRemoteHost.swift")
            return
        }
        #expect(region.contains("lastWatchDiagnosticsText"),
                "the .diagnosticsRead case must store the received text")
        let forbidden = [
            "model.remoteDeliver", "model.cancelBolus", "model.dismissAlert",
            "model.requestRemoteControl", "Task {", "Task{", "sendTracked", "statusCommand",
        ]
        for token in forbidden {
            #expect(!region.contains(token),
                    "the .diagnosticsRead case must not reference \(token) — dose/delivery/control-free (D-04)")
        }
    }

    // MARK: - (c) Integration: reachable from the aggregated bundle

    @Test func debugMenuViewWiresWatchSelfSectionIntoOrderedSectionsArray() throws {
        guard let source = Self.readSource("ios/faBolus/Views/DebugMenuView.swift") else {
            Issue.record("could not resolve ios/faBolus/Views/DebugMenuView.swift from #filePath=\(#filePath)")
            return
        }
        #expect(source.contains("WatchSelfDiagnostics.phoneSection"),
                "DebugMenuView's ordered sections array must include the [Watch self] section")
        #expect(source.contains("requestWatchDiagnostics"),
                "DebugMenuView must request the watch's diagnostics (gated on the shared opt-in)")
        // D-02: no second export mechanism introduced alongside the new section. `fileExporter(` (an
        // actual API call, not just the word) avoids a false positive on the pre-existing "No
        // .fileExporter/BackupDocument save" negation comment a few lines above the ShareLink.
        for forbidden in ["fileExporter(", "Compression", "Archive", ".zip"] {
            #expect(!source.contains(forbidden), "no new export mechanism may be introduced (D-02): \(forbidden)")
        }
    }
}
