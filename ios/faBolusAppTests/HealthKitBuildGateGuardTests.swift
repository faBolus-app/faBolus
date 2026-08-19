import Testing
import Foundation

/// Phase 09.23-01 (D-10/D-13): wiring guard for the `FABOLUS_HEALTHKIT` build-gate plumbing that
/// strips the paid HealthKit entitlement + usage strings + compile flag by default so a free
/// account / CI build still signs and stays green (CI parity). Mirrors
/// `CgmConfigSectionCopyGuardTests`'s `#filePath`-rooted walk-up resolve + naive line-comment strip
/// idiom (same documented limitation as that file's I-01 note: NOT string-literal aware — tolerable
/// here because the specific tokens scanned for never appear only inside a trailing comment).
struct HealthKitBuildGateGuardTests {

    // MARK: - Source resolution (mirrors CgmConfigSectionCopyGuardTests.repoRootURL)

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("scripts/generate-project.sh")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// NAIVE `#`-comment stripper for the shell script — truncates each line at its first `#`. NOT
    /// string-literal aware (the `strip_block`/`drop_flag` helper bodies embed `#` inside quoted awk
    /// patterns), which is fine here: the two literal calls this suite scans for
    /// (`strip_block HEALTHKIT` / `drop_flag FABOLUS_HEALTHKIT`) sit on their own simple lines, before
    /// any trailing `#`-comment, inside the generator's `if [ "$HEALTHKIT" = 0 ]` block — see the
    /// I-01 note on `CgmConfigSectionCopyGuardTests` for the same tradeoff applied to `//` comments.
    private static func stripShellComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "#") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    private static let generatorPath = "scripts/generate-project.sh"
    private static let specPath = "project.yml"

    // MARK: - Vacuous-pass file-resolution guards

    @Test func generatorSourceResolvesAndIsNonTrivial() throws {
        let source = try #require(Self.readSource(Self.generatorPath),
                                  "could not resolve \(Self.generatorPath) from #filePath=\(#filePath)")
        #expect(source.contains("#!/usr/bin/env bash"),
                "resolved file does not look like generate-project.sh — path resolution likely broke")
        #expect(source.count > 2000, "resolved source is implausibly short — path resolution likely broke")
    }

    @Test func specSourceResolvesAndIsNonTrivial() throws {
        let source = try #require(Self.readSource(Self.specPath),
                                  "could not resolve \(Self.specPath) from #filePath=\(#filePath)")
        #expect(source.contains("targets:"), "resolved file does not look like project.yml — path resolution likely broke")
        #expect(source.count > 2000, "resolved source is implausibly short — path resolution likely broke")
    }

    // MARK: - generate-project.sh wiring: strip_block + drop_flag calls exist

    @Test func generatorStripsHealthKitBlockAndDropsCompileFlag() throws {
        let raw = try #require(Self.readSource(Self.generatorPath))
        let code = Self.stripShellComments(raw)
        #expect(code.contains("strip_block HEALTHKIT"),
                "generate-project.sh must call strip_block HEALTHKIT to remove the entitlement/usage-string block(s) when FABOLUS_HEALTHKIT=0")
        #expect(code.contains("drop_flag FABOLUS_HEALTHKIT"),
                "generate-project.sh must call drop_flag FABOLUS_HEALTHKIT to drop the compile flag when FABOLUS_HEALTHKIT=0")
    }

    // MARK: - project.yml tagged-block wiring: entitlement + usage string sit between the markers

    /// Collects the concatenated body of every `# >>> HEALTHKIT` / `# <<< HEALTHKIT` block in
    /// project.yml. There are TWO in this phase — one wrapping the two entitlement keys, one
    /// wrapping `NSHealthUpdateUsageDescription` — mirroring how the DATA_PROTECTION tag wraps two
    /// separate blocks (one per iOS target) under a single `strip_block` call. Returns nil if no
    /// open/close pair is found at all (vacuous-pass guard).
    private static func healthKitTaggedBlockBodies(_ source: String) -> [String]? {
        var blocks: [String] = []
        var current: [String] = []
        var inBlock = false
        var sawAnyBlock = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("# >>> HEALTHKIT") { inBlock = true; sawAnyBlock = true; current = []; continue }
            if line.contains("# <<< HEALTHKIT") { inBlock = false; blocks.append(current.joined(separator: "\n")); continue }
            if inBlock { current.append(String(line)) }
        }
        return sawAnyBlock ? blocks : nil
    }

    @Test func specHasHealthKitTaggedBlockWrappingEntitlementAndUsageString() throws {
        let source = try #require(Self.readSource(Self.specPath))
        #expect(source.contains("# >>> HEALTHKIT"), "project.yml missing the `# >>> HEALTHKIT` open marker")
        #expect(source.contains("# <<< HEALTHKIT"), "project.yml missing the `# <<< HEALTHKIT` close marker")
        let blocks = try #require(Self.healthKitTaggedBlockBodies(source),
                                  "no `# >>> HEALTHKIT` / `# <<< HEALTHKIT` block found")
        let combined = blocks.joined(separator: "\n")
        #expect(combined.contains("com.apple.developer.healthkit: true"),
                "the com.apple.developer.healthkit entitlement key must sit inside a # >>> HEALTHKIT / # <<< HEALTHKIT block")
        #expect(combined.contains("com.apple.developer.healthkit.access"),
                "the com.apple.developer.healthkit.access entitlement key must sit inside a # >>> HEALTHKIT / # <<< HEALTHKIT block")
        #expect(combined.contains("NSHealthUpdateUsageDescription"),
                "NSHealthUpdateUsageDescription must sit inside a # >>> HEALTHKIT / # <<< HEALTHKIT block so it strips in lockstep with the entitlement")
    }

    // MARK: - Compile-flag reaches both the app target and the test target (independent conditions)

    @Test func specAddsHealthKitFlagToAppAndTestTargets() throws {
        let source = try #require(Self.readSource(Self.specPath))
        let compileConditionLines = source.components(separatedBy: "\n").filter { $0.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS") }
        #expect(!compileConditionLines.isEmpty, "path resolution broke — found zero SWIFT_ACTIVE_COMPILATION_CONDITIONS lines")
        let withFlag = compileConditionLines.filter { $0.contains("FABOLUS_HEALTHKIT") }
        // faBolus Debug + Release + the faBolusAppTests target's own line == 3 (each target's compile
        // conditions are independent in xcodegen — the 09.5 FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL precedent).
        #expect(withFlag.count >= 3,
                "FABOLUS_HEALTHKIT must appear on the faBolus Debug + Release SWIFT_ACTIVE_COMPILATION_CONDITIONS lines AND the faBolusAppTests target's line (found \(withFlag.count) of \(compileConditionLines.count) total lines)")
    }
}
