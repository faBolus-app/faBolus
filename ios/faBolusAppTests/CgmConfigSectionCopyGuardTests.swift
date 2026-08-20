import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.22-05 (Task 1, D-11 / D-14): pins that EVERY failover source has a discoverable config
/// section in `CgmCredentialsView`, and that the sources that previously had none — Dexcom G7 and
/// Apple Health (HealthKit) — carry their required precondition copy. (The xDrip App Group section's
/// own copy-presence tests were removed with the source in Phase 1, Plan 01 — CGM-05; the core
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
        #expect(CgmCredentialsView.configuredSectionSourceIds == registryIds,
                "configuredSectionSourceIds must cover exactly the registry sources; diff: \(CgmCredentialsView.configuredSectionSourceIds.symmetricDifference(registryIds))")
        // The D-11 additions that remain on `main` must specifically be present. "healthkit" only
        // exists in the registry (and this required set) when FABOLUS_HEALTHKIT is ON (D-13, Phase
        // 09.23) — under OFF neither side has it, so the equality check above already covers that
        // state. "xdrip-appgroup" was removed in Phase 1, Plan 01 (CGM-05).
        var requiredIds = ["dexcom-g7-ble"]
        #if FABOLUS_HEALTHKIT
        requiredIds.append("healthkit")
        #endif
        for id in requiredIds {
            #expect(CgmCredentialsView.configuredSectionSourceIds.contains(id),
                    "missing D-11 config section for \(id)")
        }
    }

    // MARK: - Vacuous-pass file-resolution guard

    @Test func credentialsViewSourceResolvesAndIsNonTrivial() throws {
        let source = try #require(Self.readSource(Self.credentialsViewPath),
                                  "could not resolve \(Self.credentialsViewPath) from #filePath=\(#filePath)")
        #expect(source.contains("struct CgmCredentialsView"),
                "resolved file does not look like CgmCredentialsView.swift — path resolution likely broke")
        #expect(source.count > 2000, "resolved source is implausibly short — path resolution likely broke")
    }

    // MARK: - Required precondition copy for the three new sections (non-comment code)

    @Test func g7SectionCarriesKeepDexcomAppAndFirstReadingTimingCopy() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        #expect(code.contains("Read from Dexcom app"), "G7 section missing its mode explainer")
        #expect(code.contains("Keep the official Dexcom app installed, paired, and running"),
                "G7 section missing the keep-the-Dexcom-app-running precondition")
        #expect(code.contains("up to ~5 minutes"), "G7 section missing the ~5-min first-reading timing")
    }

    // D-13 (Phase 09.23): the healthKit-specific copy expectation is scoped to the FABOLUS_HEALTHKIT
    // ON build, matching the "healthkit" id being scoped to that same flag in the loop above — the
    // whole HealthKit config-section surface is treated as inert under OFF for this guard suite.
    #if FABOLUS_HEALTHKIT
    @Test func healthKitSectionCarriesPermissionRecoveryAndPrerequisiteCopy() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        #expect(code.contains("permission"), "HealthKit section missing the permission-request explanation")
        #expect(code.contains("iOS Settings"), "HealthKit section missing the iOS-Settings recovery guidance")
        #expect(code.contains("another app") && code.contains("writing glucose to Apple Health"),
                "HealthKit section missing the 'another app must be writing glucose to Health' prerequisite")
    }

    // Phase 09.23-03 (D-08/D-12/D-14): the section must now truthfully advertise the per-type
    // EXPORT capability (it shipped this plan) and must no longer carry the stale "faBolus only
    // reads — it never writes glucose" claim that predates the export feature.
    @Test func healthKitSectionAdvertisesExportAndDropsTheStaleReadOnlyClaim() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        #expect(code.contains("Export to Apple Health"),
                "HealthKit section missing a discoverable export-capability header/copy")
        #expect(code.contains("WRITE your carb, insulin, and glucose entries") || code.contains("write your carb, insulin, and glucose entries"),
                "HealthKit section missing copy describing WHAT faBolus exports")
        #expect(!code.contains("faBolus only reads") && !code.contains("it never writes glucose"),
                "HealthKit section still carries the stale pre-export 'only reads, never writes' claim")
    }

    // The per-type import/export toggle rows (D-14) must be bound to the corresponding AppSettings
    // properties — every enabled type is individually user-selectable, and no HR export row exists
    // (D-08).
    @Test func healthKitSectionBindsEveryPerTypeToggleAndHasNoHeartRateExportRow() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        let expectedImportBindings = [
            "$settings.healthKitImportCarbsEnabled",
            "$settings.healthKitImportInsulinEnabled",
            "$settings.healthKitImportHeartRateEnabled",
            "$settings.healthKitImportGlucoseEnabled",
            "$settings.healthKitAutoImportEnabled",
        ]
        let expectedExportBindings = [
            "$settings.healthKitExportCarbsEnabled",
            "$settings.healthKitExportInsulinEnabled",
            "$settings.healthKitExportGlucoseEnabled",
            "$settings.healthKitAutoExportEnabled",
        ]
        for binding in expectedImportBindings + expectedExportBindings {
            #expect(code.contains(binding), "HealthKit section missing the toggle row bound to \(binding)")
        }
        #expect(!code.contains("healthKitExportHeartRate"),
                "D-08 violated — no heart-rate EXPORT toggle/row may exist; HR is read-only")
    }
    #endif
}
