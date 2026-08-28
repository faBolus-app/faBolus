import Testing
import Foundation
@testable import faBolusCore

/// §2.1(3) B1(b): the full-trail `history()` + deterministic `exportText()` that back the change-log view,
/// and `BackupValue.displayString` used to render before/after.
struct SettingChangeLogExportTests {

    private func seeded() -> SettingChangeLog {
        var log = SettingChangeLog()
        // Oldest first into the store; history()/exportText() must return newest first.
        log.record(
            StoredSettingChange(
                key: .global("maxBolus"), before: nil, after: .double(12),
                provenance: .consensusDefault, atSeconds: 1_700_000_000), cap: 512)
        log.record(
            StoredSettingChange(
                key: .segment(idpId: 0, startMinutes: 480, field: "isf"),
                before: .int(40), after: .int(45),
                provenance: .selfSet, atSeconds: 1_700_000_600), cap: 512)
        return log
    }

    @Test func historyIsNewestFirstAndCoversTheWholeTrail() {
        let log = seeded()
        let h = log.history()
        #expect(h.count == 2)
        #expect(h.first?.key.field == "isf")  // most recent
        #expect(h.last?.key.field == "maxBolus")  // oldest
        #expect(log.history().isEmpty == false)
    }

    @Test func exportTextIsDeterministicNewestFirstUTC() {
        let text = seeded().exportText()
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)  // header + 2 entries
        #expect(lines[0].contains("2 entries"))
        // Newest first: the ISF selfSet line precedes the maxBolus consensus-default line.
        #expect(lines[1].contains("isf") && lines[1].contains("40 → 45") && lines[1].contains("Set by you"))
        #expect(lines[2].contains("maxBolus") && lines[2].contains("— → 12") && lines[2].contains("Consensus default"))
        // Deterministic UTC timestamp (test-stable regardless of the machine's zone).
        #expect(lines[1].contains("2023-11-14T22:23:20Z"))
        // Empty log → header only.
        #expect(SettingChangeLog().exportText().split(separator: "\n").count == 1)
    }

    @Test func backupValueDisplayString() {
        #expect(BackupValue.bool(true).displayString == "on")
        #expect(BackupValue.bool(false).displayString == "off")
        #expect(BackupValue.int(45).displayString == "45")
        #expect(BackupValue.double(1.2).displayString == "1.2")
        #expect(BackupValue.double(12).displayString == "12")
        #expect(BackupValue.double(0.05).displayString == "0.05")
        #expect(BackupValue.string("x").displayString == "x")
        #expect(BackupValue.stringArray(["a", "b"]).displayString == "a, b")
        #expect(BackupValue.intArray([1, 2]).displayString == "1, 2")
    }
}
