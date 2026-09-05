import Testing
import Foundation

/// DENY-BY-DEFAULT source-text funnel guard — the standing replacement for
/// `everyTherapyWriteEntryPointIsCentrallyGated` (deleted with its subjects when `AccessPolicy` Gate 1 and
/// its 12 ack-gated `AppModel` entry points were retired). That table test asserted coverage over a
/// declared set of gated cases; once the subjects are gone, a table over an empty row set proves nothing.
/// This guard instead scans `AppModel.swift`'s ACTUAL source text for every `source.<identifier>(` pump
/// write and fails on any identifier not on an explicit, by-name allow-list — so a pump write added later,
/// with no `GatedPumpWrite` case to classify it into, still forces a deliberate decision rather than
/// silently reaching the backend unfunneled.
///
/// Modeled on `AppModelAccessWideningGuardTests` — the same `#filePath`-walk repo-root resolution and the
/// same loud-failure idiom, so a moved file fails loudly, not quietly.
///
/// What this proves and does not prove: that every pump write in `AppModel` is one of the enumerated,
/// by-name entry points below — falsifiable by text, not by trusting `GatedPumpWrite.allCases` (whose own
/// declared set could drift from what `AppModel` actually calls). It does NOT prove any surviving write is
/// *gated* — that is `AccessPolicyTests`' job; the two are complementary, not substitutes.
struct PumpWriteFunnelGuardTests {

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

    // MARK: - The allow-list

    /// Every `source.<identifier>(` name `AppModel.swift` is permitted to call, re-derived from
    /// what actually survives the phase's deletions (`grep -oE 'source\.[a-zA-Z][a-zA-Z0-9]*\('
    /// ios/faBolus/Data/AppModel.swift | sort -u`). By NAME, not by pattern — a substring hunt for
    /// `source.set`/`source.`+`Profile` would miss real writes like `suspendDelivery`/`resumeDelivery`.
    /// Anything not on this list fails the scan below.
    static let allowedSourceCallNames: [String] = [
        // Delivery / dismissal anchors — the four capability-permitted `GatedPumpWrite` cases.
        "deliverBolus", "deliverExtendedBolus", "cancelBolus", "dismissNotificationTyped",
        // Pump-switch reset.
        "resetSnapshotForPumpSwitch",
        // Reads / reconcile — mutate nothing, so they carry no `GatedPumpWrite` case.
        "refreshSleepSchedule", "refreshProfileSegments", "refreshGlucoseNow", "refreshCalcInputsNow",
        "reconcile", "recommendBolus", "clearUnknownOutcomeAfterManualVerification",
        // Connection lifecycle.
        "connect", "disconnect", "forgetPairing",
    ]

    /// Every literal `source.<identifier>(` occurrence in `AppModel.swift`, by name (no arguments, no
    /// duplicates) — a source-TEXT scan, which also catches a call sitting inside a compile-time-excluded
    /// `#if` block that the compiler itself would never see.
    private static func sourceCallNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        var searchStart = text.startIndex
        let prefix = "source."
        while let prefixRange = text.range(of: prefix, range: searchStart..<text.endIndex) {
            var cursor = prefixRange.upperBound
            var name = ""
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            if !name.isEmpty, cursor < text.endIndex, text[cursor] == "(",
                name.first?.isLetter == true
            {
                names.insert(name)
            }
            searchStart = prefixRange.upperBound
        }
        return names
    }

    // MARK: - Tests

    /// Deny-by-default: every `source.<identifier>(` in `AppModel.swift` must be on the allow-list.
    /// Anything unlisted fails — this is what a newly-added, unclassified pump write reddens.
    @Test func everySourceCallIsOnTheAllowList() throws {
        let source = try Self.appModelSource()
        #expect(source.count > 5_000, "AppModel.swift resolved implausibly short — path resolution likely broke")

        let found = Self.sourceCallNames(in: source)
        let allowed = Set(Self.allowedSourceCallNames)
        let unlisted = found.subtracting(allowed)
        #expect(
            unlisted.isEmpty,
            """
            Found source.<name>( call(s) in AppModel.swift not on the funnel guard's allow-list: \(unlisted.sorted()). \
            Every pump write reachable through AppModel must be a deliberate, named decision — \
            add it to PumpWriteFunnelGuardTests.allowedSourceCallNames with a stated reason, or remove the call.
            """
        )
    }

    /// Anti-vacuity #1: the resolved source is non-empty and contains the delivery anchors this guard is
    /// NOT about — so a guard pointed at the wrong file, or at a file the delivery core has left, fails.
    @Test func resolvedSourceContainsTheDeliveryAnchors() throws {
        let source = try Self.appModelSource()
        for anchor in ["source.deliverBolus(", "source.deliverExtendedBolus(", "source.cancelBolus("] {
            #expect(source.contains(anchor), "Expected delivery anchor missing from AppModel.swift: '\(anchor)'")
        }
    }

    /// Anti-vacuity #2: every allow-list entry is asserted PRESENT (as a real `source.<name>(` call), not
    /// merely tolerated — so a rename that removes a survivor turns this guard red instead of silently
    /// shrinking the found set to make the allow-list check above vacuously pass.
    @Test func everyAllowListEntryIsActuallyPresent() throws {
        let source = try Self.appModelSource()
        let found = Self.sourceCallNames(in: source)
        for name in Self.allowedSourceCallNames {
            #expect(
                found.contains(name),
                """
                Allow-listed name '\(name)' has no matching source.\(name)( call in AppModel.swift — \
                either it was renamed/removed (update the allow-list) or the scan is broken.
                """
            )
        }
    }

    /// Fault-injection proof for the scanner itself: a synthetic source string containing an unlisted
    /// `source.<name>(` call must be detected as unlisted — proving the scanner would catch a real
    /// regression, not just pass because it never looks.
    @Test func scannerDetectsAnUnlistedInjectedWrite() {
        let injected = "        try await self.source.suspendDeliveryButUnlisted()\n"
        let found = Self.sourceCallNames(in: injected)
        #expect(found.contains("suspendDeliveryButUnlisted"))
        #expect(!Set(Self.allowedSourceCallNames).contains("suspendDeliveryButUnlisted"))
    }
}
