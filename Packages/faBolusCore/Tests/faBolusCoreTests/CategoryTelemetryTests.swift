import Testing
import Foundation
@testable import faBolusCore

/// `NotificationBroker.CategoryTelemetry`'s hand-written `Codable` conformance follows the house
/// safe-decode pattern (`ConnectionTelemetry.swift`): every field decodes with `decodeIfPresent` rather
/// than a synthesized decoder that would throw on a missing key and — via the loader's `try? decode` —
/// silently zero every OTHER category in the persisted dictionary too, not just the one field that is
/// missing.
struct CategoryTelemetryTests {
    typealias T = NotificationBroker.CategoryTelemetry

    /// A payload written with today's three fields decodes intact.
    @Test func fullPayloadDecodesIntact() throws {
        let json = #"{"delivered":5,"dismissed":2,"actedUpon":3}"#
        let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        #expect(t.delivered == 5)
        #expect(t.dismissed == 2)
        #expect(t.actedUpon == 3)
    }

    /// A payload missing one field (as a future required-field addition would produce for every
    /// already-persisted blob) decodes that field to its default, WITHOUT losing the fields that ARE
    /// present — a synthesized decoder would throw here, and the loader's `try?` would then fall back to
    /// an empty dictionary, wiping every category, not just this one.
    @Test func payloadMissingAFieldDefaultsOnlyThatFieldRatherThanZeroingTheRest() throws {
        let json = #"{"delivered":5,"dismissed":2}"#  // "actedUpon" absent, as if newly added
        let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        #expect(t.delivered == 5, "a field present in the payload must survive a sibling field's absence")
        #expect(t.dismissed == 2, "a field present in the payload must survive a sibling field's absence")
        #expect(t.actedUpon == 0, "the missing field defaults rather than throwing")
    }

    /// The shape actually persisted is a dictionary keyed by category raw value. One entry missing a
    /// field must not drop the OTHER entries — the wholesale-zeroing failure mode a synthesized decoder
    /// plus `try?` would produce at the dictionary level.
    @Test func aDictionaryWithOneEntryMissingAFieldStillDecodesEveryEntry() throws {
        let json = #"""
            {"pumpAlert":{"delivered":5,"dismissed":2,"actedUpon":3},
             "pumpDisconnect":{"delivered":1,"dismissed":0}}
            """#
        let decoded = try JSONDecoder().decode([String: T].self, from: Data(json.utf8))
        #expect(decoded["pumpAlert"] == T(delivered: 5, dismissed: 2, actedUpon: 3))
        #expect(decoded["pumpDisconnect"] == T(delivered: 1, dismissed: 0, actedUpon: 0))
    }

    /// Round-trip: encode then decode returns the same value.
    @Test func roundTripsThroughEncodeDecode() throws {
        let original = T(delivered: 7, dismissed: 4, actedUpon: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == original)
    }
}
