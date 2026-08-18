import Testing
import Foundation

/// SYSTEMIC guard (09.18e): the untrusted-`Double`→`Int` trap crash-class recurred TWICE during
/// LoopPowerPack adoption — 09.18c (FoodFinder carb-estimate card / AI parse / serving-size display) and
/// 09.18d (LoopInsights caffeine + alcohol trackers). Each time a free-text / paste-able / third-party
/// `Double` flowed into a raw `Int(_:)`, which **traps** ("… cannot be converted to Int because it is
/// either infinite or NaN" / overflow) on `.infinity` / `.nan` / a finite value above `Int.max` (e.g.
/// `1e19`). The fix is the single shared [[clampedInt]] funnel in faBolusCore. This guard makes the funnel
/// self-enforcing: it raw-text-scans every `.swift` file under the FoodFinder + LoopInsights feature roots
/// and FAILS the always-run `swift test` suite the moment a raw `Int(` reappears — the kind of regression
/// manual review misses on a merge or a cherry-pick from upstream.
///
/// **The rule (these dirs only):** no raw `Int(` conversion. Route an untrusted `Double` through
/// `clampedInt(_:min:max:)`; if a specific `Int(` genuinely cannot trap (e.g. the failable
/// `Int(_ text: StringProtocol)` String→Int? parse, which returns `nil` instead of trapping), annotate that
/// exact line with the inline `safe-int-conversion` marker so the exemption is a conscious, reviewable
/// decision rather than a silent reappearance of the anti-pattern.
///
/// Scanning strategy (robust to whitespace, needs no Swift parse — mirrors `NotificationSingleBuilderGuard`
/// and `FoodFinderCarbSeamGuardTests`): per line, (1) skip lines carrying the `safe-int-conversion` marker,
/// (2) drop the `//`-comment tail so prose mentions of `Int(_:)` in doc comments are not flagged, then
/// (3) match `Int(` only when NOT preceded by an identifier char — so `clampedInt(` and `UInt(` are never
/// false-positives.
struct DoubleToIntTrapGuardTests {

    /// The FoodFinder + LoopInsights feature roots this guard owns (repo-root-relative). Both the vendored
    /// LoopPowerPack sources and the faBolus-original / re-skinned surfaces are covered — the trap has bitten
    /// in each. These are exactly the dirs that ingest untrusted numbers (OpenFoodFacts JSON, an AI carb
    /// reply, a pasted tracker amount) and render them, so a raw `Int(` here is the exact recurrence risk.
    private static let featureDirs = [
        "ios/faBolus/Data/FoodFinder",
        "ios/faBolus/Views/FoodFinder",
        "ios/faBolus/Vendor/LoopPowerPack/FoodFinder",
        "ios/faBolus/Views/LoopInsights",
        "ios/faBolus/Vendor/LoopPowerPack/LoopInsights",
    ]

    /// Inline exemption marker for a raw `Int(` that provably cannot trap (must sit on the SAME line as the
    /// conversion). Keep exemptions rare and each one justified in the same comment.
    private static let allowMarker = "safe-int-conversion"

    /// Matches a raw `Int(` call that is NOT part of a longer identifier — the negative lookbehind excludes
    /// `clampedInt(` (the funnel) and `UInt(` (never traps). Compiled once.
    private static let rawIntCall: NSRegularExpression = {
        // swiftlint:disable:next force_try — a constant, hand-verified pattern; a failure is a coding error.
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])Int\\(")
    }()

    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/Packages/faBolusCore/Tests/faBolusCoreTests/DoubleToIntTrapGuardTests.swift`) to the repo
    /// root — same technique as `NotificationSingleBuilderGuardTests.appRoots()`.
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

    /// Enumerate every `.swift` file under a resolved repo-relative directory (deep enumerator, so a nested
    /// file is covered too). Returns `[]` if the directory does not resolve (a missing dir just contributes
    /// zero files; the liveness assertions below catch a total-resolution break).
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

    /// The code portion of a line with its `//`-comment tail removed. Prose like "would trap `Int(_:)`" in a
    /// doc comment must not count as a violation; the scanned dirs carry no `/* */` block comments and no
    /// `//` inside a string literal ahead of a real `Int(`, so a plain first-`//` split is sufficient here.
    private static func codePortion(of line: some StringProtocol) -> String {
        let s = String(line)
        if let r = s.range(of: "//") { return String(s[..<r.lowerBound]) }
        return s
    }

    private static func hasRawIntCall(_ code: String) -> Bool {
        rawIntCall.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    // MARK: - The invariant: no raw untrusted Double→Int in the FoodFinder / LoopInsights dirs

    @Test func foodFinderAndLoopInsightsRouteDoubleToIntThroughClampedInt() throws {
        var scannedFiles = 0
        var sawClampedIntFunnel = false
        var violations: [String] = []

        for dir in Self.featureDirs {
            for fileURL in Self.swiftFiles(under: dir) {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scannedFiles += 1
                if source.contains("clampedInt(") { sawClampedIntFunnel = true }

                for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.contains(Self.allowMarker) { continue }          // consciously-annotated exemption
                    guard Self.hasRawIntCall(Self.codePortion(of: line)) else { continue }
                    violations.append("\(fileURL.lastPathComponent):\(offset + 1)")
                }
            }
        }

        // Liveness: a path-resolution break (0 files) or a wholesale revert of the funnel (no clampedInt
        // anywhere) must FAIL loudly, not let the scan pass vacuously over zero real sites.
        #expect(scannedFiles > 0,
                "Double→Int trap guard scanned no files — path resolution broke (#filePath=\(#filePath)).")
        #expect(sawClampedIntFunnel,
                "Double→Int trap guard saw no clampedInt( usage in the FoodFinder / LoopInsights dirs — the shared funnel appears to have been reverted, or the scan is not reaching the real sources.")

        #expect(violations.isEmpty,
                """
                Untrusted Double→Int trap risk reintroduced — raw `Int(` found at: \
                \(violations.joined(separator: ", ")). \
                In the FoodFinder / LoopInsights feature dirs, route an untrusted Double through the shared \
                `clampedInt(_:min:max:)` funnel (faBolusCore) instead of a raw `Int(_:)` — a non-finite \
                (.infinity/.nan) or out-of-range (e.g. 1e19 > Int.max) value TRAPS `Int(_:)` and crashes the \
                surface. If the conversion provably cannot trap (e.g. the failable String→Int? parse), add \
                an inline `\(Self.allowMarker)` marker on that line with a one-line justification.
                """)
    }

    // MARK: - Liveness: the guard's own scanning primitives must behave

    /// Guards the guard: the exemption marker, the comment strip, and the identifier-boundary lookbehind
    /// must each work, so the invariant test above cannot silently rot into a vacuous pass.
    @Test func scanPrimitivesBehave() {
        // A raw Double→Int is caught.
        #expect(Self.hasRawIntCall(Self.codePortion(of: "        return Int(capped)")))
        // The funnel and UInt are NOT caught (identifier-boundary lookbehind).
        #expect(!Self.hasRawIntCall(Self.codePortion(of: "        return clampedInt(raw, max: 1000)")))
        #expect(!Self.hasRawIntCall(Self.codePortion(of: "        let id = UInt(bitPattern: h)")))
        // A prose mention of Int(_:) inside a comment is stripped before scanning → not caught.
        #expect(!Self.hasRawIntCall(Self.codePortion(of: "        // a raw Int(_:) here would trap")))
        // The FoodFinder Data root resolves (so `clampedInt` sites are actually reachable by the scan).
        #expect(Self.resolve("ios/faBolus/Data/FoodFinder") != nil,
                "liveness — ios/faBolus/Data/FoodFinder must resolve from #filePath=\(#filePath).")
    }
}
