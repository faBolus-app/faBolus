import Testing
import Foundation

/// Pins that AppModel's explicit `internal` stored properties are exactly the enumerated advisory set
/// and that no dose/gate member was widened. Opening `deliveryLedgerCoordinator` would put the
/// delivery ledger on an extension-visible surface.
///
/// Baseline fact this guard depends on (verified, not assumed): before the carve that split AppModel,
/// `AppModel.swift` contained ZERO declarations using the explicit `internal` keyword — every member
/// was `private`/`private(set)`/`public`, or carried no modifier at all (Swift's default, which is
/// already internal and needs no keyword). That is what makes the scan below sound: every literal
/// `internal var`/`internal let` in the file today is attributable to the carve, with no pre-existing
/// noise to subtract.
struct AppModelAccessWideningGuardTests {

    // MARK: - Repo/file resolution

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

    /// `lastPersistedGlucoseKeys`/`lastPersistedBolusKeys` live in `HistoryPersistenceCoordinator`, not AppModel.
    /// Scanning only AppModel.swift would vacuous-pass after the move.
    private static func historyPersistenceCoordinatorSource() throws -> String {
        let root = try #require(Self.repoRootURL(), "could not resolve repo root from #filePath")
        let url = root.appendingPathComponent("ios/faBolus/Data/App/HistoryPersistenceCoordinator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The enumerated widened set

    /// Exact declaration-line substrings widened to `internal`. `history` is now computed but still starts
    /// with this prefix — the guard pins visibility, not stored-vs-computed.
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
        "internal var alertIntel = AppModel.loadAlertIntel()"
    ]

    /// Thin read-only seam so backup export can read the ledger snapshot without widening `deliveryLedgerCoordinator`.
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
            #expect(
                source.contains(declaration),
                "Expected widened declaration missing from AppModel.swift: '\(declaration)'")
        }

        let allLines = Self.allExplicitInternalDeclarationLines(in: source)
        let expectedCount = Self.widenedStoredPropertyDeclarations.count + 1  // +1 for the new seam
        #expect(
            allLines.count == expectedCount,
            "Found \(allLines.count) explicit-`internal` declaration lines in AppModel.swift, expected exactly \(expectedCount) (the enumerated 17 widened + the 1 new seam). Extra or missing lines:\n\(allLines.joined(separator: "\n"))"
        )

        #expect(
            source.contains(Self.newInternalSeamDeclaration),
            "Expected new internal seam missing from AppModel.swift: '\(Self.newInternalSeamDeclaration)'")
    }

    /// No dose/gate member was widened: `deliveryLedgerCoordinator` stays `private`. The history-diff keys
    /// stay `private` in HistoryPersistenceCoordinator.
    @Test func noDoseOrGateMemberWasWidened() throws {
        let source = try Self.appModelSource()

        #expect(
            source.contains("private let deliveryLedgerCoordinator: DeliveryLedgerCoordinator"),
            "deliveryLedgerCoordinator must stay `private` — it is dose-adjacent and must never be widened by an advisory carve"
        )
        #expect(
            !source.contains("internal let deliveryLedgerCoordinator"),
            "deliveryLedgerCoordinator must never appear as `internal` — this carve reads it only via the read-only privacyExportLedgerSnapshot seam"
        )
        #expect(
            !source.contains("internal var deliveryLedgerCoordinator"),
            "deliveryLedgerCoordinator must never appear as `internal`")

        // These two keys moved out of AppModel entirely — assert the negative here AND the positive against their new file so the move cannot make this pin unreachable.
        #expect(
            !source.contains("lastPersistedGlucoseKeys"),
            "lastPersistedGlucoseKeys must no longer appear in AppModel.swift at all — it moved to HistoryPersistenceCoordinator.swift (16-05)"
        )
        #expect(
            !source.contains("lastPersistedBolusKeys"),
            "lastPersistedBolusKeys must no longer appear in AppModel.swift at all — it moved to HistoryPersistenceCoordinator.swift (16-05)"
        )

        let coordinatorSource = try Self.historyPersistenceCoordinatorSource()
        #expect(
            coordinatorSource.contains("private var lastPersistedGlucoseKeys: Set<TimeInterval>"),
            "lastPersistedGlucoseKeys must stay `private` in HistoryPersistenceCoordinator.swift — no method outside the coordinator touches it"
        )
        #expect(
            coordinatorSource.contains("private var lastPersistedBolusKeys: Set<TimeInterval>"),
            "lastPersistedBolusKeys must stay `private` in HistoryPersistenceCoordinator.swift — no method outside the coordinator touches it"
        )
    }

    /// Fault-injection proof for the line-scan helper itself: a synthetic source string containing
    /// an explicit-`internal` stored-property line must be detected, and one that only NAMES a
    /// property in a doc comment (no `internal var`/`internal let` keyword) must not — proving the
    /// checker discriminates a real declaration from mere prose.
    @Test func declarationScannerDiscriminatesRealDeclarationsFromProse() {
        let declarationLike = "    internal var totallyFakeWidenedProperty: Int = 0"
        let proseLike = "    /// See `totallyFakeWidenedProperty` in AppModel.swift for the widening rationale."
        #expect(Self.allExplicitInternalDeclarationLines(in: declarationLike).count == 1)
        #expect(Self.allExplicitInternalDeclarationLines(in: proseLike).isEmpty)
    }

    // MARK: - Backtick-quoting convention this scan relies on

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
                #expect(
                    !comment.contains(form),
                    "AppModel.swift comment prose contains a bare `\(form.trimmingCharacters(in: .whitespaces))` — backtick-quote it (e.g. `` `\(form.trimmingCharacters(in: .whitespaces))` ``) so it cannot inflate the widened-declaration count. Offending comment: '\(comment)'"
                )
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
