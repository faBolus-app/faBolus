import Testing
import Foundation
@testable import faBolusCore

/// `ConnectionTelemetry`'s hand-written `Codable` conformance is the house safe-decode pattern: every
/// persisted blob predates at least one field this type has since gained, so every field decodes with
/// `decodeIfPresent` rather than a synthesized decoder that would throw on a missing key and — via the
/// store's `try? decode` — silently zero the shipped counters.
struct ConnectionTelemetryTests {

    /// MIGRATION GUARD: a blob persisted before `windowStart` existed (no such key) must upgrade in
    /// place — the shipped connect/uptime/disconnect/reconcile counters MUST survive, not reset to
    /// zero, and `windowStart` reads nil rather than throwing.
    @Test func legacyBlobWithoutWindowStartDecodesAndPreservesCounters() throws {
        let old = #"""
            {"connectCount":3,"totalUptimeSeconds":600,"disconnects":{"btOff":2},
             "reconcile":{"delivered":1},"commandLatency":{"lt500ms":1}}
            """#
        let t = try JSONDecoder().decode(ConnectionTelemetry.self, from: Data(old.utf8))
        #expect(t.connectCount == 3)
        #expect(t.totalUptimeSeconds == 600)
        #expect(t.disconnects["btOff"] == 2)
        #expect(t.reconcile["delivered"] == 1)
        #expect(t.commandLatency["lt500ms"] == 1)
        #expect(t.windowStart == nil)
    }

    /// A blob that DOES carry `windowStart` decodes it back out unchanged (round-trip).
    @Test func windowStartRoundTripsThroughEncodeDecode() throws {
        let original = ConnectionTelemetry(connectCount: 1, windowStart: Date(timeIntervalSince1970: 1_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionTelemetry.self, from: data)
        #expect(decoded.windowStart == original.windowStart)
        #expect(decoded.connectCount == 1)
    }
}
