import Foundation
import Testing

@testable import RemoteProtocol

/// A message is either read in full or refused: nothing out of range, mistyped or contradictory gets in.
@Suite struct DecodeTests {
    private func message(_ kind: String, _ payload: [String: WireValue]) -> WireValue {
        .object(["version": .int(2), "kind": .string(kind), "payload": .object(payload)])
    }

    private func payload(of fixture: String) -> [String: WireValue] {
        guard let f = GoldenFixtures.fixtures.first(where: { $0.name == fixture }),
            case .object(let o) = f.wire, case .object(let p)? = o["payload"]
        else { return [:] }
        return p
    }

    private func refused(_ value: WireValue) -> Bool {
        if case .malformed = RemoteMessage.receive(value) { return true }
        return false
    }

    /// The watch's 32-bit floats would change a dose in transit, so insulin is never a float.
    @Test func aFloatWhereAnIntegerBelongsIsRefused() {
        var p = payload(of: "bolus-units")
        p["mU"] = .double(4000)
        #expect(refused(message("bolus", p)))
        p["mU"] = .double(4.0)
        #expect(refused(message("bolus", p)))
    }

    @Test func outOfRangeValuesAreRefused() {
        var p = payload(of: "bolus-units")
        p["mU"] = .int(-50)
        #expect(refused(message("bolus", p)))
        p = payload(of: "bolus-carbs")
        p["carbsG"] = .int(1000)
        #expect(refused(message("bolus", p)))
        p = payload(of: "bolus-units")
        p["sentAt"] = .int(0)
        #expect(refused(message("bolus", p)))
        p["sentAt"] = .int(2_147_483_648)
        #expect(refused(message("bolus", p)))
    }

    /// The last auto-correction is a time and nothing else: absent reads as none known, and a time out of
    /// range or of the wrong type is refused rather than read as zero.
    @Test func theLastAutoCorrectionIsATimeOnly() {
        var p = payload(of: "status")
        guard case .message(.status(let golden)) = RemoteMessage.receive(message("status", p)) else {
            Issue.record("golden status didn't read")
            return
        }
        #expect(golden.lastAutoCorrectionAt == GoldenFixtures.now - 2700)
        p["lastAutoCorrection"] = nil
        guard case .message(.status(let none)) = RemoteMessage.receive(message("status", p)) else {
            Issue.record("status without it didn't read")
            return
        }
        #expect(none.lastAutoCorrectionAt == nil)
        p["lastAutoCorrection"] = .object(["at": .int(0)])
        #expect(refused(message("status", p)))
        p["lastAutoCorrection"] = .object(["at": .double(1_793_534_400)])
        #expect(refused(message("status", p)))
    }

    /// A window of 0 minutes, the phone's "nothing counts as current", reads as itself; below 0 is refused.
    @Test func aZeroMinuteWindowIsAWindow() {
        var config = GoldenFixtures.config
        config.glucoseStaleMinutes = 0
        config.iobStaleMinutes = 0
        config.therapyStaleMinutes = 0
        config.pumpStatusStaleMinutes = 0
        guard case .message(.config(let read)) = RemoteMessage.receive(RemoteMessage.config(config).wire) else {
            Issue.record("a config with zero windows didn't read")
            return
        }
        #expect(read == config)
        config.iobStaleMinutes = -1
        #expect(refused(RemoteMessage.config(config).wire))
    }

    @Test func aMissingOrEmptyRequestIdIsRefused() {
        var p = payload(of: "bolus-units")
        p["requestId"] = nil
        #expect(refused(message("bolus", p)))
        p["requestId"] = .string("")
        #expect(refused(message("bolus", p)))
        p["requestId"] = .string(String(repeating: "x", count: 65))
        #expect(refused(message("bolus", p)))
    }

    /// A carb request needs the watch's estimate; a units request needs its units.
    @Test func eachModeNeedsItsAmount() {
        var p = payload(of: "bolus-carbs")
        p["estimateMU"] = nil
        #expect(refused(message("bolus", p)))
        p = payload(of: "bolus-units")
        p["mode"] = .string("carbs")
        #expect(refused(message("bolus", p)))
        p = payload(of: "bolus-units")
        p["mode"] = .string("extended")
        #expect(refused(message("bolus", p)))
    }

    @Test func aStatusWhoseGateContradictsItselfIsRefused() {
        var p = payload(of: "status")
        p["bolus"] = .object(["canBolus": .bool(true), "blockReason": .string("readOnly")])
        #expect(refused(message("status", p)))
        p["bolus"] = .object(["canBolus": .bool(false)])
        #expect(refused(message("status", p)))
    }

    @Test func unknownTokensAreRefused() {
        var p = payload(of: "status")
        p["pumpLink"] = .string("teleporting")
        #expect(refused(message("status", p)))
        p = payload(of: "bolusOutcome-delivered")
        p["outcome"] = .string("probably")
        #expect(refused(message("bolusOutcome", p)))
    }

    /// The revision is the content's digest; one that doesn't match is a corrupt config, not one to adopt.
    @Test func aConfigWhoseRevisionDoesNotMatchIsRefused() {
        var p = payload(of: "config")
        p["revision"] = .string("0000000000000000")
        #expect(refused(message("config", p)))
        p = payload(of: "config")
        p["chartHours"] = .array([.int(3)])
        #expect(refused(message("config", p)))
    }

    @Test func aConfigWithAnImpossibleLayoutIsRefused() {
        var p = payload(of: "config")
        p["screens"] = .object(["order": .array([.string("glance")]), "default": .string("details")])
        #expect(refused(message("config", p)))
        p = payload(of: "config")
        p["chartHours"] = .array([.int(5)])
        #expect(refused(message("config", p)))
        p = payload(of: "config")
        p["details"] = .array([.string("iob"), .string("iob")])
        #expect(refused(message("config", p)))
    }

    @Test func historyMustBeAlignedAndInOrder() {
        var p = payload(of: "history")
        p["mgdl"] = .array([.int(100)])
        #expect(refused(message("history", p)))
        p = payload(of: "history")
        p["at"] = .array([.int(GoldenFixtures.now), .int(GoldenFixtures.now - 300)])
        p["mgdl"] = .array([.int(100), .int(110)])
        #expect(refused(message("history", p)))
    }

    @Test func historyIsCappedToTheNewestPoints() {
        let points = (0..<300).map { HistoryPayload.Point(at: GoldenFixtures.now - $0 * 300, mgdl: 100 + $0 % 50) }
        let h = HistoryPayload.newest(points, sentAt: GoldenFixtures.now)
        #expect(h.points.count == WireLimits.maxHistoryPoints)
        #expect(h.points.last?.at == GoldenFixtures.now)
        #expect(h.points == h.points.sorted { $0.at < $1.at })
        #expect(RemoteMessage.receive(RemoteMessage.history(h).wire) == .message(.history(h)))
    }

    @Test func tooManyAlertsAreRefused() {
        var p = payload(of: "status")
        let alert = AlertItem(id: "a", title: "t", body: "b", severity: .info, intent: .quiet, dismissable: false).wire
        p["alerts"] = .array(Array(repeating: alert, count: WireLimits.maxListCount + 1))
        #expect(refused(message("status", p)))
    }

    @Test func messagesThatArentAnyVersionAreUnrecognized() {
        #expect(RemoteMessage.receive(.string("hello")) == .unrecognized)
        #expect(RemoteMessage.receive(.object([:])) == .unrecognized)
        #expect(RemoteMessage.receive(.object(["version": .int(0), "kind": .string("status")])) == .unrecognized)
        #expect(RemoteMessage.receive(.object(["version": .string("2")])) == .unrecognized)
        #expect(RemoteMessage.receive(.object(["kind": .string("poll")])) == .unrecognized)
    }

    @Test func aNewerVersionIsReportedNotRead() {
        #expect(RemoteMessage.receive(.object(["version": .int(3), "kind": .string("status")])) == .otherVersion(3))
    }

    @Test func versionTwoWithAnUnknownKindIsMalformed() {
        #expect(refused(message("statusRead", [:])))
        #expect(refused(.object(["version": .int(2), "kind": .string("status")])))
    }

    /// Foundation hides booleans and floats inside NSNumber; the bridge tells them apart.
    @Test func theFoundationBridgeKeepsNumberKinds() throws {
        let bridged = try WireValue(foundation: [
            "b": NSNumber(value: true), "i": NSNumber(value: 42), "d": NSNumber(value: 2.5),
            "l": NSNumber(value: Int64(1_793_534_400)), "f": NSNumber(value: Float(0.5))
        ])
        #expect(
            bridged
                == .object([
                    "b": .bool(true), "i": .int(42), "d": .double(2.5), "l": .int(1_793_534_400), "f": .double(0.5)
                ]))
        #expect(throws: WireValue.ConversionError.self) { try WireValue(foundation: Date()) }
    }

    @Test func canonicalJSONIsStableAndEscaped() throws {
        let value = WireValue.object(["b": .string("a/\"q\"\n"), "a": .array([.int(1), .null]), "c": .object([:])])
        #expect(
            value.canonicalJSON
                == "{\n  \"a\": [\n    1,\n    null\n  ],\n  \"b\": \"a/\\\"q\\\"\\n\",\n  \"c\": {}\n}\n")
        #expect(try WireValue(json: Data(value.canonicalJSON.utf8)) == value)
    }
}
