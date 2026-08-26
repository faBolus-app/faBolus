import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// **MUST-NOT-REACH boundary (Phase 09.7-01, D-06).** Proves the gap-aware history-log sync — the
/// coverage-map diff + paged `HistoryLogRequest` fetch that replaces the old `didBackfill` backfill — has
/// no route to the signed dose path. Mirrors `NudgeDeliveryBoundaryTests`'s two-proof shape (runtime +
/// static source scan): `HistoryLogStatusRequest`/`HistoryLogRequest` are `.currentStatus`-characteristic,
/// unsigned, no `allowInsulinDelivery` override — they fail-safe-derive to `.read` risk under the
/// connection's default `.readOnly` `WritePolicy` (RESEARCH Security Domain). This suite is the
/// belt-and-suspenders test-level complement to that structural proof. UNGATED (not behind any build
/// flag) so it runs on every CI build.
@Suite(.serialized) @MainActor
struct HistoryLogSyncDeliveryBoundaryTests {

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    // MARK: - Runtime proof

    /// A full, multi-page/multi-window gap sync (forward gap AND an interior hole, both wide enough to
    /// span more than one 255-record page) drives the ENTIRE sync to completion on a `FakePumpTransport`
    /// that has NO bolus opcode scripted or built AT ALL — there is no `BolusPermissionResponse`/
    /// `InitiateBolusResponse` reply available even if the sync somehow tried to reach for one. After the
    /// sync settles, `fake.sent` must contain zero bolus-permission / initiate-bolus opcodes, and no sent
    /// message anywhere may have its delivery-elevation flag set.
    @Test func historySyncNeverReachesDeliverySeam() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            // Held coverage has an interior hole (300...400) and ends at 600 — the pump range 1...900
            // then has TWO windows to fetch (300...400 interior, 601...900 forward), the second one wide
            // enough (300 records) to need two pages.
            AppSettings.shared.historyCoverage = HistoryCoverageMap(ranges: [1...299, 401...600])

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 900, firstSequenceNum: 1, lastSequenceNum: 900))
            // Drain every page/window boundary — comfortably more ticks than the sync could ever need.
            for _ in 0..<20 {
                backend.injectHistoryLogFrameForTesting(
                    FakePumpTransport.historyLogStream(cgmReadings: [(seq: 1, pumpTimeSec: 1, mgdl: 100)]))
                backend.fireHistorySyncTickForTesting()
            }

            let deliverySeamOpcodes: Set<UInt8> = [BolusPermissionRequest.props.opCode, InitiateBolusRequest.props.opCode]
            #expect(!fake.sent.contains { deliverySeamOpcodes.contains($0.opCode) },
                    "the gap-sync path must never send a bolus-permission or initiate-bolus request")
            #expect(!fake.sent.contains { $0.allowDelivery },
                    "no message the gap-sync path sends may carry the delivery-elevation flag")
            #expect(!fake.sent.isEmpty, "sanity: the sync must have actually sent history-log requests")
        }
    }

    // MARK: - Static source scan (belt-and-suspenders)

    /// Signature-scoped scan (never whole-file — `deliverBolus`/`InitiateBolusRequest` are legitimately
    /// declared elsewhere in `TandemBackend.swift`) of every gap-sync function, asserting none of their
    /// bodies reference a delivery-seam identifier. Fault-injection-verified during development:
    /// temporarily referencing `InitiateBolusRequest` inside `requestBackfillPage` made this test fail
    /// as expected; reverted before commit (recorded in the plan SUMMARY).
    ///
    /// **Retargeted (Phase 16 16-08, GO-2 Step 1, REMED-16):** the gap-sync functions moved verbatim
    /// from `TandemBackend.swift` into `PumpHistorySyncCoordinator.swift` — this scan now reads THAT
    /// file. `beginGapSync`/`backfillPageDone` dropped their `private` modifier (they're now called
    /// from `TandemBackend.swift`'s wiring closures, a different file — Swift's `private` is file-
    /// scoped) so their two signature strings below match `func` not `private func`; the other 5 are
    /// byte-identical to the pre-move list. The 6 forbidden SYMBOLS are untouched.
    @Test func historySyncSourceHasNoDeliverySeamSymbols() throws {
        let forbidden = ["deliverBolus(", "deliverExtendedBolus(", "InitiateBolusRequest(",
                         "BolusPermissionRequest(", ".allowDelivery", "allowInsulinDelivery: true"]

        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
        let backendURL = repoRoot.appendingPathComponent("ios/faBolus/Data/PumpHistorySyncCoordinator.swift")
        let source = try String(contentsOf: backendURL, encoding: .utf8)

        let gapSyncFunctionSignatures = [
            "static func missingRanges(",
            "static func retentionFloorSequence(",
            "func beginGapSync(",
            "private func advanceToNextGapWindow(",
            "private func requestBackfillPage(",
            "func backfillPageDone(",
            "private func creditCurrentWindowAndAdvance(",
        ]
        for signature in gapSyncFunctionSignatures {
            let slice = try Self.balancedFunctionBody(signaturePrefix: signature, in: source)
            for symbol in forbidden {
                #expect(!slice.contains(symbol), "Forbidden delivery-seam symbol '\(symbol)' found in PumpHistorySyncCoordinator.swift's \(signature) body")
            }
        }
    }

    /// Locate a function by its declaration-line signature prefix and return the source slice from that
    /// line through its balanced closing brace — copied from `NudgeDeliveryBoundaryTests`'s helper so a
    /// future line-shift in `TandemBackend.swift` cannot silently widen or narrow the scanned region.
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
