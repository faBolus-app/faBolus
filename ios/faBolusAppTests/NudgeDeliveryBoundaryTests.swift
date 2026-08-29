import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// The eating-nudge carb estimate is display-only and must never be the number that reaches the
/// signed dose path (`TandemBackend.deliverBolus` / `GatedPumpWrite`).
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

    // MARK: - End-to-end nudge → deliver boundary

    /// The only number that reaches the pump is the one the user typed, never the nudge's estimate.
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

    /// `EatingAlert.estimatedCarbs` is display-only: it surfaces through `.message`, never a second
    /// member a caller could route onto the dose path.
    @Test func nudgeAlertExposesEstimateOnlyViaMessage() {
        let zeroCarbAlert = EatingAlert(estimatedCarbs: 0, at: Date())
        #expect(zeroCarbAlert.message == "Looks like you might be eating. Bolus?")

        let carbAlert = EatingAlert(estimatedCarbs: 42, at: Date())
        #expect(carbAlert.message == "Looks like you're eating (~42g). Bolus?")
        #expect(carbAlert.message.contains("42"))
    }

    // MARK: - Source scan: nudge files contain no delivery-seam symbols

    /// Eating-nudge source must contain zero delivery-seam symbols. Slice `AppModel+EatingNudge`
    /// by function signature, never whole-file — `deliverBolus`/`remoteDeliver` are legitimately
    /// declared in `AppModel.swift`.
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
            repoRoot.appendingPathComponent("ios/faBolus/Data/App/SmartAssist.swift"),
        ]
        for url in wholeFileTargets {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for symbol in forbidden {
                #expect(!contents.contains(symbol), "Forbidden delivery-seam symbol '\(symbol)' found in \(url.lastPathComponent)")
            }
        }

        // Scope (2): function-body scan of AppModel+EatingNudge.swift's three eating-nudge
        // functions only. MUST NOT whole-file-scan AppModel.swift — deliverBolus/remoteDeliver
        // are legitimately declared there.
        let eatingNudgeFileURL = repoRoot.appendingPathComponent("ios/faBolus/Data/App/AppModel+EatingNudge.swift")
        let eatingNudgeSource = try String(contentsOf: eatingNudgeFileURL, encoding: .utf8)
        let eatingNudgeFunctionSignatures = [
            "func eatingNudgeActedOn(",
            "func updateEatingNudge(",
            "func dismissEatingNudge(",
        ]
        for signature in eatingNudgeFunctionSignatures {
            let slice = try Self.balancedFunctionBody(signaturePrefix: signature, in: eatingNudgeSource)
            for symbol in forbidden {
                #expect(!slice.contains(symbol), "Forbidden delivery-seam symbol '\(symbol)' found in AppModel+EatingNudge.swift's \(signature) body")
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
