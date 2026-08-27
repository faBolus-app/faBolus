import Testing
import Foundation

/// Phase 16 GO-1 Step 4 (16-04 Task 3, REMED-16, review concern #1 / suggestion #2) — the
/// source-scan guard proving the `private`->`internal` access-widening this carve required (a
/// separate-file `extension AppModel` cannot declare stored properties and cannot see a `private`
/// member of the type it extends) is EXACTLY the enumerated advisory set below — no more, no fewer
/// — and, critically, that NO dose/gate member was ever included.
///
/// **Baseline fact this guard depends on (verified, not assumed):** before Phase 16 (`git show
/// 0da3867:ios/faBolus/Data/AppModel.swift`, the 16-01 tracer commit, close to the pre-phase
/// baseline), `AppModel.swift` contained ZERO stored-property declarations using the explicit
/// `internal` keyword — every property was either `private`/`private(set)`/`public` or had no
/// modifier at all (Swift's own default, which is *already* `internal` and needs no keyword). That
/// means every literal `internal var`/`internal let`/`internal lazy var` occurrence in the CURRENT
/// `AppModel.swift` is attributable to this carve's widening, with no baseline noise to filter out —
/// a plain substring scan is a genuine, non-vacuous proof, not an approximation.
struct AppModelAccessWideningGuardTests {

    // MARK: - Repo/file resolution (mirrors AppModelReferenceAuditTests' idiom)

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

    private static func appModelSource() throws -> String {
        let root = try #require(Self.repoRootURL(), "could not resolve repo root from #filePath")
        let url = root.appendingPathComponent("ios/faBolus/Data/AppModel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Phase 16 GO-1 Step 5 (16-05, CX-A-08 retarget): `lastPersistedGlucoseKeys`/
    /// `lastPersistedBolusKeys` moved OUT of `AppModel.swift` entirely, into their own dedicated
    /// `HistoryPersistenceCoordinator` — not a same-type widening, so the ORIGINAL scan target
    /// (`AppModel.swift`) can never find them again and would otherwise vacuous-pass. Retargeted here
    /// per the source-text guard-retargeting rule (verify against actual source, not the plan's draft).
    private static func historyPersistenceCoordinatorSource() throws -> String {
        let root = try #require(Self.repoRootURL(), "could not resolve repo root from #filePath")
        let url = root.appendingPathComponent("ios/faBolus/Data/App/HistoryPersistenceCoordinator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The enumerated widened set (verified against source — see 16-04 SUMMARY)

    /// The EXACT 17 stored-property declarations widened `private`->`internal` by this carve, held as
    /// their exact declaration-line substrings (not bare property names) so the check is precise and
    /// cannot accidentally match an unrelated occurrence of the same word elsewhere in the file.
    ///
    /// IN-01 caveat: `"internal var history: GlucoseHistoryStore?"` was a *stored* property when 16-04
    /// widened it, but 16-05 (one plan later, same phase) turned `history` into a *computed* property
    /// (`internal var history: GlucoseHistoryStore? { historyPersistence.store }`). The `source.contains`
    /// substring match below still holds because the computed declaration line starts with the identical
    /// prefix — so this array's name ("stored-property") is inaccurate for this one entry only. The guard
    /// is still proving the `private`->`internal` visibility survives; it is NOT proving stored-vs-computed.
    static let widenedStoredPropertyDeclarations: [String] = [
        "internal var history: GlucoseHistoryStore?",
        "internal var eatingEngine = EatingTriggerEngine(",
        "internal var lastEatingConfig: Data?",
        "internal let mealDetector = MealDetector()",
        "internal var lastAccelWindowAt = Date.distantPast",
        "internal var lastAccelWindowRaw: [Float]?",
        "internal let accelPipeline = EatingAccelPipeline()",
        "internal let eatingPersonalization = EatingPersonalization()",
        "internal let eatingLocation = EatingLocationGate()",
        "internal var lastWantAccel = false",
        "internal var lastEatingPositiveAt = Date.distantPast",
        "internal var eatingNudge: EatingAlert?",
        "internal lazy var healthKitImportSource: HealthKitImportSource",
        "internal var lastHealthKitAutoImport = Date.distantPast",
        "internal lazy var healthKitExportDestination: HealthKitExportDestination",
        "internal var lastHealthKitAutoExport = Date.distantPast",
        "internal var alertIntel = AppModel.loadAlertIntel()",
    ]

    /// The ONE new (not widened — it never existed before, so there is no `private`->`internal`
    /// transition to prove) `internal` COMPUTED property this carve added: a thin, read-only seam so
    /// `AppModel+Backup.swift`'s `buildPrivacyExport` can read the ledger snapshot WITHOUT widening
    /// `deliveryLedgerCoordinator` itself (review concern #1's dose-adjacent exception — see its own
    /// doc comment in `AppModel.swift`).
    static let newInternalSeamDeclaration = "internal var privacyExportLedgerSnapshot: RemoteBolusLedger"

    /// Every literal `internal var`/`internal let`/`internal lazy var` occurrence in `AppModel.swift`
    /// (stored-property or computed-property declarations using the explicit keyword). Per the type
    /// doc comment's baseline fact, 100% of these are attributable to this carve.
    private static func allExplicitInternalDeclarationLines(in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("internal var ") || trimmed.contains("internal let ")
                || trimmed.contains("internal lazy var ")
        }
    }

    // MARK: - Tests

    /// The widened set is EXACTLY the enumerated 17 stored properties — every enumerated declaration
    /// is present, and no OTHER explicit-`internal` stored-property declaration exists beyond the one
    /// new computed seam (`privacyExportLedgerSnapshot`). Fails loudly (not vacuously) if the source
    /// resolves implausibly short.
    @Test func widenedSetIsExactlyTheEnumeratedAdvisoryProperties() throws {
        let source = try Self.appModelSource()
        #expect(source.count > 10_000, "AppModel.swift resolved implausibly short — path resolution likely broke")

        for declaration in Self.widenedStoredPropertyDeclarations {
            #expect(source.contains(declaration),
                    "Expected widened declaration missing from AppModel.swift: '\(declaration)'")
        }

        let allLines = Self.allExplicitInternalDeclarationLines(in: source)
        let expectedCount = Self.widenedStoredPropertyDeclarations.count + 1   // +1 for the new seam
        #expect(allLines.count == expectedCount,
                "Found \(allLines.count) explicit-`internal` declaration lines in AppModel.swift, expected exactly \(expectedCount) (the enumerated 17 widened + the 1 new seam). Extra or missing lines:\n\(allLines.joined(separator: "\n"))")

        #expect(source.contains(Self.newInternalSeamDeclaration),
                "Expected new internal seam missing from AppModel.swift: '\(Self.newInternalSeamDeclaration)'")
    }

    /// No dose/gate member was widened: `deliveryLedgerCoordinator` (the dose-adjacent ledger/
    /// global-block coordinator owning `runLedgeredDelivery`) stays `private` — the carve added a
    /// thin read-only seam NEXT TO it instead of widening the coordinator itself. The two
    /// history-diff keys (Phase 16 GO-1 Step 5 / 16-05: now owned by `HistoryPersistenceCoordinator`,
    /// not `AppModel`) also stay `private` in their new home, proving the widening was minimal, not
    /// "widen everything nearby".
    @Test func noDoseOrGateMemberWasWidened() throws {
        let source = try Self.appModelSource()

        #expect(source.contains("private let deliveryLedgerCoordinator: DeliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must stay `private` — it is dose-adjacent and must never be widened by an advisory carve")
        #expect(!source.contains("internal let deliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must never appear as `internal` — this carve reads it only via the read-only privacyExportLedgerSnapshot seam")
        #expect(!source.contains("internal var deliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must never appear as `internal`")

        // 16-05 retarget (CX-A-08): these two keys moved OUT of AppModel.swift entirely (a dedicated
        // coordinator extraction, not a same-type widening) — assert the negative here (never
        // reappears in AppModel.swift) AND the positive against their actual new file, so this stays
        // a loud, non-vacuous proof rather than an assertion the move made permanently unreachable.
        #expect(!source.contains("lastPersistedGlucoseKeys"),
                "lastPersistedGlucoseKeys must no longer appear in AppModel.swift at all — it moved to HistoryPersistenceCoordinator.swift (16-05)")
        #expect(!source.contains("lastPersistedBolusKeys"),
                "lastPersistedBolusKeys must no longer appear in AppModel.swift at all — it moved to HistoryPersistenceCoordinator.swift (16-05)")

        let coordinatorSource = try Self.historyPersistenceCoordinatorSource()
        #expect(coordinatorSource.contains("private var lastPersistedGlucoseKeys: Set<TimeInterval>"),
                "lastPersistedGlucoseKeys must stay `private` in HistoryPersistenceCoordinator.swift — no method outside the coordinator touches it")
        #expect(coordinatorSource.contains("private var lastPersistedBolusKeys: Set<TimeInterval>"),
                "lastPersistedBolusKeys must stay `private` in HistoryPersistenceCoordinator.swift — no method outside the coordinator touches it")
    }

    /// Fault-injection proof for the line-scan helper itself (mirrors `AppModelReferenceAuditTests`'
    /// `markerCheckerDiscriminatesActiveFromCommentOnly` idiom): a synthetic source string containing
    /// an explicit-`internal` stored-property line must be detected, and one that only NAMES a
    /// property in a doc comment (no `internal var`/`internal let` keyword) must not — proving the
    /// checker discriminates a real declaration from mere prose.
    @Test func declarationScannerDiscriminatesRealDeclarationsFromProse() {
        let declarationLike = "    internal var totallyFakeWidenedProperty: Int = 0"
        let proseLike = "    /// See `totallyFakeWidenedProperty` in AppModel.swift for the widening rationale."
        #expect(Self.allExplicitInternalDeclarationLines(in: declarationLike).count == 1)
        #expect(Self.allExplicitInternalDeclarationLines(in: proseLike).isEmpty)
    }

    // MARK: - WR-02 hardening: enforce the backtick-quoting convention this scan silently relies on

    /// Returns the comment portion of each line (everything from the first `//` onward, covering `//`
    /// and `///` line/doc comments). The count-based guard above scans the WHOLE line for the literal
    /// substrings `internal var `/`internal let `/`internal lazy var ` (each with a TRAILING space), so a
    /// future doc comment in `AppModel.swift` that writes one of those keywords in bare prose (rather
    /// than backtick-quoted, e.g. `` `internal var` ``, which has no trailing space) would silently
    /// inflate the count and fail the widened-set assertion for a reason unrelated to any real widening.
    private static func commentPortions(in source: String) -> [String] {
        source.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "//") else { return nil }
            return String(line[range.lowerBound...])
        }
    }

    /// The convention this suite depends on, made loud: NO comment/prose line in `AppModel.swift` may
    /// contain a bare (non-backtick-quoted) `internal var `/`internal let `/`internal lazy var `
    /// substring. Backtick-quoting a keyword (`` `internal var` ``) elides the trailing space the
    /// count scanner keys on, so the convention keeps prose from being miscounted as a declaration.
    /// If this ever fails, the fix is to backtick-quote the keyword in the offending comment — NOT to
    /// relax the count guard.
    @Test func appModelProseBacktickQuotesInternalKeywords() throws {
        let comments = Self.commentPortions(in: try Self.appModelSource())
        let bareForms = ["internal var ", "internal let ", "internal lazy var "]
        for comment in comments {
            for form in bareForms {
                #expect(!comment.contains(form),
                        "AppModel.swift comment prose contains a bare `\(form.trimmingCharacters(in: .whitespaces))` — backtick-quote it (e.g. `` `\(form.trimmingCharacters(in: .whitespaces))` ``) so it cannot inflate the widened-declaration count. Offending comment: '\(comment)'")
            }
        }
    }

    /// Fault-injection proof the convention checker is not vacuous: a synthetic comment with a bare
    /// `internal var ` is caught; a backtick-quoted one is not.
    @Test func proseConventionCheckerDiscriminatesBareFromBacktickQuoted() {
        let bareComment = "    /// this widens internal var foo to internal"
        let quotedComment = "    /// this widens `internal var` foo to internal"
        let bare = Self.commentPortions(in: bareComment)
        let quoted = Self.commentPortions(in: quotedComment)
        #expect(bare.contains { $0.contains("internal var ") })
        #expect(!quoted.contains { $0.contains("internal var ") })
    }
}
