import Foundation
import PumpScript
import TandemLink
import Testing
import faBolusCore

@testable import PhoneApp

/// The diagnostics export. Ported from the old app's `DiagnosticsBundleTests` and
/// `CgmArbiterDiagnosticsTests`: every section is there, it says where the glucose on screen comes from,
/// and it never carries a glucose value or the pairing code.
@MainActor
@Suite struct DiagnosticsTests {
    @Test func theExportHasEverySectionAndNoGlucoseOrCode() async {
        let phone = Phone()
        phone.mock.pump.glucose = (247, 60)
        let model = await phone.launch()
        #expect(await phone.until(model) { model.pump.glucose?.value.mgdl == 247 })
        let text = await model.diagnostics()
        for heading in ["## Pump", "## Pump link", "## Watch link", "## Alerts", "## Bolus ledger", "## Other"] {
            #expect(text.contains(heading), "\(heading)")
        }
        #expect(text.contains("Glucose shown from: pump"))
        #expect(!text.contains("247"), "a glucose value in the export")
        #expect(!text.contains(ScriptedPump.code), "the pairing code in the export")
        await model.shutdown()
    }

    /// While a backup source supplies the glucose, the export names it and why the pump's didn't.
    @Test func theExportNamesTheBackupSourceAndWhy() {
        let bundle = DiagnosticsBundle(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "test", pairing: nil,
            pump: PumpState(), link: LinkState(), linkNow: 0, watch: nil, alerts: nil, ledger: RemoteBolusLedger(),
            glucoseProvenance: .failover(sourceID: "dexcom-g6-ble", reason: .pumpStale),
            backupSourceID: "dexcom-g6-ble", backup: nil, historySync: .idle(lastSynced: nil), logbookCount: 0)
        #expect(bundle.text.contains("Glucose shown from: dexcom-g6-ble (pumpStale)"))
    }
}
