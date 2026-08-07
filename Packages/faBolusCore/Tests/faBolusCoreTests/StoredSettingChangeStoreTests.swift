import Testing
import Foundation
@testable import faBolusCore

/// P14 S7. The provenance / change-log sidecar: atomic-write + fail-closed persistence (mirroring
/// `RemoteBolusLedgerStore`), and the OQ6 stable-key guarantee (keyed on a segment's start time, not its
/// renumbering index).
struct StoredSettingChangeStoreTests {

    private func tempStore() -> StoredSettingChangeStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setting-change-\(UUID().uuidString).json")
        return StoredSettingChangeStore(url: url)
    }

    private func change(_ key: SettingKey, before: BackupValue?, after: BackupValue,
                        _ prov: SettingProvenance, at: Int) -> StoredSettingChange {
        StoredSettingChange(key: key, before: before, after: after, provenance: prov, atSeconds: at)
    }

    // MARK: Persistence — fresh / round-trip / corrupt / newer-version

    @Test func freshInstallLoadsEmptyAndNotFailed() {
        let s = tempStore()
        let out = s.loadOutcome()
        #expect(out.log.latest.isEmpty && out.log.log.isEmpty)
        #expect(!out.failedClosed)                 // no file ≠ corrupt
    }

    @Test func saveThenLoadRoundTrips() throws {
        let s = tempStore()
        var log = SettingChangeLog()
        log.record(change(.segment(idpId: 1, startMinutes: 480, field: "basalRate"),
                          before: .double(0.8), after: .double(1.0), .clinicianSet, at: 100), cap: 512)
        try s.save(log)
        let out = s.loadOutcome()
        #expect(!out.failedClosed)
        #expect(out.log == log)                    // byte-exact round-trip through JSON
        #expect(out.log.provenance(.segment(idpId: 1, startMinutes: 480, field: "basalRate")) == .clinicianSet)
    }

    @Test func corruptFileFailsClosedButEmpty() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setting-change-corrupt-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        let out = StoredSettingChangeStore(url: url).loadOutcome()
        #expect(out.failedClosed)                  // existing-but-unreadable ⇒ flagged, not mis-decoded
        #expect(out.log.latest.isEmpty)            // …and empty, never partial
    }

    @Test func newerSchemaFailsClosedRatherThanMisDecoding() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setting-change-v999-\(UUID().uuidString).json")
        let future = SettingChangeLog(version: 999, latest: [], log: [])
        try Data(JSONEncoder().encode(future)).write(to: url)
        let out = StoredSettingChangeStore(url: url).loadOutcome()
        #expect(out.failedClosed)
    }

    // MARK: Log semantics — latest vs audit trail, revert target

    @Test func recordUpdatesLatestAndAppendsAudit() {
        var log = SettingChangeLog()
        let key = SettingKey.global("maxBolus")
        log.record(change(key, before: nil, after: .double(10), .consensusDefault, at: 1), cap: 512)
        log.record(change(key, before: .double(10), after: .double(12), .clinicianSet, at: 2), cap: 512)
        #expect(log.latest.count == 1)                          // one CURRENT record per key
        #expect(log.provenance(key) == .clinicianSet)           // …the most recent
        #expect(log.history(key).count == 2)                    // audit trail keeps both
        #expect(log.current(key)?.before == .double(10))        // §2.1(4): the one-tap revert target
    }

    @Test func capTrimsOldestAuditButKeepsCurrentPerKey() {
        var log = SettingChangeLog()
        let a = SettingKey.global("a"), b = SettingKey.global("b")
        log.record(change(a, before: nil, after: .int(1), .selfSet, at: 1), cap: 2)
        log.record(change(b, before: nil, after: .int(2), .selfSet, at: 2), cap: 2)
        log.record(change(b, before: .int(2), after: .int(3), .selfSet, at: 3), cap: 2)  // overflows cap 2
        #expect(log.log.count == 2)                             // audit bounded
        #expect(log.current(a)?.after == .int(1))               // key a's CURRENT survives the trim
        #expect(log.current(b)?.after == .int(3))
    }

    // MARK: OQ6 — keyed on start time, not the renumbering index

    @Test func provenanceIsKeyedOnStartTimeSoSegmentRenumberIsStable() {
        var log = SettingChangeLog()
        // Two segments in profile 1: 00:00 (self-set) and 08:00 (clinician-set).
        log.record(change(.segment(idpId: 1, startMinutes: 0, field: "basalRate"),
                          before: nil, after: .double(0.6), .selfSet, at: 1), cap: 512)
        log.record(change(.segment(idpId: 1, startMinutes: 480, field: "basalRate"),
                          before: nil, after: .double(0.9), .clinicianSet, at: 2), cap: 512)
        // Deleting the 00:00 segment would renumber the 08:00 segment from index 1 → index 0. Because the
        // key is the START TIME (480), not the index, the 08:00 record is untouched — no remap reconcile.
        #expect(log.provenance(.segment(idpId: 1, startMinutes: 480, field: "basalRate")) == .clinicianSet)
        // A different profile with the SAME start time is a different key (no cross-profile collision).
        #expect(log.provenance(.segment(idpId: 2, startMinutes: 480, field: "basalRate")) == nil)
    }
}
