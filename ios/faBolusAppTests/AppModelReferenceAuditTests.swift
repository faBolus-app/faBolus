import Testing
import Foundation

/// Phase 16 GO-1 Step 0/1 (16-01 Task 2, CX-A-08) — the guard-test RETARGET MAP that 16-03/16-04
/// consume verbatim before carving `AppModel.swift` further. Enumerates every test file in
/// `ios/faBolusAppTests` that names the literal string `"AppModel.swift"`, and classifies each as
/// either:
///
///  - **ACTIVE-scan**: the file opens/reads `ios/faBolus/Data/AppModel.swift` AT RUNTIME (a
///    signature-located balanced-brace scan, or an `excludedFiles` allow-list keyed to that exact
///    filename) — a later carve that removes what it looks for, or that moves prose the allow-list
///    exists to tolerate, WILL make the test throw/fail (not vacuous-pass).
///  - **COMMENT-ONLY**: the file only cites `"AppModel.swift"` inside a doc comment or a
///    line-number pin — it never opens the file at runtime, so a carve/renumber cannot make it fail;
///    at worst the prose goes stale (an owner-review item, never a test break).
///
/// **Verified against source, not asserted from the plan's draft classification.** The 16-01 plan
/// listed `SleepScheduleWriteBoundaryTests` among the three ACTIVE files (grouping it with
/// `NudgeDeliveryBoundaryTests`/`LiveActivityAbsenceGuardTests` under "GO-1"); reading its source
/// shows its OWN active balanced-brace scan targets `ios/faBolus/Data/TandemBackend.swift`
/// (`setSleepSchedule`, a GO-2 concern) — its one `"AppModel.swift"` occurrence is a doc-comment
/// cross-reference to `NudgeDeliveryBoundaryTests`' Pitfall-1 note, never a runtime read of
/// `AppModel.swift`. This suite classifies it COMMENT-ONLY on the AppModel-reference axis (its
/// TandemBackend-axis activeness is `HistoryLogSyncDeliveryBoundaryTests`'/GO-2's concern, not
/// this one's) — see the 16-01 SUMMARY's "Deviations" section for the full note.
///
/// **16-04 update (Phase 16 GO-1 Step 4):** the carve retargeted `NudgeDeliveryBoundaryTests`'
/// balanced-function-body scan from `ios/faBolus/Data/AppModel.swift` to the new
/// `ios/faBolus/Data/AppModel+EatingNudge.swift` (per this file's own retarget instruction below,
/// discharged) — `eatingNudgeActedOn`/`updateEatingNudge`/`dismissEatingNudge` now live there. Its
/// remaining `"AppModel.swift"` occurrences are prose (explaining why `AppModel.swift` itself is
/// never whole-file-scanned, since `deliverBolus`/`remoteDeliver` are legitimately declared there),
/// never a runtime read of `AppModel.swift` — so `NudgeDeliveryBoundaryTests` reclassifies from
/// ACTIVE to COMMENT-ONLY on this file's specific axis, verified against its post-retarget source
/// (mirroring the `SleepScheduleWriteBoundaryTests` deviation note above, not merely asserted).
///
/// `CgmFailoverUiRefactorGuardTests` (scans `SettingsView`/`StatusView` for `CgmTestOutcome`) and
/// `CgmTestFlowStateTests` (drives the Test-flow state machine directly, never the view) were BOTH
/// read as 16-01 `<read_first>` context for 16-03 — neither contains the literal `"AppModel.swift"`
/// today, so neither appears in the enumeration below; they stay informational-only ahead of 16-03.
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

    // MARK: - The retarget map (verified against source — see the type doc comment)

    /// ACTIVE-scan: reads `ios/faBolus/Data/AppModel.swift` at runtime. A carve that MOVES the Live-
    /// Activity doc-comment prose currently tolerated by `AppModel.swift`'s presence in
    /// `LiveActivityAbsenceGuardTests`' `excludedFiles` allow-list MUST add the new file to that
    /// allow-list (else the moved prose trips the "no `ActivityKit` outside test files" scan). 16-04
    /// verified no such prose moved in this carve, so `LiveActivityAbsenceGuardTests` stays as-is.
    ///
    /// **16-04 D4-07 addition:** `NightscoutStubInertnessTests` reclassifies from COMMENT-ONLY to
    /// ACTIVE — its new `maybeBackfillNightscoutIsAbsentFromAppModel` test genuinely opens/reads
    /// `ios/faBolus/Data/AppModel.swift` at runtime (a zero-runtime-reference proof that the deleted
    /// `maybeBackfillNightscout`/`lastNSBackfill` symbols are gone), so it now carries the same
    /// `appendingPathComponent("ios/faBolus/Data/AppModel.swift")` marker as the other ACTIVE files.
    ///
    /// **16-04 Task 3 addition:** `AppModelAccessWideningGuardTests` (new in Task 3) is ACTIVE for the
    /// same reason — it opens `AppModel.swift` to source-scan the enumerated widened-property set.
    static let activeScanFiles: Set<String> = [
        "LiveActivityAbsenceGuardTests.swift",
        "NightscoutStubInertnessTests.swift",
        "AppModelAccessWideningGuardTests.swift",
    ]

    /// COMMENT-ONLY: cites `"AppModel.swift"` in a doc comment / line-number pin; never opens the
    /// file at runtime, so a carve/renumber inside `AppModel.swift` cannot make these fail.
    static let commentOnlyFiles: Set<String> = [
        "BackupRemovalBoundaryTests.swift",
        "DashboardSnapshotTests.swift",
        "DeliverySurfaceOutcomeGuardTests.swift",
        "LedgerBlockPrecedenceGuardTests.swift",
        "LedgerFaultReleaseGuardTests.swift",
        "MobiRejectAtPairingBoundaryTests.swift",
        "SettingsCatalogTests.swift",
        // Verified COMMENT-ONLY on the AppModel-reference axis — see the type doc comment's
        // deviation note; its own active scan targets TandemBackend.swift, a GO-2 concern.
        "SleepScheduleWriteBoundaryTests.swift",
        // 16-04 (Phase 16 GO-1 Step 4): reclassified from ACTIVE — its balanced-function-body scan
        // was retargeted to the new `AppModel+EatingNudge.swift` (the eating-nudge functions moved
        // there); its remaining `"AppModel.swift"` mentions are prose only. See the type doc
        // comment's "16-04 update" note.
        "NudgeDeliveryBoundaryTests.swift",
        // 17-04 (D3-01): its doc comment cites `AppModel.swift:1927-...` as a line-number pin
        // explaining where the truthful `lastError` string is already resolved — never opens the
        // file at runtime, so it is COMMENT-ONLY on this file's specific axis (17-10 classification
        // gap closure — this suite exists precisely to catch drift like this).
        "BolusOutcomeBannerTests.swift",
    ]

    /// Substrings that, if present in a FILE's source, indicate it opens/reads
    /// `ios/faBolus/Data/AppModel.swift` at runtime (a genuine active dependency on that file's
    /// on-disk shape) rather than merely naming it in prose.
    ///
    /// WR-02 approximation flag: this is a raw whole-source substring scan, NOT a comment-aware parse —
    /// a marker string appearing inside a doc comment (e.g. an example) would count as a runtime read.
    /// That residual is BOUNDED, not ignored: `markerCheckerDiscriminatesActiveFromCommentOnly` proves
    /// the checker isn't vacuous, and `commentOnlyFilesNeverOpenAppModelSwiftAtRuntime` fails loudly if
    /// any comment-only file contains a marker substring anywhere (prose included). Convention for future
    /// prose that must MENTION one of these idioms without being reclassified: break the literal (e.g.
    /// interleave backticks) so it cannot match verbatim.
    private static let activeRuntimeReadMarkers: [String] = [
        // A balanced-brace/function-body scan that builds the URL and reads the file (Nudge's idiom).
        "appendingPathComponent(\"ios/faBolus/Data/AppModel.swift\")",
        // LiveActivityAbsenceGuardTests' allow-list form — excludes the literal filename from a
        // repo-wide scan (an allow-list keyed to it, not a scan OF it, but equally "active": a carve
        // that relocates the tolerated prose needs this list extended).
        "excludedFiles: Set<String> = [\"AppModel.swift\"]",
    ]

    // MARK: - Tests

    /// The primary retarget-map assertion: every file that currently references `"AppModel.swift"`
    /// is classified into EXACTLY one of the two sets above — no unclassified drift in either
    /// direction. A NEW file starting to reference `AppModel.swift` without being added here, or an
    /// existing one stopping, fails loudly instead of silently falling out of the map 16-03/16-04
    /// depend on.
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
