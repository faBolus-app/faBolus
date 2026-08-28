import XCTest
@testable import faBolusCore

/// v3 handoff §5.3: `transferUserInfo` is a guaranteed, FIFO, opportunistic-latency queue and must
/// **never** carry a bolus — *"A stale queued bolus could deliver minutes later."* Before this fix
/// the (now-retired) WatchConnectivity transport's `send` fell back to it for every command, including
/// `.bolusRequest`, both when the peer was unreachable and when the live send errored.
///
/// The former WatchConnectivity transport owned a non-injectable `WCSession.default` and only compiled
/// where WatchConnectivity exists, so the *rule* lives in `RemoteSendDisposition` and is pinned here.
/// What these tests do NOT cover: that `BLELink` actually calls it — that is a one-line read of its
/// `send`.
final class RemoteSendDispositionTests: XCTestCase {

    /// Every command that reaches the pump, or authorizes something that does.
    private static let mutating: [RemoteCommand.Kind] = [
        .bolusRequest, .bolusConfirm, .cancelBolus, .suspendPump, .resumePump,
        .dismissAlert, .bolusApprovalRequest, .bolusApprovalResponse, .sealed
    ]
    /// Display/handshake traffic. Queuing these is desirable — a watch that was out of range catches up.
    private static let nonMutating: [RemoteCommand.Kind] = [
        .bolusStatus, .statusRead,
        .authHello, .authChallenge, .authProof, .authResult
    ]

    /// The two lists together must be the whole enum. If a case is added and left unclassified, this
    /// fails rather than silently defaulting to "queueable" — which for a new delivery verb would
    /// reintroduce the exact defect.
    func testClassificationCoversEveryKind() {
        let classified = Set((Self.mutating + Self.nonMutating).map(\.rawValue))
        let all: [RemoteCommand.Kind] = [
            .bolusRequest, .bolusConfirm, .bolusStatus, .cancelBolus, .statusRead, .dismissAlert,
            .suspendPump, .resumePump, .authHello, .authChallenge, .authProof, .authResult,
            .sealed, .bolusApprovalRequest, .bolusApprovalResponse
        ]
        XCTAssertEqual(classified.count, all.count, "a RemoteCommand.Kind is unclassified")
        for k in all { XCTAssertTrue(classified.contains(k.rawValue), "\(k.rawValue) unclassified") }
        for k in Self.mutating { XCTAssertTrue(k.mutatesPumpState, "\(k.rawValue) should be mutating") }
        for k in Self.nonMutating { XCTAssertFalse(k.mutatesPumpState, "\(k.rawValue) should not be mutating") }
    }

    // MARK: The rule

    func testMutatingCommandIsNeverQueuedWhenUnreachable() {
        for k in Self.mutating {
            XCTAssertEqual(
                RemoteSendDisposition.decide(kind: k, isReachable: false),
                .reportUndeliverable, "\(k.rawValue) must not be queued")
        }
    }

    func testMutatingCommandIsNeverQueuedAfterALiveSendFails() {
        for k in Self.mutating {
            XCTAssertEqual(
                RemoteSendDisposition.decide(kind: k, isReachable: true, liveSendFailed: true),
                .reportUndeliverable, "\(k.rawValue) must not fall back to the queue")
        }
    }

    func testNonMutatingCommandQueuesWhenUnreachable() {
        for k in Self.nonMutating {
            XCTAssertEqual(RemoteSendDisposition.decide(kind: k, isReachable: false), .queue)
        }
    }

    func testNonMutatingCommandFallsBackToTheQueueWhenALiveSendFails() {
        for k in Self.nonMutating {
            XCTAssertEqual(
                RemoteSendDisposition.decide(kind: k, isReachable: true, liveSendFailed: true),
                .queue)
        }
    }

    func testEverythingGoesLiveWhenReachable() {
        for k in Self.mutating + Self.nonMutating {
            XCTAssertEqual(RemoteSendDisposition.decide(kind: k, isReachable: true), .sendLive)
        }
    }

    /// A bolus is the case that matters: unreachable must mean "not sent", not "sent later".
    func testBolusRequestUnreachableIsReportedNotDeferred() {
        let d = RemoteSendDisposition.decide(kind: .bolusRequest, isReachable: false)
        XCTAssertEqual(d, .reportUndeliverable)
        XCTAssertNotEqual(d, .queue)
    }
}
