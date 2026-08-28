import Testing
import Foundation
@testable import faBolus

/// **I-L1.** Pins `GarminHistoryCap` — the pure, ConnectIQ-free cap of the outbound Garmin status
/// history array to the watch-plot point budget, applied bridge-side (`GarminRemoteBridge`) BEFORE
/// send. Lives OUTSIDE `#if GARMIN` (mirrors `garminSendDisposition`/`GarminMessageReadiness`) so it
/// compiles and is unit-testable in the default (non-GARMIN) target.
///
/// LOAD-BEARING CONTEXT: every status push previously sent the FULL history array with no size bound
/// (`GarminRemoteBridge.swift`'s `includeHistory:true` send sites). An oversize payload risks the SAME
/// `InsufficientMemory`/`UnsupportedType` failure I-M3 now classifies as PERMANENT (dropped, no retry)
/// — so a status push that never needed the extra points could silently stall the watch chart forever
/// (T-19-20). The cap is newest-tail, order-preserving: the watch plot only ever shows the MOST RECENT
/// points, so trimming the OLDEST ones first is the only trim that doesn't visibly break the chart.
struct GarminHistoryCapTests {

    @Test func shortArrayIsReturnedUnchanged() {
        let points = [1, 2, 3]
        #expect(GarminHistoryCap.cap(points) == points)
    }

    @Test func arrayExactlyAtBudgetIsReturnedUnchanged() {
        let points = Array(0..<GarminHistoryCap.pointBudget)
        #expect(GarminHistoryCap.cap(points) == points)
    }

    /// The key invariant: an oversize array is trimmed to the newest-tail `pointBudget` elements,
    /// preserving order (oldest→newest within the kept subset) — never the OLDEST points, which the
    /// watch plot doesn't show anyway.
    @Test func oversizeArrayKeepsNewestTailPreservingOrder() {
        let points = Array(0..<(GarminHistoryCap.pointBudget + 50))
        let capped = GarminHistoryCap.cap(points)
        #expect(capped.count == GarminHistoryCap.pointBudget)
        #expect(capped == Array(points.suffix(GarminHistoryCap.pointBudget)))
        #expect(capped.first == 50, "the OLDEST 50 points must be the ones trimmed, not the newest")
        #expect(capped.last == points.last)
    }

    @Test func emptyArrayStaysEmpty() {
        let points: [Int] = []
        #expect(GarminHistoryCap.cap(points).isEmpty)
    }

    /// `cap` is generic — must also work on the paired `historyEpochs` timestamp array (same shape,
    /// different element type), so BOTH arrays cap to the same tail length and stay aligned.
    @Test func genericOverDoubleElementsAlsoCaps() {
        let epochs = (0..<(GarminHistoryCap.pointBudget + 10)).map { Double($0) }
        let capped = GarminHistoryCap.cap(epochs)
        #expect(capped.count == GarminHistoryCap.pointBudget)
        #expect(capped == Array(epochs.suffix(GarminHistoryCap.pointBudget)))
    }

    // MARK: garminCapStatusHistory — the dict-level transform applied at the bridge's send() choke point

    @Test func dictWithoutHistoryKeyPassesThroughUnchanged() {
        let dict: [String: Any] = ["kind": "bolusStatus", "requestId": "abc"]
        let out = garminCapStatusHistory(dict)
        #expect(out["kind"] as? String == "bolusStatus")
        #expect(out["requestId"] as? String == "abc")
        #expect(out["history"] == nil)
    }

    @Test func dictWithOversizeHistoryAndEpochsCapsBothToSameAlignedTail() {
        let n = GarminHistoryCap.pointBudget + 20
        let dict: [String: Any] = [
            "kind": "statusRead",
            "history": Array(0..<n),
            "historyEpochs": Array(0..<n)
        ]
        let out = garminCapStatusHistory(dict)
        let history = out["history"] as? [Int]
        let epochs = out["historyEpochs"] as? [Int]
        #expect(history?.count == GarminHistoryCap.pointBudget)
        #expect(epochs?.count == GarminHistoryCap.pointBudget)
        #expect(
            history == epochs,
            "history/historyEpochs must cap to the SAME tail so points stay aligned to their timestamps")
        #expect(history?.last == n - 1)
    }

    @Test func dictWithShortHistoryPassesThroughUnchanged() {
        let dict: [String: Any] = ["history": [1, 2, 3], "historyEpochs": [10, 20, 30]]
        let out = garminCapStatusHistory(dict)
        #expect(out["history"] as? [Int] == [1, 2, 3])
        #expect(out["historyEpochs"] as? [Int] == [10, 20, 30])
    }
}
