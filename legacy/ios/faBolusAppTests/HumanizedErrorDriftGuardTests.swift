import Testing
import Foundation
@testable import faBolus

/// Curated `lastError` / `connectionDetail` literals must pass through the dashboard/connection
/// humanizers unchanged, or a real message is silently rewritten into a generic fallback. This suite
/// calls the REAL production humanizers (`DashboardView.humanizedDashboardError`,
/// `StatusRingView.humanized`) directly — there is no hand-kept copy to drift from them — so it goes
/// red the moment production starts rewriting a curated case into its fallback.
struct HumanizedErrorDriftGuardTests {

    // MARK: - Repo enumeration

    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("project.yml")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Strip `//`-style line comments (including `///` doc comments) so a doc comment that
    /// legitimately quotes a curated `lastError = "…"` string in prose isn't scanned as a real
    /// assignment. Same technique as `BandDriftGuardTests.stripLineComments`.
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let idx = line.range(of: "//") { return String(line[..<idx.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent(relativePath)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return Self.stripLineComments(raw)
    }

    /// Extract every `<assignee> = "…"` string LITERAL from `source`, skipping interpolated
    /// assignments (`= "\(…)"`) — those are the dynamic NSError-derived fallbacks the humanizers are
    /// SUPPOSED to rewrite, not curated copy that must survive unchanged.
    private static func literals(assignedTo assignee: String, in source: String) -> [String] {
        let pattern = assignee + #"\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        var out: [String] = []
        re.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let literal = ns.substring(with: match.range(at: 1))
            if literal.contains(#"\("#) { return }  // interpolated dynamic fallback — not curated copy
            out.append(literal)
        }
        return out
    }

    // MARK: - Non-vacuous self-check (the humanizers actually rewrite raw shapes, and only raw shapes)

    /// Anti-vacuity: a real NSError-shaped string MUST be rewritten (so the pass-through assertions
    /// below are meaningful — they aren't trivially true because the humanizers never rewrite), and a
    /// curated human sentence MUST pass through unchanged (the anti-misinformation invariant).
    @Test func productionHumanizersRewriteRawShapesButPreserveCuratedCopy() {
        for raw in [
            "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)",
            "CBErrorDomain#-42 something failed",
            "Error Domain=CBError Code=7"
        ] {
            #expect(
                DashboardView.humanizedDashboardError(raw) != raw,
                "raw shape \"\(raw)\" must be rewritten by humanizedDashboardError, not left verbatim")
        }
        #expect(
            StatusRingView.humanized("NSPOSIXErrorDomain#-1009 offline") != "NSPOSIXErrorDomain#-1009 offline",
            "a raw domain#code detail must be rewritten by StatusRingView.humanized")

        // A curated human sentence must NOT be rewritten under either humanizer.
        let curatedDashboard = "Bolus sent but outcome is unknown — verify on the pump before retrying."
        #expect(DashboardView.humanizedDashboardError(curatedDashboard) == curatedDashboard)
        #expect(StatusRingView.humanized("Bluetooth is off") == "Bluetooth is off")
    }

    // MARK: - The anti-drift assertions (curated copy survives the real humanizer)

    @Test func curatedLastErrorLiteralsPassThroughDashboardHumanizerUnchanged() throws {
        var literals: [String] = []
        for file in [
            "ios/faBolus/Data/AppModel.swift",
            "ios/faBolus/Data/App/PumpConnectionLifecycle.swift"
        ] {
            literals += Self.literals(assignedTo: "lastError", in: try Self.source(file))
        }
        #expect(
            !literals.isEmpty,
            "scan found no curated `lastError = \"…\"` literals — the source path or extractor broke")
        for literal in literals {
            #expect(
                DashboardView.humanizedDashboardError(literal) == literal,
                "curated lastError copy \"\(literal)\" is rewritten by humanizedDashboardError — it must pass through unchanged"
            )
        }
    }

    @Test func curatedConnectionDetailLiteralsPassThroughHumanizerUnchanged() throws {
        var literals: [String] = []
        for file in [
            "ios/faBolus/Data/App/PumpConnectionLifecycle.swift",
            "ios/faBolus/Data/TandemBackend.swift"
        ] {
            literals += Self.literals(assignedTo: "connectionDetail", in: try Self.source(file))
        }
        #expect(
            !literals.isEmpty,
            "scan found no curated `connectionDetail = \"…\"` literals — the source path or extractor broke")
        for literal in literals {
            #expect(
                StatusRingView.humanized(literal) == literal,
                "curated connectionDetail copy \"\(literal)\" is rewritten by StatusRingView.humanized — it must pass through unchanged"
            )
        }
    }
}
