import Foundation
import Testing
@testable import faBolusCore

/// Every `BolusOutcome` transition, allowed and refused, through the ledger that owns it.
struct BolusOutcomeTests {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// One representative of every outcome.
    private static let all: [BolusOutcome] = [
        .requested, .accepted, .delivering, .delivered(units: 2), .stopped(delivered: 1, requested: 2),
        .refused(reason: "no cartridge"), .failed(reason: "not connected"), .unknown(since: t0)
    ]

    private static func name(_ o: BolusOutcome) -> String {
        switch o {
        case .requested: return "requested"
        case .accepted: return "accepted"
        case .delivering: return "delivering"
        case .delivered: return "delivered"
        case .stopped: return "stopped"
        case .refused: return "refused"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }

    /// The whole table of allowed moves, from the diagram on `BolusOutcome`.
    private static let allowed: Set<String> = [
        "requested>accepted", "requested>refused", "requested>failed", "requested>unknown",
        "accepted>delivering", "accepted>delivered", "accepted>stopped", "accepted>refused", "accepted>failed",
        "accepted>unknown",
        "delivering>delivered", "delivering>stopped", "delivering>unknown",
        "unknown>delivered", "unknown>stopped"
    ]

    @Test func everyPairFollowsTheTable() {
        for from in Self.all {
            for to in Self.all {
                let pair = "\(Self.name(from))>\(Self.name(to))"
                #expect(from.canMove(to: to) == Self.allowed.contains(pair), "\(pair)")
            }
        }
    }

    @Test func finalOutcomesNeverMove() {
        for from in Self.all where from.isFinal {
            for to in Self.all { #expect(!from.canMove(to: to), "\(Self.name(from)) is final") }
        }
    }

    /// An unknown outcome is never turned into a failure or a refusal; only a delivered amount the
    /// pump reports can settle it.
    @Test func unknownIsNeverCalledFailed() {
        #expect(!BolusOutcome.unknown(since: Self.t0).canMove(to: .failed(reason: "x")))
        #expect(!BolusOutcome.unknown(since: Self.t0).canMove(to: .refused(reason: "x")))
        #expect(!BolusOutcome.delivering.canMove(to: .failed(reason: "x")))
        #expect(!BolusOutcome.delivering.canMove(to: .refused(reason: "x")))
    }

    @Test func classification() {
        #expect(Self.all.filter(\.isFinal).map(Self.name) == ["delivered", "stopped", "refused", "failed"])
        #expect(Self.all.filter(\.isInFlight).map(Self.name) == ["requested", "accepted", "delivering"])
        #expect(Self.all.filter(\.isUnknown).map(Self.name) == ["unknown"])
        #expect(
            Self.all.filter(\.mayHaveDelivered).map(Self.name)
                == ["accepted", "delivering", "delivered", "stopped", "unknown"])
        #expect(!BolusOutcome.delivered(units: 0).mayHaveDelivered)
        #expect(!BolusOutcome.stopped(delivered: 0, requested: 2).mayHaveDelivered)
    }

    @Test func deliveredBelowTheRequestIsStopped() {
        #expect(BolusOutcome.settled(deliveredUnits: 2, requestedUnits: 2) == .delivered(units: 2))
        #expect(BolusOutcome.settled(deliveredUnits: 1.5, requestedUnits: 2) == .stopped(delivered: 1.5, requested: 2))
        #expect(BolusOutcome.settled(deliveredUnits: 0, requestedUnits: 2) == .stopped(delivered: 0, requested: 2))
        // Within half a milliunit is decoding noise, not a stop.
        #expect(BolusOutcome.settled(deliveredUnits: 1.9996, requestedUnits: 2) == .delivered(units: 1.9996))
        #expect(
            BolusOutcome.settled(deliveredUnits: 1.999, requestedUnits: 2) == .stopped(delivered: 1.999, requested: 2))
        #expect(BolusOutcome.stopped(delivered: 1.5, requested: 2).deliveredUnits == 1.5)
        #expect(BolusOutcome.unknown(since: Self.t0).deliveredUnits == nil)
    }

    // MARK: - Through the ledger

    private static let key = RemoteBolusLedger.Key(peerId: "garmin", requestId: "r1")

    /// A ledger holding the one request, moved to `outcome` by the shortest legal path.
    private static func ledger(at outcome: BolusOutcome) -> RemoteBolusLedger {
        var l = RemoteBolusLedger()
        let request = DoseRequest(
            id: key.requestId, origin: .remote(peerId: key.peerId, sentAt: t0), shape: .now(units: 2))
        _ = l.begin(request, now: t0)
        switch outcome {
        case .requested: break
        case .accepted: l.markAccepted(key, bolusId: 1)
        case .delivering:
            l.markAccepted(key, bolusId: 1)
            l.markDelivering(key)
        case .delivered:
            l.markAccepted(key, bolusId: 1)
            l.markDelivered(key, units: 2)
        case .stopped:
            l.markAccepted(key, bolusId: 1)
            l.markDelivered(key, units: 1)
        case .refused(let reason): l.markRefused(key, reason: reason)
        case .failed(let reason): l.markFailed(key, reason: reason)
        case .unknown(let since): l.markUnknown(key, now: since)
        }
        return l
    }

    /// Apply the ledger transition that would produce `to`.
    private static func apply(_ to: BolusOutcome, to l: inout RemoteBolusLedger) -> Bool {
        switch to {
        case .requested: return false  // nothing moves back to requested
        case .accepted: return l.markAccepted(key, bolusId: 1)
        case .delivering: return l.markDelivering(key)
        case .delivered: return l.markDelivered(key, units: 2)
        case .stopped: return l.markDelivered(key, units: 1)
        case .refused(let reason): return l.markRefused(key, reason: reason)
        case .failed(let reason): return l.markFailed(key, reason: reason)
        case .unknown(let since): return l.markUnknown(key, now: since)
        }
    }

    /// The ledger applies exactly the moves the table allows, and leaves the outcome alone otherwise.
    @Test func theLedgerAppliesOnlyAllowedMoves() {
        for from in Self.all {
            for to in Self.all {
                var l = Self.ledger(at: from)
                #expect(l.outcome(Self.key) == from, "setup reached \(Self.name(from))")
                let applied = Self.apply(to, to: &l)
                let pair = "\(Self.name(from))>\(Self.name(to))"
                #expect(applied == Self.allowed.contains(pair), "\(pair)")
                #expect(l.outcome(Self.key) == (applied ? to : from), "\(pair)")
            }
        }
    }

    @Test func aNonFiniteOrNegativeDeliveredAmountIsNotAReading() {
        for bad in [Double.nan, .infinity, -1] {
            var l = Self.ledger(at: .delivering)
            let applied = l.markDelivered(Self.key, units: bad)
            #expect(!applied)
            #expect(l.outcome(Self.key) == .delivering)
        }
    }

    @Test func transitionsOnAnUnknownRequestDoNothing() {
        var l = RemoteBolusLedger()
        let missing = RemoteBolusLedger.Key(peerId: "nobody", requestId: "none")
        let applied = [
            l.markAccepted(missing, bolusId: 1), l.markDelivering(missing), l.markUnknown(missing),
            l.markDelivered(missing, units: 1), l.markRefused(missing, reason: "x"),
            l.markFailed(missing, reason: "x"), l.confirmOnPump(missing)
        ]
        #expect(applied.allSatisfy { !$0 })
        #expect(l.allEntries.isEmpty)
    }
}
