import XCTest
@testable import faBolusCore

/// Phase 16 16-08 (GO-2 Step 1, REMED-16): `HistorySyncState` relocated from `TandemBackend.swift` into
/// `faBolusCore` per the owner's move-to-core decision. Pins `Equatable` conformance for every case,
/// including the two cases with associated values (`idle(lastSynced:)`/`error(_:)`), so a future
/// refactor of this enum can't silently break the equality the UI/`AppModel` diffing relies on.
final class HistorySyncStateTests: XCTestCase {
    func testIdleEqualityIsKeyedByLastSynced() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HistorySyncState.idle(lastSynced: date), HistorySyncState.idle(lastSynced: date))
        XCTAssertEqual(HistorySyncState.idle(lastSynced: nil), HistorySyncState.idle(lastSynced: nil))
        XCTAssertNotEqual(HistorySyncState.idle(lastSynced: date), HistorySyncState.idle(lastSynced: nil))
        XCTAssertNotEqual(
            HistorySyncState.idle(lastSynced: date),
            HistorySyncState.idle(lastSynced: date.addingTimeInterval(1)))
    }

    func testSyncingAndPausedAreSingletonCases() {
        XCTAssertEqual(HistorySyncState.syncing, HistorySyncState.syncing)
        XCTAssertEqual(HistorySyncState.paused, HistorySyncState.paused)
        XCTAssertNotEqual(HistorySyncState.syncing, HistorySyncState.paused)
    }

    func testErrorEqualityIsKeyedByMessage() {
        XCTAssertEqual(HistorySyncState.error("a"), HistorySyncState.error("a"))
        XCTAssertNotEqual(HistorySyncState.error("a"), HistorySyncState.error("b"))
    }

    func testDistinctCasesAreNeverEqualAcrossCaseBoundaries() {
        let all: [HistorySyncState] = [.idle(lastSynced: nil), .syncing, .paused, .error("x")]
        for i in 0..<all.count {
            for j in 0..<all.count where i != j {
                XCTAssertNotEqual(all[i], all[j], "\(all[i]) must not equal \(all[j])")
            }
        }
    }
}
