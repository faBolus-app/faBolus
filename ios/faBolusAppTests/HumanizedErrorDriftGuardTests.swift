import Testing
import Foundation
@testable import faBolus

/// **IN-02 (Phase 17 review) anti-drift pin.** `MainHUDView.humanizedDashboardError` and
/// `StatusRingView.humanized` each map ONLY a recognizable RAW error shape (Foundation's
/// "couldn't be completed. (<Domain> error <code>.)" boilerplate, a bare "domain#code " NSError
/// token, or an "Error Domain=" string) to one plain fallback sentence, and pass EVERY other string
/// through byte-identical. That's correct today because every CURATED `lastError`/`connectionDetail`
/// literal in the app was verified not to match those raw shapes. Nothing, however, stops a FUTURE
/// curated message from accidentally starting with `word#digits ` (e.g. a version-prefixed
/// "iOS17#3 …") and getting silently rewritten into the generic fallback — losing a real message.
///
/// This guard scans the production source for every literal `lastError = "…"` / `connectionDetail =
/// "…"` assignment and asserts none of them look "raw" (i.e. each passes through the humanizer
/// UNCHANGED). Modeled on `BandDriftGuardTests`/`BolusSuccessBannerDriftGuardTests`'s repo-root-walk +
/// comment-stripped source-scan idiom.
///
/// NOTE: the raw-shape regexes below are a DELIBERATE copy of the production humanizers'
/// (`MainHUDView.swift:238-244`, `StatusRingView.swift:140-146`) — those helpers are `private`, so a
/// direct call isn't reachable even under `@testable import`. If a humanizer's detection pattern is
/// ever changed, update the mirror here too (same intentional-duplication tradeoff as
/// `BandDriftGuardTests.forbiddenRawBandColors`). The `looksRaw*` self-checks below fail loudly if the
/// mirror stops matching a known raw shape, so a silently-broken copy is caught.
struct HumanizedErrorDriftGuardTests {

    // MARK: - Repo enumeration (mirrors BandDriftGuardTests' idiom)

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

    // MARK: - Mirrored raw-shape detection (see NOTE in the type doc comment)

    /// Mirrors `MainHUDView.humanizedDashboardError`'s three raw-shape checks.
    private static func looksRawDashboard(_ raw: String) -> Bool {
        raw.range(
            of: #"couldn.t be completed\. \([^)]*error -?\d+\.?\)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
            || raw.range(of: #"^\S+#-?\d+\s"#, options: .regularExpression) != nil
            || raw.contains("Error Domain=")
    }

    /// Mirrors `StatusRingView.humanized`'s single raw "domain#code " token check.
    private static func looksRawConnection(_ detail: String) -> Bool {
        detail.range(of: #"^\S+#-?\d+\s"#, options: .regularExpression) != nil
    }

    // MARK: - Non-vacuous self-checks (the mirror actually catches the raw shapes)

    @Test func mirrorMatchesKnownRawShapes() {
        #expect(Self.looksRawDashboard("The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"))
        #expect(Self.looksRawDashboard("CBErrorDomain#-42 something failed"))
        #expect(Self.looksRawDashboard("Error Domain=CBError Code=7"))
        #expect(Self.looksRawConnection("NSPOSIXErrorDomain#-1009 offline"))
        // A curated human sentence must NOT look raw under either matcher.
        #expect(!Self.looksRawDashboard("Bolus sent but outcome is unknown — verify on the pump before retrying."))
        #expect(!Self.looksRawConnection("Bluetooth is off"))
    }

    // MARK: - The anti-drift assertions

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
                !Self.looksRawDashboard(literal),
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
                !Self.looksRawConnection(literal),
                "curated connectionDetail copy \"\(literal)\" is rewritten by StatusRingView.humanized — it must pass through unchanged"
            )
        }
    }
}
