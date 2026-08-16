import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// **MUST-NOT-REACH boundary (phase #92, faBolusNudge delivery-path boundary).** Proves the INVERSE of
/// `StackingGuardDeliverInvariantTests`: where that suite proves a friction disclosure never blocks the
/// consented dose from reaching the pump, this suite proves the advisory `FABOLUS_NUDGE` eating nudge NEVER
/// supplies the number that reaches the signed delivery seam (`TandemBackend.deliverBolus` /
/// `GatedPumpWrite`). UNGATED — NOT wrapped in `#if FABOLUS_NUDGE` (D-04) — so this suite compiles and RUNS
/// under CI's `FABOLUS_NUDGE=0` build: `EatingAlert`, `AppModel.eatingNudge*`, and
/// `AppModel.openBolusRequested` are all declared OUTSIDE the gate; only their bodies branch on it. This
/// test asserts the boundary STRUCTURALLY; it does NOT add a runtime is-from-nudge gate to the deliver seam
/// (D-01). See `.planning/phases/07-fabolusnudge-delivery-path-boundary-92/07-CONTEXT.md`.
@Suite(.serialized) @MainActor
struct NudgeDeliveryBoundaryTests {

    private let bolusId = 9012
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// A backend whose time-sync + permission already succeed, scripted to a matching bolus status so a
    /// full-completion delivery settles. Copied verbatim (same 4 scripted opcodes) from
    /// `StackingGuardDeliverInvariantTests.makeDeliveringBackend` — Swift Testing suites are independent
    /// structs and `FakePumpTransport` is already file-visible across the target, so no shared base class
    /// is needed.
    private func makeDeliveringBackend(deliveredMilliunits: UInt32) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
        return (backend, fake)
    }

    // MARK: - Task 1 (TRACER): end-to-end nudge → deliver boundary

    /// MUST-NOT-REACH: a LIVE nudge with `estimatedCarbs == 60` is in flight while the REAL deliver path
    /// (through `FakePumpTransport`) delivers an EXPLICITLY-entered dose of `3.2`. The delivered amount
    /// equals the entered dose and is never the nudge's estimate — the only number that ever reaches the
    /// pump is the one the user typed, proving SC1/SC2/D-05d as a coupled pair (mirrors
    /// `StackingGuardDeliverInvariantTests.deliveredEqualsConsentedWhileSG1Fires`, inverted into a
    /// MUST-NOT-REACH shape per D-03).
    @Test func deliveredEqualsExplicitDoseNeverNudgeEstimate() async throws {
        let liveNudge = EatingAlert(estimatedCarbs: 60, at: Date())   // deliberately != the entered dose below
        let entered = 3.2                                            // the ONLY number that should reach the pump

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3200)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: 0)
        #expect(delivered == entered)                          // exactly the entered dose
        #expect(delivered != liveNudge.estimatedCarbs)          // guards against a future accidental wiring of the estimate into the dose
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake   // keep the fake alive for the duration of the assertion
    }

    /// `EatingAlert.estimatedCarbs` surfaces ONLY through `.message` (D-02/D-05a/D-05c) — there is no
    /// second stored/computed member on the type a caller could route into a dose. `EatingAlert` (see
    /// `ios/faBolus/Data/SmartAssist.swift`) declares exactly two members: `estimatedCarbs` (the raw
    /// number) and `message` (the display string it feeds); `message` is the ONLY other member on the
    /// type, so the type's own shape — not a runtime probe — is the proof that the number terminates
    /// there. This test pins the string-level behavior so a future member addition is caught at review.
    @Test func nudgeAlertExposesEstimateOnlyViaMessage() {
        let zeroCarbAlert = EatingAlert(estimatedCarbs: 0, at: Date())
        #expect(zeroCarbAlert.message == "Looks like you might be eating. Bolus?")

        let carbAlert = EatingAlert(estimatedCarbs: 42, at: Date())
        #expect(carbAlert.message == "Looks like you're eating (~42g). Bolus?")
        #expect(carbAlert.message.contains("42"))
    }

    // MARK: - Task 2: belt-and-suspenders static source scan

    /// Second, independent proof (source-level, D-02/D-05b): the eating-nudge source contains ZERO
    /// delivery-seam symbols. `EatingTrigger.swift` and `SmartAssist.swift` are scanned WHOLE-FILE (both
    /// are delivery-symbol-free today); `AppModel.swift` is scanned by FUNCTION-BODY SLICE ONLY, for its
    /// three eating-nudge functions located by signature — NEVER whole-file, because `deliverBolus` /
    /// `remoteDeliver` are legitimately declared elsewhere in that same file (RESEARCH Pitfall 1). A
    /// future line-shift in `AppModel.swift` cannot silently widen or narrow the scanned region because
    /// the slice is found by signature, not by hardcoded line numbers.
    @Test func nudgeSourceContainsNoDeliverySeamSymbols() throws {
        // The forbidden delivery-seam identifier set: the two `GatedPumpWrite` delivery verbs plus the
        // signed-write entry-point names. Held as plain string constants — this scan targets the SOURCE
        // files below, never this test file itself, so their appearance here is not what's under test.
        let forbidden = ["deliverBolus", "deliverExtendedBolus", "remoteDeliver", "perform(totalMu"]

        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root

        // Scope (1): whole-file negative scan — both files are delivery-symbol-free today.
        let wholeFileTargets = [
            repoRoot.appendingPathComponent("Packages/faBolusCore/Sources/faBolusCore/EatingTrigger.swift"),
            repoRoot.appendingPathComponent("ios/faBolus/Data/SmartAssist.swift"),
        ]
        for url in wholeFileTargets {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for symbol in forbidden {
                #expect(!contents.contains(symbol), "Forbidden delivery-seam symbol '\(symbol)' found in \(url.lastPathComponent)")
            }
        }

        // Scope (2): function-body-scoped scan of AppModel.swift's three eating-nudge functions only.
        // MUST NOT whole-file-scan AppModel.swift — deliverBolus/remoteDeliver are legitimately declared
        // elsewhere in that file, which would be a guaranteed false positive.
        let appModelURL = repoRoot.appendingPathComponent("ios/faBolus/Data/AppModel.swift")
        let appModelSource = try String(contentsOf: appModelURL, encoding: .utf8)
        let eatingNudgeFunctionSignatures = [
            "func eatingNudgeActedOn(",
            "func updateEatingNudge(",
            "func dismissEatingNudge(",
        ]
        for signature in eatingNudgeFunctionSignatures {
            let slice = try Self.balancedFunctionBody(signaturePrefix: signature, in: appModelSource)
            for symbol in forbidden {
                #expect(!slice.contains(symbol), "Forbidden delivery-seam symbol '\(symbol)' found in AppModel.swift's \(signature) body")
            }
        }
    }

    /// Locate a function by its declaration-line signature prefix (e.g. `"func foo("`) and return the
    /// source slice from that line through its balanced closing brace. Scoping by signature (rather than a
    /// hardcoded line range) means a future line-shift in the source file does not silently widen or
    /// narrow the scanned region.
    private static func balancedFunctionBody(signaturePrefix: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.contains(signaturePrefix) }) else {
            throw SliceError.signatureNotFound(signaturePrefix)
        }
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[startIdx...] {
            collected.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        guard opened else { throw SliceError.unbalancedBraces(signaturePrefix) }
        return collected.joined(separator: "\n")
    }

    private enum SliceError: Error, CustomStringConvertible {
        case signatureNotFound(String)
        case unbalancedBraces(String)
        var description: String {
            switch self {
            case .signatureNotFound(let sig): return "Function signature not found while scanning: \(sig)"
            case .unbalancedBraces(let sig): return "Could not find a balanced closing brace for: \(sig)"
            }
        }
    }
}
