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
        let json = #"{"requested":5,"dismissed":2,"actedUpon":3}"#
        let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        #expect(t.requested == 5)
        #expect(t.dismissed == 2)
        #expect(t.actedUpon == 3)
    }

    /// A payload missing one field (as a future required-field addition would produce for every
    /// already-persisted blob) decodes that field to its default, WITHOUT losing the fields that ARE
    /// present — a synthesized decoder would throw here, and the loader's `try?` would then fall back to
    /// an empty dictionary, wiping every category, not just this one.
    @Test func payloadMissingAFieldDefaultsOnlyThatFieldRatherThanZeroingTheRest() throws {
        let json = #"{"requested":5,"dismissed":2}"#  // "actedUpon" absent, as if newly added
        let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        #expect(t.requested == 5, "a field present in the payload must survive a sibling field's absence")
        #expect(t.dismissed == 2, "a field present in the payload must survive a sibling field's absence")
        #expect(t.actedUpon == 0, "the missing field defaults rather than throwing")
    }

    /// The shape actually persisted is a dictionary keyed by category raw value. One entry missing a
    /// field must not drop the OTHER entries — the wholesale-zeroing failure mode a synthesized decoder
    /// plus `try?` would produce at the dictionary level.
    @Test func aDictionaryWithOneEntryMissingAFieldStillDecodesEveryEntry() throws {
        let json = #"""
            {"pumpAlert":{"requested":5,"dismissed":2,"actedUpon":3},
             "pumpDisconnect":{"requested":1,"dismissed":0}}
            """#
        let decoded = try JSONDecoder().decode([String: T].self, from: Data(json.utf8))
        #expect(decoded["pumpAlert"] == T(requested: 5, dismissed: 2, actedUpon: 3))
        #expect(decoded["pumpDisconnect"] == T(requested: 1, dismissed: 0, actedUpon: 0))
    }

    /// Round-trip: encode then decode returns the same value.
    @Test func roundTripsThroughEncodeDecode() throws {
        let original = T(requested: 7, dismissed: 4, actedUpon: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        #expect(decoded == original)
    }

    /// The rename is a RESET of that one field, never a silent reinterpretation. A blob an earlier
    /// build wrote under the old `delivered` key decodes `requested` to 0 (the key is simply absent under
    /// its new name), while the sibling fields it also wrote carry over untouched.
    @Test func aPreRenameBlobUnderTheOldDeliveredKeyDecodesRequestedAsZeroButKeepsItsSiblings() throws {
        let json = #"{"delivered":9,"dismissed":2,"actedUpon":1}"#  // pre-rename key
        let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
        #expect(t.requested == 0, "the old key name is not read under the new field")
        #expect(t.dismissed == 2, "an untouched sibling field survives the rename")
        #expect(t.actedUpon == 1, "an untouched sibling field survives the rename")
    }
}

/// `NotificationBroker.TelemetrySnapshot`'s tolerant-decode conformance: the per-category dict
/// plus a real `windowStart`, mirroring `ConnectionTelemetry.swift`'s own shape one file away.
struct TelemetrySnapshotTests {
    typealias S = NotificationBroker.TelemetrySnapshot
    typealias T = NotificationBroker.CategoryTelemetry

    private func date(_ s: Int) -> Date { Date(timeIntervalSinceReferenceDate: TimeInterval(s)) }

    /// A fresh snapshot starts with no window start and an empty per-category dict — never backfilled.
    @Test func defaultsToNoWindowStartAndAnEmptyDictionary() {
        let s = S()
        #expect(s.windowStart == nil)
        #expect(s.perCategory.isEmpty)
    }

    /// A payload missing `windowStart` (as an old v2 blob written before this field existed would be)
    /// decodes it to `nil`, WITHOUT losing `perCategory` — the same tolerant-decode contract
    /// `CategoryTelemetry` and `ConnectionTelemetry` already honor.
    @Test func aPayloadMissingWindowStartDecodesItAsNilButKeepsPerCategory() throws {
        let json = #"{"perCategory":{"pumpAlert":{"requested":2,"dismissed":0,"actedUpon":1}}}"#
        let decoded = try JSONDecoder().decode(S.self, from: Data(json.utf8))
        #expect(decoded.windowStart == nil)
        #expect(decoded.perCategory["pumpAlert"] == T(requested: 2, dismissed: 0, actedUpon: 1))
    }

    /// A bare-dict blob in the OLD (pre-`TelemetrySnapshot`) shape — `{"category": {...}}` with no
    /// `perCategory` wrapper key at all — decodes WITHOUT error (every one of its top-level keys is simply
    /// unrecognized), but as an EMPTY snapshot: no `perCategory` entries carry over and `windowStart` stays
    /// `nil`. This is exactly the intended reset — a fail-safe reset via tolerant decode, never a
    /// crash and never a silent reinterpretation of the old shape's category counts.
    @Test func aPreWrapperBareDictionaryBlobDecodesAsAnEmptySnapshotRatherThanCarryingOverAnyCategory() throws {
        let json = #"{"pumpAlert":{"requested":2,"dismissed":0,"actedUpon":1}}"#
        let decoded = try JSONDecoder().decode(S.self, from: Data(json.utf8))
        #expect(decoded.perCategory.isEmpty, "the old bare-dict shape's categories must not carry over")
        #expect(decoded.windowStart == nil)
    }

    /// Round-trip: encode then decode returns the same value, including a set `windowStart`.
    @Test func roundTripsThroughEncodeDecode() throws {
        let original = S(perCategory: ["pumpDisconnect": T(requested: 3, dismissed: 1, actedUpon: 0)], windowStart: date(1000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(S.self, from: data)
        #expect(decoded == original)
    }
}
