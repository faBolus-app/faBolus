import Testing
import Foundation

/// Classifies which tests open `AppModel.swift` at runtime versus only naming it in comments, so a
/// carve that moves dose-path code cannot silently drop a scanner.
struct AppModelReferenceAuditTests {

    // MARK: - Repo/file resolution (mirrors CiqAwarenessScopeGuardTests' idiom)

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

    private static func testsDirURL() throws -> URL {
        let root = try #require(Self.repoRootURL())
        return root.appendingPathComponent("ios/faBolusAppTests")
    }

    private static func readSource(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file directly under `ios/faBolusAppTests` (non-recursive — the target has no
    /// subdirectories today) whose source contains the literal string `"AppModel.swift"`, EXCLUDING
    /// this audit file itself (which necessarily names the string many times in its own prose).
    private static func filesReferencingAppModelSwift() throws -> Set<String> {
        let dir = try Self.testsDirURL()
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var out: Set<String> = []
        for url in entries where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard name != "AppModelReferenceAuditTests.swift" else { continue }
            guard let source = Self.readSource(url) else { continue }
            if source.contains("AppModel.swift") { out.insert(name) }
        }
        return out
    }

    // MARK: - Runtime vs comment-only classification

    /// These files open `AppModel.swift` at runtime. A carve that moves scanned prose must update them.
    static let activeScanFiles: Set<String> = [
        "LiveActivityAbsenceGuardTests.swift",
        "NightscoutStubInertnessTests.swift",
        "AppModelAccessWideningGuardTests.swift",
        "HumanizedErrorDriftGuardTests.swift",
    ]

    /// These files only name `AppModel.swift` in comments; they never open it, so a carve cannot
    /// make them fail.
    static let commentOnlyFiles: Set<String> = [
        "DashboardSnapshotTests.swift",
        "DeliverySurfaceOutcomeGuardTests.swift",
        "LedgerBlockPrecedenceGuardTests.swift",
        "LedgerFaultReleaseGuardTests.swift",
        "MobiRejectAtPairingBoundaryTests.swift",
        "SleepScheduleWriteBoundaryTests.swift",
        "NudgeDeliveryBoundaryTests.swift",
        "BolusOutcomeBannerTests.swift",
    ]

    /// Substrings that mean a file actually reads `AppModel.swift` rather than only naming it.
    /// This is a raw substring scan, not a comment-aware parse — break the literal in prose that
    /// must mention a marker without being reclassified.
    private static let activeRuntimeReadMarkers: [String] = [
        "appendingPathComponent(\"ios/faBolus/Data/AppModel.swift\")",
        "excludedFiles: Set<String> = [\"AppModel.swift\"]",
        "\"ios/faBolus/Data/AppModel.swift\"",
    ]

    // MARK: - Tests

    /// Every file that names `"AppModel.swift"` must sit in exactly one of the two sets above.
    @Test func everyAppModelReferencingFileIsClassified() throws {
        let found = try Self.filesReferencingAppModelSwift()
        let classified = Self.activeScanFiles.union(Self.commentOnlyFiles)

        let unclassified = found.subtracting(classified)
        #expect(unclassified.isEmpty,
                "New AppModel.swift-referencing file(s) not yet classified in the 16-01 retarget map: \(unclassified.sorted())")

        let noLongerReferencing = classified.subtracting(found)
        #expect(noLongerReferencing.isEmpty,
                "Classified file(s) no longer reference AppModel.swift — retarget map is stale: \(noLongerReferencing.sorted())")

        // A path-resolution bug (e.g. `ios/faBolusAppTests` not found) must fail loudly, not pass
        // vacuously with zero files found.
        #expect(found.count >= 10, "fewer AppModel.swift references were found than the phase currently ships — path resolution likely broke")
    }

    /// Every file classified ACTIVE must actually contain one of the runtime-read markers — proving
    /// the classification is verified against source, not asserted from prose alone.
    @Test func activeScanFilesActuallyReadAppModelSwiftAtRuntime() throws {
        let dir = try Self.testsDirURL()
        for name in Self.activeScanFiles {
            let source = try #require(Self.readSource(dir.appendingPathComponent(name)),
                                      "could not read \(name)")
            let hasMarker = Self.activeRuntimeReadMarkers.contains { source.contains($0) }
            #expect(hasMarker, "\(name) is classified ACTIVE but contains none of the known runtime-read markers — reclassify or update the marker list")
        }
    }

    /// Every file classified COMMENT-ONLY must contain NEITHER runtime-read marker — proving these
    /// are genuinely inert on a carve, not just asserted so.
    @Test func commentOnlyFilesNeverOpenAppModelSwiftAtRuntime() throws {
        let dir = try Self.testsDirURL()
        for name in Self.commentOnlyFiles {
            let source = try #require(Self.readSource(dir.appendingPathComponent(name)),
                                      "could not read \(name)")
            let hasMarker = Self.activeRuntimeReadMarkers.contains { source.contains($0) }
            #expect(!hasMarker, "\(name) is classified COMMENT-ONLY but contains a runtime-read marker — it actually IS an active scan; reclassify")
        }
    }

    /// Fault-injection proof for the marker-based checker itself (mirrors `CiqAwarenessScopeGuardTests`'
    /// idiom): a synthetic source string containing a runtime-read marker must be detected, and one
    /// that only cites the filename in prose must not — proving the checker discriminates instead of
    /// vacuously agreeing with whatever it's handed.
    @Test func markerCheckerDiscriminatesActiveFromCommentOnly() {
        let activeLike = "let url = repoRoot.appendingPathComponent(\"ios/faBolus/Data/AppModel.swift\")\nlet source = try String(contentsOf: url)"
        let commentLike = "/// See `AppModel.swift:1327` for the one dependency this carve must not break."
        #expect(Self.activeRuntimeReadMarkers.contains { activeLike.contains($0) })
        #expect(!Self.activeRuntimeReadMarkers.contains { commentLike.contains($0) })
    }
}
