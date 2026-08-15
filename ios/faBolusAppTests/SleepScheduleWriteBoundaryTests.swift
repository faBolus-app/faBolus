import Testing
import Foundation
import faBolusCore
import PumpX2Messages
import PumpX2BLE
@testable import faBolus

/// **MUST-NOT-REACH boundary (Phase 09.10, T-09.10-03).** Proves the L7 mode-only invariant for the Mobi
/// native Sleep-schedule write TWO independent ways, mirroring `NudgeDeliveryBoundaryTests`' shape (a
/// structural/property proof + a belt-and-suspenders static source scan):
///
/// 1. **Structural/property:** `SetSleepScheduleRequest.props.operationRisk == .settings` — it is signed
///    and `.control`-characteristic (so `.readOnly` still blocks it), but `modifiesInsulinDelivery` is
///    UNSET, so `MessageProps.operationRisk` (Core/MessageProps.swift) derives `.settings`, never
///    `.delivery`. No `WritePolicy` path can elevate a `.settings`-risk message to allow insulin delivery
///    — the risk class is derived from the message's OWN declared shape, not from how it is sent.
/// 2. **Source-scan:** a `#filePath`-rooted, balanced-brace scan of `TandemBackend.setSleepSchedule`'s
///    function body (located by signature, not a hardcoded line range, so a future line-shift in the
///    source file can't silently widen or narrow the scanned region) proves it calls `sendControl` with
///    the NON-delivery argument and contains no delivery-enabling call.
///
/// **Fault-injection verified to actually bite:** temporarily changed the `setSleepSchedule` call site to
/// `sendControl(SetSleepScheduleRequest(...), delivery: true)` — `nonDeliverySendSiteContainsNoDeliveryEnablingCall`
/// went RED (found the forbidden `delivery: true` token in the scanned slice); reverted. This confirms
/// the scan is not a vacuous always-pass — it actually detects the L7 violation it's written to catch.
@Suite @MainActor
struct SleepScheduleWriteBoundaryTests {

    // MARK: - Task 2.1: structural/property proof

    /// `SetSleepScheduleRequest` is signed + `.control` (so `.readOnly` blocks it) but does NOT declare
    /// `modifiesInsulinDelivery`, so `MessageProps.operationRisk` derives `.settings` — never `.delivery`.
    /// This is the L7 invariant enforced structurally IN THE KIT, independent of how the app calls it.
    @Test func setSleepScheduleRequestIsSettingsRiskNeverDeliveryRisk() {
        let props = SetSleepScheduleRequest.props
        #expect(props.operationRisk == .settings)
        #expect(props.operationRisk != .delivery)
        #expect(props.signed)
        #expect(props.characteristic == .control)
    }

    /// `SetSleepScheduleResponse` (the write's ack) is likewise `.settings`-risk — it is a signed control
    /// response with no delivery effect, so a caller checking the ack's own risk gets the same answer.
    @Test func setSleepScheduleResponseIsSettingsRiskNeverDeliveryRisk() {
        #expect(SetSleepScheduleResponse.props.operationRisk == .settings)
        #expect(SetSleepScheduleResponse.props.operationRisk != .delivery)
    }

    // MARK: - Task 2.2: belt-and-suspenders static source scan

    /// Second, independent proof (source-level): `TandemBackend.setSleepSchedule`'s function body — located
    /// by signature, not a hardcoded line range — sends via the non-delivery `sendControl(..., delivery:
    /// false)` form and contains no delivery-enabling call. Scanning the FUNCTION-BODY SLICE only (never
    /// the whole file) matters because `sendControl(..., delivery: true)` is legitimately called elsewhere
    /// in the same file (e.g. `suspendDelivery`/`setTempBasal`), which would be a guaranteed false positive
    /// under a whole-file scan (mirrors `NudgeDeliveryBoundaryTests`' Pitfall-1 note for `AppModel.swift`).
    @Test func nonDeliverySendSiteContainsNoDeliveryEnablingCall() throws {
        let forbidden = ["delivery: true", ".allowDelivery"]

        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
        let tandemBackendURL = repoRoot.appendingPathComponent("ios/faBolus/Data/TandemBackend.swift")
        let source = try String(contentsOf: tandemBackendURL, encoding: .utf8)

        let slice = try Self.balancedFunctionBody(signaturePrefix: "func setSleepSchedule(", in: source)
        for symbol in forbidden {
            #expect(!slice.contains(symbol), "Forbidden delivery-enabling symbol '\(symbol)' found in TandemBackend.setSleepSchedule's body")
        }
        // Positive proof (not just an absence-of-forbidden-symbols check): the function DOES send under
        // the non-delivery policy — the scan actually inspects the right thing.
        #expect(slice.contains("delivery: false"), "TandemBackend.setSleepSchedule must send via sendControl(..., delivery: false)")
        #expect(slice.contains("sendControl("), "TandemBackend.setSleepSchedule must route through the sendControl funnel")
    }

    /// Locate a function by its declaration-line signature prefix (e.g. `"func foo("`) and return the
    /// source slice from that line through its balanced closing brace. Scoping by signature (rather than a
    /// hardcoded line range) means a future line-shift in the source file does not silently widen or
    /// narrow the scanned region. Mirrors `NudgeDeliveryBoundaryTests.balancedFunctionBody` byte-for-byte.
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
