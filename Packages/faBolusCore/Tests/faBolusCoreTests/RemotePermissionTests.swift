import XCTest
@testable import faBolusCore

final class RemotePermissionTests: XCTestCase {
    func testViewOnlyGrantsNothing() {
        let p = RemotePeerPolicy.viewOnly
        for perm in RemotePermission.allCases { XCTAssertFalse(p.allows(perm)) }
        XCTAssertEqual(p.approvalMode, .auto)
    }

    func testLegacyFullGrantsEverything() {
        let p = RemotePeerPolicy.legacyFull
        for perm in RemotePermission.allCases { XCTAssertTrue(p.allows(perm)) }
    }

    func testGrantSubset() {
        let p = RemotePeerPolicy(permissions: [.bolus, .cancelBolus], approvalMode: .hostApproval)
        XCTAssertTrue(p.allows(.bolus))
        XCTAssertTrue(p.allows(.cancelBolus))
        XCTAssertFalse(p.allows(.suspendResume))
        XCTAssertFalse(p.allows(.dismissAlerts))
        XCTAssertEqual(p.approvalMode, .hostApproval)
    }

    func testCodableRoundTrip() throws {
        let p = RemotePeerPolicy(permissions: [.bolus, .extendedBolus], approvalMode: .hostApproval)
        let data = try JSONEncoder().encode(["c1": p])
        let back = try JSONDecoder().decode([String: RemotePeerPolicy].self, from: data)
        XCTAssertEqual(back["c1"], p)
    }
}
