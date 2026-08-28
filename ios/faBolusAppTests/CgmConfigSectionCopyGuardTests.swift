import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.22-05 (Task 1, D-11 / D-14): pins that EVERY failover source has a discoverable config
/// section in `CgmCredentialsView`, and that the sources that previously had none — Dexcom G7 and
/// Apple Health (HealthKit) — carry their required precondition copy. (The G7 copy-presence test was
/// removed with the source in Phase 1, Plan 03 — CGM-01/CGM-02; the xDrip App Group section's own
/// copy-presence tests were removed with the source in Phase 1, Plan 01 — CGM-05; the core
/// `configuredSectionSourceIds == registryIds` equality assertion below still covers the shrunk set.)
/// Mirrors `WatchDirectBleScopeGuardTests`' `#filePath`-rooted source scan (no simulator, no live source).
///
/// **I-01 (D-14) — `stripLineComments` limitation.** The helper below is a NAIVE line-comment stripper:
/// it truncates each line at the first `//` and is NOT string-literal aware, so a `//` inside a Swift
/// string literal (e.g. a URL like "https://…") would be wrongly truncated. That is acceptable HERE
/// because (a) none of the asserted precondition phrases contain `//`, and (b) the strip only exists so
/// a phrase that survives ONLY inside a `//` comment can't pass a presence check vacuously. A future
/// guard that must assert on URL-bearing copy needs a string-literal-aware scan instead (or a shared
/// test-support helper) — do not copy this stripper for that purpose.
@MainActor
struct CgmConfigSectionCopyGuardTests {

    // MARK: - Source resolution (mirrors WatchDirectBleScopeGuardTests.repoRootURL)

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("ios/faBolus/Views/CgmCredentialsView.swift")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// NAIVE line-comment strip — see the I-01 note in the type doc-comment for the string-literal
    /// limitation and why it's tolerable for these specific presence checks.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private static let credentialsViewPath = "ios/faBolus/Views/CgmCredentialsView.swift"

    // MARK: - Every registry source has a config section (behavioral, not a text scan)

    /// The strongest, non-vacuous form of D-11: the view's declared section-coverage set MUST equal the
    /// full `GlucoseSourceRegistry` id set. Adding a registry source without a section — or dropping a
    /// section — turns this RED. No source with a hard precondition can be selectable with no explainer.
    @Test func everyRegistrySourceHasAConfigSection() {
        let registryIds = Set(GlucoseSourceRegistry.enabled.map(\.id))
        #expect(
            CgmCredentialsView.configuredSectionSourceIds == registryIds,
            "configuredSectionSourceIds must cover exactly the registry sources; diff: \(CgmCredentialsView.configuredSectionSourceIds.symmetricDifference(registryIds))"
        )
        // HealthKit ("healthkit") was removed from narrow `main` in Phase 5 (HEALTH-01); Nightscout
        // ("nightscout") was removed from narrow `main` in Phase 5 (HEALTH-02) — both sides of the
        // equality check above are now Share-only, with no D-11 required-id set left to assert.
        // "dexcom-g7-ble" was removed in Phase 1, Plan 03 (CGM-01/CGM-02); "xdrip-appgroup" was
        // removed in Phase 1, Plan 01 (CGM-05).
    }

    // MARK: - Vacuous-pass file-resolution guard

    @Test func credentialsViewSourceResolvesAndIsNonTrivial() throws {
        let source = try #require(
            Self.readSource(Self.credentialsViewPath),
            "could not resolve \(Self.credentialsViewPath) from #filePath=\(#filePath)")
        #expect(
            source.contains("struct CgmCredentialsView"),
            "resolved file does not look like CgmCredentialsView.swift — path resolution likely broke")
        #expect(source.count > 2000, "resolved source is implausibly short — path resolution likely broke")
    }

    // MARK: - Required precondition copy for the remaining new section (non-comment code)
    //
    // The G7 copy-presence test (g7SectionCarriesKeepDexcomAppAndFirstReadingTimingCopy) was deleted
    // here in Phase 1, Plan 03 (CGM-01/CGM-02) along with the g7ConfigSection it pinned. The
    // HealthKit-specific copy-presence tests (healthKitSectionCarriesPermissionRecoveryAndPrerequisiteCopy,
    // healthKitSectionAdvertisesExportAndDropsTheStaleReadOnlyClaim,
    // healthKitSectionBindsEveryPerTypeToggleAndHasNoHeartRateExportRow) were deleted here in Phase 5
    // (HEALTH-01) along with the healthKitConfigSection they pinned — see dev/healthkit's
    // REINTEGRATION.md.
}
