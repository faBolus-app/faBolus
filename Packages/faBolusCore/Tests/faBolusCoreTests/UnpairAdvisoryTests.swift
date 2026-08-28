import Testing
@testable import faBolusCore

/// P14 S12 (§2.2.3): the unpair advisory — a Mobi MUST warn about needing the charging base to re-pair;
/// t:slim / unknown get a plain note. The Mobi warning is unconditional (owner OQ8).
struct UnpairAdvisoryTests {

    @Test func mobiRequiresTheChargingBaseAndSaysSo() {
        #expect(UnpairAdvisory.requiresChargingBaseToRepair(.mobi))
        #expect(UnpairAdvisory.confirmationMessage(for: .mobi).localizedCaseInsensitiveContains("charging base"))
    }

    @Test func tslimAndUnknownDoNotRequireTheBase() {
        for model in [PumpModel.tslimX2, .unknown] {
            #expect(!UnpairAdvisory.requiresChargingBaseToRepair(model))
            let msg = UnpairAdvisory.confirmationMessage(for: model)
            #expect(!msg.localizedCaseInsensitiveContains("charging base"))
            #expect(!msg.isEmpty)  // still a real confirmation, just without the base caveat
        }
    }

    /// The offline fallback (C19) — the load-bearing path the live MockBackend can't exercise: when the
    /// snapshot model is `.unknown` (disconnected), the persisted Mobi flag decides the warning.
    @Test func resolvedModelPrefersSnapshotThenFallsBackToStoredSignal() {
        // A known snapshot model always wins, regardless of the stored flag.
        #expect(UnpairAdvisory.resolvedModel(snapshotModel: .mobi, storedIsMobi: false) == .mobi)
        #expect(UnpairAdvisory.resolvedModel(snapshotModel: .tslimX2, storedIsMobi: true) == .tslimX2)
        // Snapshot unknown ⇒ the offline signal decides — so a disconnected Mobi STILL warns.
        #expect(UnpairAdvisory.resolvedModel(snapshotModel: .unknown, storedIsMobi: true) == .mobi)
        #expect(UnpairAdvisory.resolvedModel(snapshotModel: .unknown, storedIsMobi: false) == .tslimX2)
        // Never recorded ⇒ unknown ⇒ the plain note (no false charging-base claim).
        #expect(UnpairAdvisory.resolvedModel(snapshotModel: .unknown, storedIsMobi: nil) == .unknown)
        #expect(
            UnpairAdvisory.requiresChargingBaseToRepair(
                UnpairAdvisory.resolvedModel(snapshotModel: .unknown, storedIsMobi: true)))
    }

    /// A4 (§2.2.3, owner 2026-08-09): the unpair flow gates on a backup-or-skip choice BEFORE it completes.
    /// Pin the two-step ordering (backup choice always precedes the confirm) and that the prompt copy is
    /// present — the invariant the two-stage SwiftUI flow implements.
    @Test func unpairFlowOffersBackupBeforeTheConfirm() {
        #expect(UnpairAdvisory.steps == [.backupChoice, .confirm])
        #expect(UnpairAdvisory.steps.first == .backupChoice)  // backup is offered first — can't be skipped silently
        #expect(UnpairAdvisory.steps.last == .confirm)
        #expect(!UnpairAdvisory.backupPromptTitle.isEmpty)
        #expect(UnpairAdvisory.backupPromptMessage.localizedCaseInsensitiveContains("back"))
        #expect(!UnpairAdvisory.backUpNowLabel.isEmpty)
        #expect(UnpairAdvisory.skipBackupLabel.localizedCaseInsensitiveContains("skip"))
    }
}
