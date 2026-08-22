import SwiftUI
import faBolusCore

/// F1 (§13) — Privacy & data. One place to **export** everything faBolus holds on this device (glucose /
/// insulin / carb history + the setting-change log + the remote-bolus ledger audit trail) as a single
/// shareable JSON file, and to **erase** all of it. faBolus has no servers; export saves the user's own
/// copy wherever they choose. Erase is owner-only and refuses while a delivery is unresolved (see
/// `AppModel.eraseAllOnDeviceHealthData`).
struct PrivacyDataView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared

    // Export (Rule 3 / 06-01: `BackupDocument` lives in SettingsBackup.swift, excluded at
    // FABOLUS_BACKUP=0 — D-08 deliberately keeps this whole file on `main` for the erase/full-reset
    // UI below, so only the export-specific state/UI/action are individually gated. Plan 02 trims
    // this export surface out of the file entirely once the default flips to 0.)
    #if FABOLUS_BACKUP
    @State private var exporting = false
    @State private var exportDoc: BackupDocument?
    #endif
    @State private var message: String?

    // Erase
    @State private var confirmErase = false
    @State private var confirmFullReset = false

    /// Owner-only surface for the destructive erase: hidden for a read-only (caregiver) phone. Child mode
    /// already gates all of Settings behind a PIN (SettingsLockGate), so reaching here implies the owner —
    /// but we also hide it while child mode is on, defensively.
    private var isOwner: Bool { !settings.phoneReadOnly && !settings.childModeEnabled }

    var body: some View {
        Form {
            #if FABOLUS_BACKUP
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
            #endif

            if isOwner {
                Section {
                    Button(role: .destructive) { confirmErase = true } label: {
                        Label("Delete all on-device data", systemImage: "trash")
                    }
                } header: {
                    Text("Delete")
                } footer: {
                    Text("Permanently deletes all on-device health data — glucose/insulin/carb history, the settings change log, the bolus delivery audit trail, and local diagnostics. **Your pump pairing and saved logins are kept, and your pump/CGM are not touched.** If a bolus is in progress or unconfirmed, deletion is refused until it's resolved.")
                }

                Section {
                    Button(role: .destructive) { confirmFullReset = true } label: {
                        Label("Full reset (unpair + delete logins)", systemImage: "trash.slash")
                    }
                } header: {
                    Text("Full reset")
                } footer: {
                    Text("A complete reset: deletes everything above **plus** your saved logins (pump pairing, PIN, and CGM credentials) and **unpairs the pump**. Your app preferences (modes, toggles) are kept. This can't be undone — export first. Like the delete above, it's refused while a bolus is unresolved.")
                }
            }

            if let message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
        #if FABOLUS_BACKUP
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json,
                      defaultFilename: PrivacyDataExport.suggestedFilename()) { result in
            if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" }
            else { message = "Data exported." }
            exportDoc = nil
        }
        #endif
        .confirmationDialog("Delete all on-device data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all on-device health data (history, settings change log, bolus audit trail, diagnostics). Your pump pairing and saved logins are kept. This can't be undone — export first if you want a copy.")
        }
        .confirmationDialog("Full reset?", isPresented: $confirmFullReset, titleVisibility: .visible) {
            Button("Erase everything & unpair", role: .destructive) { fullReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all on-device health data AND your saved logins (pump pairing, PIN, CGM credentials), and unpairs the pump. \(model.unpairConfirmation) Your app preferences are kept. This can't be undone — export first. Refused while a bolus is unresolved.")
        }
    }

    #if FABOLUS_BACKUP
    private func export() {
        message = nil
        do {
            exportDoc = BackupDocument(data: try model.exportPrivacyDataJSON())
            exporting = true
        } catch {
            message = "Couldn't build the export: \(error.localizedDescription)"
        }
    }
    #endif

    private func erase() {
        switch model.eraseAllOnDeviceHealthData() {
        case .erased:            message = "All on-device data deleted."
        case .refused(let why):  message = why
        }
    }

    private func fullReset() {
        switch model.eraseEverythingFullReset() {
        case .erased:            message = "Full reset complete — on-device data, saved logins, and pump pairing cleared."
        case .refused(let why):  message = why
        }
    }
}
