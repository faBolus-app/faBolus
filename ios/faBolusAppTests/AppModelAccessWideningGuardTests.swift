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

    // MARK: - The enumerated widened set (verified against source — see 16-04 SUMMARY)

    /// The EXACT 17 stored-property declarations widened `private`->`internal` by this carve, held as
    /// their exact declaration-line substrings (not bare property names) so the check is precise and
    /// cannot accidentally match an unrelated occurrence of the same word elsewhere in the file.
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
    /// deliberately-NOT-widened history-diff keys (touched only by unmoved `persistNewHistory`) also
    /// stay `private`, proving the widening was minimal, not "widen everything nearby".
    @Test func noDoseOrGateMemberWasWidened() throws {
        let source = try Self.appModelSource()

        #expect(source.contains("private let deliveryLedgerCoordinator: DeliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must stay `private` — it is dose-adjacent and must never be widened by an advisory carve")
        #expect(!source.contains("internal let deliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must never appear as `internal` — this carve reads it only via the read-only privacyExportLedgerSnapshot seam")
        #expect(!source.contains("internal var deliveryLedgerCoordinator"),
                "deliveryLedgerCoordinator must never appear as `internal`")

        #expect(source.contains("private var lastPersistedGlucoseKeys: Set<TimeInterval>"),
                "lastPersistedGlucoseKeys must stay `private` — no carved method touches it (verified against source, not the plan's draft)")
        #expect(source.contains("private var lastPersistedBolusKeys: Set<TimeInterval>"),
                "lastPersistedBolusKeys must stay `private` — no carved method touches it (verified against source, not the plan's draft)")
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
}
