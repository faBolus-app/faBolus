import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Control-IQ-awareness helpers are display-only: they must not return a dose-shaped type, and
/// the signed delivery path must not reference them.
struct CiqAwarenessScopeGuardTests {

    // MARK: - Source resolution (mirrors WatchDirectBleScopeGuardTests.repoRootURL)

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/CiqAwarenessScopeGuardTests.swift`) until `ios/faBolus/Data` exists.
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

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Function-signature extraction (verbatim from WatchDirectBleScopeGuardTests)

    /// Extracts every `func`/`static func` SIGNATURE (name + parameter list + optional return type, no
    /// body) from a Swift source string, whitespace-normalized so formatting-only changes don't trip the
    /// guard — only an actual signature change does.
    private static func functionSignatures(in source: String) -> Set<String> {
        let pattern = #"(?:public\s+)?(?:static\s+)?func\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^{}]*\)(?:\s*->\s*[^{\n]+?)?\s*(?=\{)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var out: Set<String> = []
        for m in matches {
            let raw = ns.substring(with: m.range)
            let normalized = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            out.insert(normalized)
        }
        return out
    }

    // MARK: - Balanced-brace region extraction (signature-located, not whole-file)

    /// Returns the text from the FIRST `{` found after `marker` through its matching `}` (brace-depth
    /// balanced), i.e. exactly the declared body of whatever `marker` names — an `enum`/`struct` type body
    /// when `marker` is a type declaration, or a function body when `marker` is a func signature prefix.
    /// Mirrors the plan's explicit "balanced-brace scan of a signature-located region" idiom, generalizing
    /// `RemoteDiagnosticsScopeGuardTests.caseRegion`'s string-range technique to nested braces.
    private static func balancedBraceRegion(in source: String, afterMarker marker: String) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }
        guard let openBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var idx = openBrace.lowerBound
        var closeIdx: String.Index?
        while idx < source.endIndex {
            let c = source[idx]
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { closeIdx = idx; break }
            }
            idx = source.index(after: idx)
        }
        guard let end = closeIdx else { return nil }
        return String(source[openBrace.lowerBound...end])
    }

    // MARK: - (a) No dose-shaped return type

    /// Allowed return shapes for a Control-IQ-awareness advisory: a fraction, disclosure copy, a
    /// status flag, or a frozen wire-token enum. A bare `Double`/`Int`/`UInt32` that could carry a
    /// dose is forbidden.
    private static let allowedCiqReturnShapes: Set<String> = [
        "Double?", "String?", "String", "Bool", "ControlIQZone?",
        // Headline+detail is disclosure copy, never a dose/units shape.
        "(headline: String, detail: String)?",
        // Fail-closed optional status flag (nil pre-bench), never a dose.
        "Bool?",
    ]

    /// Extracts the substring after the LAST `-> ` in a normalized signature (its return type), or `nil`
    /// if the signature has no return type at all (`Void` — never a dose by construction).
    private static func ciqReturnType(of signature: String) -> String? {
        guard let arrowRange = signature.range(of: "-> ", options: .backwards) else { return nil }
        return String(signature[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// The prong-(a) checker: `true` iff `signature` has no return type, or its return type is one of the
    /// allowed shapes above.
    private static func isCiqAllowedReturnShape(_ signature: String) -> Bool {
        guard let returnType = ciqReturnType(of: signature) else { return true }
        return allowedCiqReturnShapes.contains(returnType)
    }

    /// Control-IQ-awareness type bodies to scan. Extend this when a new advisory type is added.
    private static let knownCiqAwarenessSignatureSources: [(file: String, typeMarker: String)] = [
        ("Packages/faBolusCore/Sources/faBolusCore/AutoCorrectionDisclosure.swift", "public enum AutoCorrectionDisclosure"),
        ("Packages/faBolusCore/Sources/faBolusCore/Models.swift", "public enum ControlIQZone"),
        // `ControlIQDisableWarning` is gone; its denylist token stays so the scan is never weakened.
        ("Packages/faBolusCore/Sources/faBolusCore/Models.swift", "public enum MaxBasalFraction"),
        ("Packages/faBolusCore/Sources/faBolusCore/ControlIQMode.swift", "public enum CiqPlusTempRate"),
        ("Packages/faBolusCore/Sources/faBolusCore/Models.swift", "public enum CiqCeilingFlags"),
    ]

    @Test func noCiqAwarenessFunctionReturnsADoseShapedType() throws {
        var totalSignaturesChecked = 0
        for (file, marker) in Self.knownCiqAwarenessSignatureSources {
            guard let source = Self.readSource(file) else {
                Issue.record("could not resolve \(file) from #filePath=\(#filePath)")
                continue
            }
            guard let region = Self.balancedBraceRegion(in: source, afterMarker: marker) else {
                Issue.record("could not find a balanced-brace region for '\(marker)' in \(file)")
                continue
            }
            let sigs = Self.functionSignatures(in: region)
            #expect(!sigs.isEmpty, "'\(marker)' region yielded zero function signatures — region resolution likely broke")
            for sig in sigs {
                totalSignaturesChecked += 1
                #expect(Self.isCiqAllowedReturnShape(sig),
                        "'\(marker)': signature '\(sig)' returns a shape outside {Double?, String?, String, Bool, ControlIQZone?} — possible dose-shaped return (D-06 guardrail #1)")
            }
        }
        // Fail loudly if path/region resolution found fewer signatures than the five sources ship.
        #expect(totalSignaturesChecked >= 8, "fewer CIQ-awareness signatures were found than the phase currently ships — path/region resolution likely broke")
    }

    /// Fault-injection proof for the prong-(a) checker (guardrail #1): since production code cannot be
    /// safely mutated within this plan's test-files-only scope, the checker's discriminating power is
    /// proven directly against synthetic signatures shaped exactly like a plausible future violation (a
    /// bare units/milliunits return) — they MUST be rejected. The real, currently-shipped signatures are
    /// re-asserted allowed in the SAME test so a checker that rejects everything (vacuously "passing" the
    /// test above for the wrong reason) is also caught.
    @Test func theReturnShapeCheckerRejectsDoseShapedSignaturesAndAllowsRealOnes() {
        let forbiddenSynthetic = [
            "static func recommendedDoseUnits() -> Double",
            "static func suggestedBolusUnits(zone: ControlIQZone) -> Double",
            "func maxBolusMilliunits() -> UInt32",
            "static func ceilingRemainingUnits(descriptor: ControllerDescriptor) -> Int",
        ]
        for sig in forbiddenSynthetic {
            #expect(!Self.isCiqAllowedReturnShape(sig), "checker failed to reject a dose-shaped synthetic signature: \(sig)")
        }
        let realAllowed = [
            "public static func lockoutRemainingFraction(descriptor: ControllerDescriptor, controllerEnabled: Bool, lockoutStartDate: Date?, now: Date) -> Double?",
            "static func shouldWarn(descriptor: ControllerDescriptor) -> Bool",
            "static func title(descriptor: ControllerDescriptor) -> String",
            "public static func fromControlStateType(_ raw: Int) -> ControlIQZone?",
        ]
        for sig in realAllowed {
            #expect(Self.isCiqAllowedReturnShape(sig), "checker incorrectly rejected a real, currently-shipped signature: \(sig)")
        }
    }

    // MARK: - (b) The signed delivery path references no Control-IQ-awareness symbol

    /// Display-only CIQ-awareness symbols that must not appear on the signed delivery path.
    /// Pre-existing Control-IQ symbols (`setControlIQ`, `controlIQEnabled`, …) are out of scope —
    /// dose-adjacent code may read those for a CIQ-off precondition.
    private static let forbiddenCiqAwarenessSymbols: [String] = [
        "ciqZone", "ControlIQZone", "lockoutRemainingFraction", "AutoCorrectionDisclosure",
        "ControlIQDisableWarning", "ciqSuspendedForLow", "ciqSuspendStartEpochSec",
        "ciqMaxBolusEventsExceeded", "ciqMaxIobEventsExceeded", "lastAutoCorrectionEpochSec",
        "ciqLastCouldNotDeliverEpochSec",
        "MaxBasalFraction", "maxBasalUnitsPerHour",
        "CiqPlusTempRate",
        "CiqCeilingFlags",
    ]

    /// Scans `region` for every token in `forbiddenCiqAwarenessSymbols`, recording an `Issue` (via the
    /// caller's own `#expect`) for the first prohibited reference. Shared by the real scan and the
    /// fault-injection self-test below so both exercise the identical matching rule.
    private static func regionContainsAnyForbiddenSymbol(_ region: String) -> String? {
        for token in Self.forbiddenCiqAwarenessSymbols where region.contains(token) { return token }
        return nil
    }

    @Test func signedDeliveryPathReferencesNoCiqAwarenessSymbol() throws {
        guard let backendSource = Self.readSource("ios/faBolus/Data/TandemBackend.swift") else {
            Issue.record("could not resolve ios/faBolus/Data/TandemBackend.swift from #filePath=\(#filePath)")
            return
        }
        let deliverRegions: [(name: String, marker: String)] = [
            ("deliverBolus", "public func deliverBolus(units:"),
            ("deliverExtendedBolus", "public func deliverExtendedBolus(totalUnits:"),
            ("validateDeliver", "private func validateDeliver(total:"),
            ("perform", "private func perform(totalMu:"),
        ]
        for (name, marker) in deliverRegions {
            guard let region = Self.balancedBraceRegion(in: backendSource, afterMarker: marker) else {
                Issue.record("could not find a balanced-brace region for TandemBackend.\(name) (marker '\(marker)')")
                continue
            }
            #expect(region.count > 20, "TandemBackend.\(name) region resolved suspiciously short — path/region resolution likely broke")
            #expect(Self.regionContainsAnyForbiddenSymbol(region) == nil,
                    "TandemBackend.\(name) references forbidden CIQ-awareness symbol '\(Self.regionContainsAnyForbiddenSymbol(region) ?? "?")' (D-06 guardrail #2)")
        }

        guard let bolusMathSource = Self.readSource("Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift") else {
            Issue.record("could not resolve Packages/faBolusCore/Sources/faBolusCore/BolusMath.swift from #filePath=\(#filePath)")
            return
        }
        #expect(Self.regionContainsAnyForbiddenSymbol(bolusMathSource) == nil,
                "BolusMath.swift references forbidden CIQ-awareness symbol '\(Self.regionContainsAnyForbiddenSymbol(bolusMathSource) ?? "?")' (D-06 guardrail #2)")

        guard let gatedWriteSource = Self.readSource("Packages/faBolusCore/Sources/faBolusCore/GatedPumpWrite.swift") else {
            Issue.record("could not resolve Packages/faBolusCore/Sources/faBolusCore/GatedPumpWrite.swift from #filePath=\(#filePath)")
            return
        }
        #expect(Self.regionContainsAnyForbiddenSymbol(gatedWriteSource) == nil,
                "GatedPumpWrite.swift references forbidden CIQ-awareness symbol '\(Self.regionContainsAnyForbiddenSymbol(gatedWriteSource) ?? "?")' (D-06 guardrail #2)")
    }

    /// Fault-injection proof for prong (b): a synthetic COPY of the real `perform()` region with a
    /// forbidden CIQ-awareness reference appended (never written to the file itself) must be flagged by
    /// the SAME `regionContainsAnyForbiddenSymbol` matcher the real scan above uses — proving the scan
    /// would go RED were a future edit to actually introduce such a reference into the deliver path. The
    /// real region is re-asserted clean in the same test, so this also proves today's code doesn't already
    /// trip it.
    @Test func theForbiddenSymbolScanCatchesAnInjectedReference() throws {
        guard let backendSource = Self.readSource("ios/faBolus/Data/TandemBackend.swift"),
              let region = Self.balancedBraceRegion(in: backendSource, afterMarker: "private func perform(totalMu:") else {
            Issue.record("could not resolve TandemBackend.swift perform() region for the fault-injection check")
            return
        }
        #expect(Self.regionContainsAnyForbiddenSymbol(region) == nil,
                "the REAL perform() region must be clean before the fault-injection check is meaningful")
        for poison in ["snapshot.ciqZone", "ControlIQZone.increases", "AutoCorrectionDisclosure.lockoutRemainingFraction"] {
            let poisoned = region + "\nlet _ = \(poison) // FAULT-INJECTED for scan verification only, never committed to production\n"
            #expect(Self.regionContainsAnyForbiddenSymbol(poisoned) != nil,
                    "the scan failed to catch an injected reference to '\(poison)' — it would not go RED for a real regression")
        }
    }
}
