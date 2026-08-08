import SwiftUI
import faBolusCore

/// F1 (§13) — Privacy & data. One place to **export** everything faBolus holds on this device (glucose /
/// insulin / carb history + the setting-change log + the remote-bolus ledger audit trail) as a single
/// shareable JSON file, and to **erase** all of it. faBolus has no servers; export saves the user's own
/// copy wherever they choose. Erase is owner-only and refuses while a delivery is unresolved (see
/// `AppModel.eraseAllOnDeviceHealthData`).
struct PrivacyDataView: View {
    @Bindable var model: AppModel

    // Export
    @State private var exporting = false
    @State private var exportDoc: BackupDocument?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    export()
                } label: {
                    Label("Export my data…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Saves everything faBolus keeps on this device — your glucose, insulin and carb history, the settings change log, and the bolus delivery audit trail — as a single **`.json`** file you can save to Files or iCloud Drive. It never leaves the device except to the file you choose; faBolus has no servers.")
            }

            if let message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json,
                      defaultFilename: PrivacyDataExport.suggestedFilename()) { result in
            if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" }
            else { message = "Data exported." }
            exportDoc = nil
        }
    }

    private func export() {
        message = nil
        do {
            exportDoc = BackupDocument(data: try model.exportPrivacyDataJSON())
            exporting = true
        } catch {
            message = "Couldn't build the export: \(error.localizedDescription)"
        }
    }
}
