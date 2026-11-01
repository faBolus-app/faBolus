import Foundation
import Testing

@testable import RemoteProtocol

@Suite struct LegacyV1Tests {
    @Test func everyVersionOneKindIsRecognized() {
        for kind in LegacyV1.kinds {
            let received = RemoteMessage.receive(
                .object(["version": .int(1), "kind": .string(kind), "requestId": .string("r1")]))
            #expect(received == .legacy(.init(kind: kind, requestId: "r1")), "\(kind)")
        }
    }

    /// Neither version can read the other's kinds as its own.
    @Test func noKindNameIsShared() {
        #expect(LegacyV1.kinds.isDisjoint(with: RemoteMessage.Kind.allCases.map(\.rawValue)))
    }

    /// A version 2 message read by the rule the old phone applied (`version` must be 1) is refused there.
    @Test func versionTwoMessagesCarryVersionTwo() {
        for fixture in GoldenFixtures.fixtures {
            guard let message = fixture.message, case .object(let o) = message.wire else { continue }
            #expect(o["version"] == .int(2), "\(fixture.name)")
        }
    }

    @Test func aBolusRequestIsAnsweredAsFailed() throws {
        let reply = try #require(LegacyV1.reply(to: .init(kind: "bolusRequest", requestId: "r9")))
        guard case .object(let o) = reply else {
            Issue.record("not an object")
            return
        }
        #expect(o["kind"] == .string("bolusStatus"))
        #expect(o["requestId"] == .string("r9"))
        #expect(o["status"] == .string("failed"))
        #expect(o["version"] == .int(1))
    }

    /// Everything else gets a status that turns bolusing off on the old watch and says why where it shows
    /// the pump's connection.
    @Test func anythingElseIsAnsweredWithADisablingStatus() throws {
        for kind in LegacyV1.kinds.subtracting(["bolusRequest"]) {
            let reply = try #require(LegacyV1.reply(to: .init(kind: kind, requestId: "r1")))
            guard case .object(let o) = reply else { continue }
            #expect(o["kind"] == .string("statusRead"), "\(kind)")
            #expect(o["requestId"] == .string("r1"), "\(kind)")
            #expect(o["canBolus"] == .bool(false), "\(kind)")
            #expect(o["remotesReadOnly"] == .bool(true), "\(kind)")
            #expect(o["message"] == .string(LegacyV1.updateWatchLabel), "\(kind)")
        }
    }

    /// The old watch correlates by request ID; without one there's nothing it would show.
    @Test func noReplyWithoutARequestId() {
        #expect(LegacyV1.reply(to: .init(kind: "statusRead", requestId: nil)) == nil)
        #expect(
            RemoteMessage.receive(.object(["version": .int(1), "kind": .string("statusRead")]))
                == .legacy(.init(kind: "statusRead", requestId: nil)))
    }

    /// The old watch never read `version`, so a versionless old message is still recognized.
    @Test func aVersionlessOldMessageIsLegacy() {
        #expect(
            RemoteMessage.receive(.object(["kind": .string("bolusRequest"), "requestId": .string("r2")]))
                == .legacy(.init(kind: "bolusRequest", requestId: "r2")))
    }
}

@Suite struct OutcomeTokenTests {
    /// The same moves as the phone's own outcome table, plus `received` (the phone has the request).
    @Test func aSettledOutcomeNeverMovesBack() {
        for from in OutcomeToken.allCases where from.isFinal {
            for to in OutcomeToken.allCases { #expect(!from.canMove(to: to), "\(from) → \(to)") }
        }
        #expect(!OutcomeToken.delivering.canMove(to: .accepted))
        #expect(!OutcomeToken.unknown.canMove(to: .delivering))
        #expect(!OutcomeToken.unknown.canMove(to: .refused))
        #expect(OutcomeToken.unknown.canMove(to: .failed))
        #expect(OutcomeToken.received.canMove(to: .delivered))
        for to in OutcomeToken.allCases { #expect(!to.canMove(to: .received)) }
    }

    @Test func aDuplicateIsNotAMove() {
        for token in OutcomeToken.allCases { #expect(!token.canMove(to: token)) }
    }
}

@Suite struct ConfigRevisionTests {
    @Test func theRevisionFollowsTheContent() {
        var c = GoldenFixtures.config
        let before = c.revision
        #expect(before.count == 16)
        #expect(c.revision == before)
        c.glucoseHideDelayMinutes = 10
        #expect(c.revision != before)
        c.glucoseHideDelayMinutes = nil
        #expect(c.revision == before)
    }
}
