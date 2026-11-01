import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Every `GlucoseSourceRegistry` source must have a `CgmCredentialsView` config section so a source
/// with a hard precondition cannot be selected with no explainer. `stripLineComments` is not
/// string-literal-aware; that is acceptable here because none of the asserted phrases contain `//`.
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

    /// Naive line-comment strip — not string-literal-aware; acceptable here because none of the
    /// asserted phrases contain `//`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private static let credentialsViewPath = "ios/faBolus/Views/CgmCredentialsView.swift"

    // MARK: - Every registry source has a config section (behavioral, not a text scan)

    /// The view's declared section-coverage set must equal the full `GlucoseSourceRegistry` id set.
    /// Adding a registry source without a section — or dropping a section — turns this red.
    @Test func everyRegistrySourceHasAConfigSection() {
        let registryIds = Set(GlucoseSourceRegistry.enabled.map(\.id))
        #expect(
            CgmCredentialsView.configuredSectionSourceIds == registryIds,
            "configuredSectionSourceIds must cover exactly the registry sources; diff: \(CgmCredentialsView.configuredSectionSourceIds.symmetricDifference(registryIds))"
        )
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
}
