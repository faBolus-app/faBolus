import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// **09.15-04 SAFETY CONTRACT — guardrail #1 + #2 (D-06).** A source-scan guard, modeled on
/// `WatchDirectBleScopeGuardTests`' `#filePath`-rooted repo-walk + function-signature extraction and
/// `RemoteDiagnosticsScopeGuardTests`' balanced-region scan, proving two static properties of the
/// codebase that must hold for the WHOLE phase, not just today's slice:
///
/// (a) **No dose in the return type.** None of the Control-IQ-awareness advisory functions built so far
///     (`AutoCorrectionDisclosure`'s disclosure functions, `ControlIQZone`'s wire-token mapping,
///     `MaxBasalFraction`/`CiqPlusTempRate`/`CiqCeilingFlags`'s bench-gated fns) declares a return type outside the allowed shapes
///     `Double?` (a fraction), `String?`/`String` (disclosure copy), `Bool` (a status flag), or
///     `ControlIQZone?` (a frozen wire token) — never a bare `Double`/`Int`/`UInt32` that could carry a
///     dose or milliunits value. Because production code cannot be safely mutated to prove this
///     discriminates (this plan's `files_modified` is test-files-only), the checker itself is proven
///     non-vacuous with synthetic dose-shaped signatures it must reject.
///
/// (b) **The signed delivery path imports nothing from Control-IQ-awareness.** `TandemBackend.deliverBolus`
///     / `.deliverExtendedBolus` / `.validateDeliver` / `.perform` (the actual signed dose path),
///     `BolusMath.swift` (the pure dose-calculator math), and `GatedPumpWrite.swift` (the dose write's
///     access-gate declaration) reference NONE of the named Control-IQ-awareness symbols — a balanced-
///     brace, signature-located region scan (not a whole-file grep, which could false-positive on
///     pre-existing, unrelated Control-IQ symbols like `setControlIQ`/`controlIQEnabled`/
///     `ControlIQPrecondition` that predate this phase and are NOT Control-IQ-awareness disclosure code).
///
/// **Maintenance note for later 09.15 plans (05-12):** `forbiddenCiqAwarenessSymbols` and
/// `knownCiqAwarenessSignatureSources` are PINNED to the primitives that exist as of plan 04. Every later
/// plan that adds a new Control-IQ-awareness primitive (T1-2's `ciqSuspendedForLow`, T1-8's max-basal-
/// fraction fn, T2-1's ceiling flags, …) MUST append the new symbol name to `forbiddenCiqAwarenessSymbols`
/// and, if it lives in a new file/type, add an entry to `knownCiqAwarenessSignatureSources` — mirroring how
/// `RemoteDiagnosticsScopeGuardTests.pinnedMutatingBaseline` is maintained plan-by-plan. Forgetting to
/// extend these sets does not make this suite fail; it makes it silently stop covering the new primitive.
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

    /// Allowed return shapes for a Control-IQ-awareness advisory function (D-06 guardrail #1): a fraction,
    /// disclosure copy, a status flag, or a frozen wire-token enum. Anything else — in particular a bare
    /// `Double`/`Int`/`UInt32` that could carry a dose or milliunits value — is forbidden.
    private static let allowedCiqReturnShapes: Set<String> = [
        "Double?", "String?", "String", "Bool", "ControlIQZone?",
        // T1-8 (09.15-08): `MaxBasalFraction.label` returns the LOCKED headline+detail pair as a tuple of
        // two Strings — unambiguously disclosure copy, not a dose/units shape (both components are always
        // formatted STRINGS, never a raw Double the tuple could smuggle a units value through).
        "(headline: String, detail: String)?",
        // T2-1 (09.15-11): `CiqCeilingFlags.wireMaxBolusEventsExceeded`/`.wireMaxIobEventsExceeded` return
        // a fail-closed OPTIONAL status flag (nil pre-bench, never a dose/units value) — the nilable
        // counterpart of the already-allowed bare `Bool` above.
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

    /// The Control-IQ-awareness TYPE bodies to scan for prong (a), as (file, type-declaration marker)
    /// pairs. See the suite doc-comment's maintenance note — extend this as later plans add new types.
    private static let knownCiqAwarenessSignatureSources: [(file: String, typeMarker: String)] = [
        ("Packages/faBolusCore/Sources/faBolusCore/AutoCorrectionDisclosure.swift", "public enum AutoCorrectionDisclosure"),
        ("Packages/faBolusCore/Sources/faBolusCore/Models.swift", "public enum ControlIQZone"),
        // Phase 23 (23-01, D-06): `ControlIQDisableWarning` (formerly here, moved verbatim from the
        // deleted `Views/PumpWizardViews.swift` in Phase 9) was deleted outright — the whole type + its
        // dedicated `CiqDisableWarningTests.swift` are gone from `main` (D-03/D-05). Its
        // `forbiddenCiqAwarenessSymbols` denylist token below is KEPT unchanged (D-06): a deleted symbol
        // is trivially absent from the signed delivery path, so the scan stays a strict superset, never
        // weakened.
        // T1-8 (09.15-08): the "% of your configured max basal rate" pure fraction + LOCKED label fn.
        ("Packages/faBolusCore/Sources/faBolusCore/Models.swift", "public enum MaxBasalFraction"),
        // T2-3 (09.15-09): the CIQ+ temp-rate bench+capability gate — `isOffered` returns a plain `Bool`
        // availability flag (already an allowed shape), never a dose/units value.
        ("Packages/faBolusCore/Sources/faBolusCore/ControlIQMode.swift", "public enum CiqPlusTempRate"),
        // T2-1 (09.15-11): the direct CIQ-ceiling-flags bench+emission gate — both `wireMax*Exceeded`
        // functions return `Bool?` (already an allowed shape), never a dose/units value.
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
        // A path/region-resolution bug must fail loudly, not pass vacuously with zero signatures checked.
        // Phase 23 (23-01, D-06): floor re-derived live after `ControlIQDisableWarning`'s catalog entry
        // (3 signatures: shouldWarn/title/body) was deleted AND after 23-01 Task 2's `AutoCorrectionDisclosure`
        // slim (D-09) removes `ambientIndicator`/`lockoutMessage`, leaving only `lockoutRemainingFraction`.
        // Live count across the 5 surviving sources post-slim: AutoCorrectionDisclosure=1,
        // ControlIQZone=1, MaxBasalFraction=3, CiqPlusTempRate=1, CiqCeilingFlags=2 == 8.
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

    /// Every Control-IQ-awareness symbol name introduced by 09.15 so far. See the suite doc-comment's
    /// maintenance note — later plans (05-12) MUST append their own new symbol names here.
    ///
    /// Deliberately does NOT include pre-existing, non-09.15 Control-IQ symbols (`setControlIQ`,
    /// `controlIQEnabled`, `controlIQMode`, `ControlIQPrecondition`, `ControlIQSettingsView`, …) — those
    /// predate this phase, are legitimately read by dose-adjacent code (e.g. `setTempBasal`'s CIQ-off
    /// precondition), and are NOT the disclosure-only surfaces this guardrail scopes.
    private static let forbiddenCiqAwarenessSymbols: [String] = [
        "ciqZone", "ControlIQZone", "lockoutRemainingFraction", "AutoCorrectionDisclosure",
        "ControlIQDisableWarning", "ciqSuspendedForLow", "ciqSuspendStartEpochSec",
        "ciqMaxBolusEventsExceeded", "ciqMaxIobEventsExceeded", "lastAutoCorrectionEpochSec",
        "ciqLastCouldNotDeliverEpochSec",
        // T1-8 (09.15-08): the max-basal fraction/label fn + the propagated primitive it's built from.
        "MaxBasalFraction", "maxBasalUnitsPerHour",
        // T2-3 (09.15-09): the CIQ+ temp-rate bench+capability gate — a BENCH-GATED PLACEHOLDER, not a
        // dose value itself, but forbidden here so the signed delivery path never grows a dependency on
        // this disclosure-adjacent gate.
        "CiqPlusTempRate",
        // T2-1 (09.15-11): the direct CIQ-ceiling-flags bench+emission gate — same rationale as
        // `CiqPlusTempRate` above; `ciqMaxBolusEventsExceeded`/`ciqMaxIobEventsExceeded` were already
        // pinned here in advance by an earlier plan.
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
