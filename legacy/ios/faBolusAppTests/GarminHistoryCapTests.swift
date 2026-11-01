import Testing
import Foundation
@testable import faBolus

/// Pins that outbound Garmin history is newest-tail capped to the watch-plot budget before send. An oversize payload can fail permanently and stall the watch chart.
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
