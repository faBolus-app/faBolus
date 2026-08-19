import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.22-05 (Task 1, D-11 / D-14): pins that EVERY failover source has a discoverable config
/// section in `CgmCredentialsView`, and that the three that previously had none — Dexcom G7,
/// Apple Health (HealthKit), and the xDrip App Group — carry their required precondition copy. The
/// xDrip self-compile / same-Team-ID caveat must be an UNMISSABLE gate (a warning-styled banner in the
/// section content), not a buried footer (CRIT F-01). Mirrors `WatchDirectBleScopeGuardTests`'
/// `#filePath`-rooted source scan (no simulator, no live source).
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
        // The three D-11 additions must specifically be present. "healthkit" only exists in the
        // registry (and this required set) when FABOLUS_HEALTHKIT is ON (D-13, Phase 09.23) — under
        // OFF neither side has it, so the equality check above already covers that state.
        var requiredIds = ["dexcom-g7-ble", "xdrip-appgroup"]
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
    #endif

    @Test func xdripSectionCarriesSelfCompileTeamIdGate() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        #expect(code.contains("Self-compile only"), "xDrip section missing the self-compile-only caveat")
        #expect(code.contains("same Apple Team ID") || code.contains("SAME Apple Team ID"),
                "xDrip section missing the same-Apple-Team-ID caveat")
    }

    /// CRIT F-01: the xDrip caveat must be an UNMISSABLE gate — presented with a warning treatment in
    /// the section CONTENT (a warning icon), not tucked into a plain-text footer. We assert both the
    /// caveat text and a warning icon are present, and that the caveat appears BEFORE the section's
    /// `footer:` label (i.e. it is content, not footer).
    @Test func xdripSelfCompileCaveatIsAnUnmissableGateNotABuriedFooter() throws {
        let code = Self.stripLineComments(try #require(Self.readSource(Self.credentialsViewPath)))
        #expect(code.contains("exclamationmark.triangle"),
                "xDrip self-compile gate must use a warning icon (unmissable), not a plain footer")
        // Anchor on the section's definition. In a SwiftUI `Section { content } header: {} footer: {}`
        // the CONTENT is emitted first in source, so the caveat must appear AFTER the section opens and
        // BEFORE its `footer:` label — i.e. it is warning-styled section content, not a buried footer.
        guard let defRange = code.range(of: "xdripAppGroupConfigSection: some View") else {
            Issue.record("could not locate the xDrip App Group section definition in the source")
            return
        }
        let sectionBody = code[defRange.upperBound...]
        let caveatIdx = sectionBody.range(of: "Self-compile only")?.lowerBound
        let footerIdx = sectionBody.range(of: "footer:")?.lowerBound
        #expect(caveatIdx != nil, "xDrip self-compile caveat not found in the section content")
        #expect(footerIdx != nil, "xDrip section has no footer label — section structure changed")
        if let caveatIdx, let footerIdx {
            #expect(caveatIdx < footerIdx,
                    "xDrip self-compile caveat sits in the footer — it must be unmissable section content")
        }
    }
}
