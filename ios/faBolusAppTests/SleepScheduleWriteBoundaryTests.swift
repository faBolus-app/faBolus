import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Mobi Sleep-schedule write is `.settings` risk, never `.delivery`: `SetSleepScheduleRequest` does
/// not declare `modifiesInsulinDelivery`, and `TandemBackend.setSleepSchedule` must send via
/// `delivery: false`.
@Suite @MainActor
struct SleepScheduleWriteBoundaryTests {

    // MARK: - Structural/property proof

    /// `SetSleepScheduleRequest` is signed + `.control` (so `.readOnly` blocks it) but does not declare
    /// `modifiesInsulinDelivery`, so `MessageProps.operationRisk` derives `.settings` — never `.delivery`.
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

    // MARK: - Static source scan

    /// `TandemBackend.setSleepSchedule`'s function body — located by signature, not a line range — sends
    /// via `sendControl(..., delivery: false)` and contains no delivery-enabling call. Scanning the
    /// function-body slice only matters because `delivery: true` is legitimate elsewhere in the same file.
    @Test func nonDeliverySendSiteContainsNoDeliveryEnablingCall() throws {
        let forbidden = ["delivery: true", ".allowDelivery"]

        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
        let tandemBackendURL = repoRoot.appendingPathComponent("ios/faBolus/Data/TandemBackend.swift")
        let source = try String(contentsOf: tandemBackendURL, encoding: .utf8)

        let slice = try Self.balancedFunctionBody(signaturePrefix: "func setSleepSchedule(", in: source)
        for symbol in forbidden {
            #expect(
                !slice.contains(symbol),
                "Forbidden delivery-enabling symbol '\(symbol)' found in TandemBackend.setSleepSchedule's body")
        }
        // Positive proof (not just an absence-of-forbidden-symbols check): the function DOES send under
        // the non-delivery policy — the scan actually inspects the right thing.
        #expect(
            slice.contains("delivery: false"),
            "TandemBackend.setSleepSchedule must send via sendControl(..., delivery: false)")
        #expect(
            slice.contains("sendControl("), "TandemBackend.setSleepSchedule must route through the sendControl funnel")
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
                if ch == "{" {
                    depth += 1
                    opened = true
                } else if ch == "}" {
                    depth -= 1
                }
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
