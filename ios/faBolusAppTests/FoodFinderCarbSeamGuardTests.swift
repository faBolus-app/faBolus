import Testing
import Foundation
@testable import faBolus

/// D-12 / D-18.1 (09.18c-01): FoodFinder is dose-adjacent, so it must ORIGINATE no dose. An estimated
/// carb number may reach the signed dose path ONLY as a string written into `BolusEntryView.carbsText`
/// through the user-confirmed "Add to carbs" seam — never through a carb-history store, a closed-loop
/// carb entry, the bolus calculator, or any delivery call. This guard makes that self-enforcing by raw-
/// text-scanning every `.swift` file under the three FoodFinder feature roots for the forbidden dose-
/// coupling tokens and asserting they are absent.
///
/// Mirrors `KeyboardShortcutDoseGuardTests`' `#filePath`-rooted `resolve(_:)` walk-up + raw-text
/// `String(contentsOf:)` `#expect(!source.contains(...))` idiom exactly (PATTERNS §9, RESEARCH D-18
/// source-scan sketch — scanning raw text is robust to whitespace variance and needs no Swift parse).
///
/// RED-first: the `foodFinderVendorDirectoryIsLiveAndNonEmpty` liveness test FAILS before the FoodFinder
/// sources exist (the Vendor dir is absent / empty), and the whole suite goes GREEN once the vendored OFF
/// service + models (Task 2) and the FoodFinderView surface (Task 3) land clean. The per-token scans pass
/// vacuously while the dirs are empty — the liveness test is what guarantees this guard cannot pass
/// vacuously before the code it protects even exists.
struct FoodFinderCarbSeamGuardTests {
    /// The three FoodFinder feature roots this guard owns (repo-root-relative).
    private static let featureDirs = [
        "ios/faBolus/Vendor/LoopPowerPack/FoodFinder",
        "ios/faBolus/Views/FoodFinder",
        "ios/faBolus/Data/FoodFinder",
    ]

    /// The exact dose-coupling needle literals FoodFinder sources must never contain. `carbStore`
    /// (lowercase) catches a property/parameter of a carb store; `CarbStore`/`CarbEntry` catch the
    /// LoopKit types; `deliverBolus`/`remoteDeliver` catch delivery calls; `calculate(` catches the
    /// bolus-calculator invocation (which only `BolusEntryView` — deliberately NOT scanned here — may
    /// make, driven by the user's own `.onChange(of: carbsText)`).
    private static let forbiddenTokens = [
        "CarbStore",
        "carbStore",
        "CarbEntry",
        "deliverBolus",
        "remoteDeliver",
        "calculate(",
    ]

    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/FoodFinderCarbSeamGuardTests.swift`) — same technique as
    /// `KeyboardShortcutDoseGuardTests.resolve(_:)`.
    private static func resolve(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Enumerate every `.swift` file under a resolved repo-relative directory (non-recursive-safe: uses a
    /// deep enumerator so nested files are covered too). Returns `[]` if the directory does not resolve.
    private static func swiftFiles(under relativeDir: String) -> [URL] {
        guard let dirURL = resolve(relativeDir) else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dirURL,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    // MARK: - D-12 / D-18.1: no dose-coupling symbol may appear in any FoodFinder feature file

    @Test func foodFinderSourcesContainNoDoseCouplingSymbol() throws {
        for dir in Self.featureDirs {
            for fileURL in Self.swiftFiles(under: dir) {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for token in Self.forbiddenTokens {
                    #expect(!source.contains(token),
                            """
                            D-12/D-18.1 violated — FoodFinder file \(fileURL.lastPathComponent) contains the \
                            forbidden dose-coupling token "\(token)". FoodFinder must originate no dose: an \
                            estimated carb number may reach the dose path ONLY as a string written into \
                            BolusEntryView.carbsText via the user-confirmed "Add to carbs" seam \
                            (onApplyGrams) — never a carb store, carb entry, bolus calculator, or delivery call.
                            """)
                }
            }
        }
    }

    // MARK: - Liveness: this guard must NOT pass vacuously before the FoodFinder sources exist

    /// RED before Task 2 vendors the OFF sources into `ios/faBolus/Vendor/LoopPowerPack/FoodFinder/`,
    /// GREEN after. If path resolution ever breaks, this fails loudly rather than letting the token scans
    /// above pass over zero files.
    @Test func foodFinderVendorDirectoryIsLiveAndNonEmpty() {
        let vendorDir = "ios/faBolus/Vendor/LoopPowerPack/FoodFinder"
        #expect(Self.resolve(vendorDir) != nil,
                "D-18.1 liveness — the FoodFinder Vendor dir (\(vendorDir)) must resolve from #filePath=\(#filePath); the source-scan guard is vacuous until it does.")
        #expect(!Self.swiftFiles(under: vendorDir).isEmpty,
                "D-18.1 liveness — the FoodFinder Vendor dir must enumerate at least one .swift file, so the dose-coupling scan actually scans real sources (not zero files).")
    }
}
