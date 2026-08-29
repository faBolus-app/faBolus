import Testing
import Foundation
@testable import faBolus

/// Pins that scanned Swift sources contain no invisible or zero-width Unicode. A hidden code point can change meaning without a visible diff.
struct InvisibleUnicodeGuardTests {

    /// The invisible/zero-width Unicode code points this guard bans anywhere in scanned source:
    /// U+200B (zero-width space), U+200C (zero-width non-joiner), U+200D (zero-width joiner),
    /// U+FEFF (zero-width no-break space / BOM), U+2060 (word joiner).
    static let invisibleCodePoints: [Unicode.Scalar] = [
        Unicode.Scalar(0x200B)!, Unicode.Scalar(0x200C)!, Unicode.Scalar(0x200D)!,
        Unicode.Scalar(0xFEFF)!, Unicode.Scalar(0x2060)!,
    ]

    // MARK: - Repo enumeration (mirrors BandDriftGuardTests' idiom)

    /// Resolve the repo root by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/InvisibleUnicodeGuardTests.swift`) until `project.yml` — a stable,
    /// always-checked-in repo-root marker — is found. Same walk-up technique as
    /// `BandDriftGuardTests.repoRootURL()`.
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

    /// Recursively enumerate every `.swift` file under `root`, skipping build artifacts and any
    /// `*Tests` directory (this file's own directory included — its own string constants are the
    /// scan's NEEDLES, not something to scan). Same idiom as `BandDriftGuardTests.allSwiftFiles(under:)`,
    /// minus the `faBolusDesign`/`faBolusCore` module exemption (this guard's scope explicitly INCLUDES
    /// `Packages/faBolusCore`, unlike the band-color drift guard).
    private static func allSwiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        let skipDirNames: Set<String> = [
            ".build", "DerivedData", "Pods", ".git", "node_modules",
        ]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipDirNames.contains(name) || name.hasSuffix("Tests") {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift" { results.append(url) }
        }
        return results
    }

    /// Scan `ios/faBolus`, `Shared`, and `Packages/faBolusCore` relative to the repo root.
    private static func scanRoots(repoRoot: URL) -> [URL] {
        [
            repoRoot.appendingPathComponent("ios/faBolus"),
            repoRoot.appendingPathComponent("Shared"),
            repoRoot.appendingPathComponent("Packages/faBolusCore"),
        ]
    }

    // MARK: - The guard

    /// No invisible/zero-width Unicode code point (U+200B/200C/200D/FEFF/2060) may appear anywhere in
    /// `ios/faBolus`, `Shared`, or `Packages/faBolusCore`. Also asserts the scan actually walked > 0
    /// files, so a broken path/enumerator regression fails loudly instead of passing vacuously (mirrors
    /// `BandDriftGuardTests`' own `scannedBlocks > 0` / `fileResolutionActuallyFoundTheRepoRoot` pattern).
    @Test func noInvisibleUnicodeInScannedTrees() throws {
        let repoRoot = try #require(Self.repoRootURL(),
                                     "could not resolve repo root from #filePath=\(#filePath)")
        var filesScanned = 0
        var violations: [String] = []

        for root in Self.scanRoots(repoRoot: repoRoot) {
            for url in Self.allSwiftFiles(under: root) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                filesScanned += 1
                for scalar in raw.unicodeScalars {
                    if Self.invisibleCodePoints.contains(scalar) {
                        violations.append(
                            "\(url.path) contains invisible Unicode code point U+\(String(format: "%04X", scalar.value))"
                        )
                    }
                }
            }
        }

        #expect(violations.isEmpty,
                "Invisible-Unicode guard violated (C6-03):\n\(violations.joined(separator: "\n"))")
        #expect(filesScanned > 0,
                "expected to scan at least one .swift file across ios/faBolus, Shared, Packages/faBolusCore — walk broke (would otherwise pass vacuously)")
    }
}
