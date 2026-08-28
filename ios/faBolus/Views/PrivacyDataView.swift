import SwiftUI
import faBolusCore

/// Privacy & data. One place to **erase** everything faBolus holds on this device
/// (glucose / insulin / carb history + the setting-change log + the remote-bolus ledger).
/// faBolus has no servers. Erase is owner-only and refuses while a delivery is unresolved (see
/// `AppModel.eraseAllOnDeviceHealthData`).
struct PrivacyDataView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared

    @State private var message: String?

    // Erase
    @State private var confirmErase = false
    @State private var confirmFullReset = false

    /// Owner-only surface for the destructive erase: hidden for a read-only (caregiver) phone. The
    /// `childModeEnabled` check is a defensive leftover from when Child mode gated all of Settings
    /// behind a PIN (`SettingsLockGate`, removed Phase 7, 07-04, FEAT-04, D-05) — `childModeEnabled` is
    /// now a permanently-frozen `false`, so this half of the condition can never filter anything out
    /// again, but reading the (unchanged, still-live) property costs nothing and keeps the defense in
    /// depth if it's ever reintegrated (`dev/child-mode`).
    private var isOwner: Bool { !settings.phoneReadOnly && !settings.childModeEnabled }

    var body: some View {
        Form {
            if isOwner {
                Section {
                    Button(role: .destructive) {
                        confirmErase = true
                    } label: {
                        Label("Delete all on-device data", systemImage: "trash")
                    }
                } header: {
                    Text("Delete")
                } footer: {
                    Text(
                        "Permanently deletes all on-device health data — glucose/insulin/carb history, the settings change log, the bolus delivery audit trail, and local diagnostics. **Your pump pairing and saved logins are kept, and your pump/CGM are not touched.** If a bolus is in progress or unconfirmed, deletion is refused until it's resolved."
                    )
                }

                Section {
                    Button(role: .destructive) {
                        confirmFullReset = true
                    } label: {
                        Label("Full reset (unpair + delete logins)", systemImage: "trash.slash")
                    }
                } header: {
                    Text("Full reset")
                } footer: {
                    Text(
                        "A complete reset: deletes everything above **plus** your saved logins (pump pairing, PIN, and CGM credentials) and **unpairs the pump**. Your app preferences (modes, toggles) are kept. This can't be undone. Like the delete above, it's refused while a bolus is unresolved."
                    )
                }
            }

            if let message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all on-device data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes all on-device health data (history, settings change log, bolus audit trail, diagnostics). Your pump pairing and saved logins are kept. This can't be undone."
            )
        }
        .confirmationDialog("Full reset?", isPresented: $confirmFullReset, titleVisibility: .visible) {
            Button("Erase everything & unpair", role: .destructive) { fullReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes all on-device health data AND your saved logins (pump pairing, PIN, CGM credentials), and unpairs the pump. \(model.unpairConfirmation) Your app preferences are kept. This can't be undone. Refused while a bolus is unresolved."
            )
        }
    }

    private func erase() {
        switch model.eraseAllOnDeviceHealthData() {
        case .erased: message = "All on-device data deleted."
        case .refused(let why): message = why
        }
    }

    private func fullReset() {
        switch model.eraseEverythingFullReset() {
        case .erased: message = "Full reset complete — on-device data, saved logins, and pump pairing cleared."
        case .refused(let why): message = why
        }
    }
}
