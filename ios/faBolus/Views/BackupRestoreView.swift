import SwiftUI
import faBolusCore

/// Back up / restore the user's configuration to a file they save wherever they like (e.g. iCloud
/// Drive) — faBolus has no servers. App settings, pump settings, or both, independently. Secrets are
/// opt-in. Restoring pump settings can reconfigure a new **Mobi** (review + confirm); a t:slim shows
/// the values for manual re-entry.
struct BackupRestoreView: View {
    @Bindable var model: AppModel
    @State private var includeApp = true
    @State private var includePump = false
    @State private var includeSecrets = false
    @State private var encryptFile = false
    @State private var password = ""
    @State private var passwordConfirm = ""

    @State private var exporting = false
    @State private var exportDoc: BackupDocument?
    @State private var importing = false
    @State private var parsed: ParsedBackup?
    @State private var encryptedData: Data?     // awaiting a password to decrypt on import
    @State private var importPassword = ""
    @State private var askImportPassword = false
    @State private var busy = false
    @State private var message: String?

    private var encryptReady: Bool { !encryptFile || (!password.isEmpty && password == passwordConfirm) }

    private var pumpConnected: Bool { model.snapshot.connection == .connected }

    var body: some View {
        Form {
            Section {
                Toggle("App settings", isOn: $includeApp)
                Toggle("Pump settings", isOn: $includePump).disabled(!pumpConnected)
                Toggle("Include credentials & pairing", isOn: $includeSecrets)
            } header: { Text("Back up") } footer: {
                Text("Choose what to save. **Pump settings** need a connected pump\(pumpConnected ? "" : " — connect first"). **Credentials & pairing** adds your CGM logins and the pump PIN to the file — leave off unless you need a full restore, and then encrypt it below.")
            }
            Section {
                Toggle("Encrypt with a password", isOn: $encryptFile)
                if encryptFile {
                    SecureField("Password", text: $password)
                    SecureField("Confirm password", text: $passwordConfirm)
                    if !password.isEmpty && password != passwordConfirm {
                        Text("Passwords don't match.").font(.caption).foregroundStyle(.red)
                    }
                }
            } header: { Text("Encryption") } footer: {
                Text(includeSecrets
                     ? "**Recommended — this backup will contain secrets.** The file is encrypted (AES-GCM); you'll need this password to restore it. There's no recovery if you forget it."
                     : "Encrypts the backup file with a password (AES-GCM). You'll need it to restore — there's no recovery if you forget it.")
            }
            Section {
                Button {
                    Task { await createBackup() }
                } label: {
                    HStack { Label("Create backup…", systemImage: "square.and.arrow.up"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || (!includeApp && !includePump) || !encryptReady)
                Button {
                    importing = true
                } label: { Label("Restore from a file…", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("Backups are a `.json` file — save it to iCloud Drive or Files, and it stays in your own iCloud, never on our servers.")
            }
            if let message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Backup & restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json,
                      defaultFilename: SettingsBackup.suggestedFilename()) { result in
            if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" }
            else { message = "Backup saved." }
            exportDoc = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): loadBackup(url)
            case .failure(let e): message = "Couldn't open the file: \(e.localizedDescription)"
            }
        }
        .sheet(item: $parsed) { p in RestoreSheet(model: model, backup: p.backup) }
        .alert("Encrypted backup", isPresented: $askImportPassword) {
            SecureField("Password", text: $importPassword)
            Button("Decrypt") {
                guard let data = encryptedData else { return }
                encryptedData = nil
                do { decodeAndPresent(try BackupCrypto.decrypt(data, password: importPassword)) }
                catch { message = "Incorrect password, or the file is damaged." }
            }
            Button("Cancel", role: .cancel) { encryptedData = nil }
        } message: {
            Text("This backup is password-protected. Enter the password you set when you created it.")
        }
    }

    private func createBackup() async {
        busy = true; message = nil
        defer { busy = false }
        let pump = includePump ? await model.readPumpSettingsForBackup() : nil
        let meta = SettingsBackup.meta(pumpModel: model.snapshot.isMobi ? "mobi"
                                       : (model.snapshot.pumpModelName.isEmpty ? "unknown" : "tslim"))
        let backup = FaBolusBackup(meta: meta,
                                   appSettings: includeApp ? SettingsBackup.appSettingsSnapshot() : nil,
                                   secrets: includeSecrets ? SettingsBackup.secretsSnapshot() : nil,
                                   pumpSettings: pump)
        do {
            var data = try backup.encoded()
            if encryptFile { data = try BackupCrypto.encrypt(data, password: password) }
            exportDoc = BackupDocument(data: data); exporting = true
        } catch { message = "Couldn't build the backup: \(error.localizedDescription)" }
    }

    private func loadBackup(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { message = "Couldn't read the file."; return }
        if BackupCrypto.isEncrypted(data) {
            encryptedData = data; importPassword = ""; askImportPassword = true   // prompt for the password
        } else {
            decodeAndPresent(data)
        }
    }

    private func decodeAndPresent(_ data: Data) {
        do {
            let backup = try FaBolusBackup.decode(data)
            guard backup.meta.schemaVersion <= FaBolusBackup.currentSchema else {
                message = "This backup was made by a newer version of faBolus. Update the app first."; return
            }
            parsed = ParsedBackup(backup: backup)
        } catch { message = "That doesn't look like a faBolus backup." }
    }
}

private struct ParsedBackup: Identifiable { let id = UUID(); let backup: FaBolusBackup }

/// Restore chooser — shows what the file contains and lets the user pick which sections to restore.
private struct RestoreSheet: View {
    @Bindable var model: AppModel
    let backup: FaBolusBackup
    @Environment(\.dismiss) private var dismiss
    @State private var restoreApp = true
    @State private var restoreSecrets = false
    @State private var restorePump = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Created", value: backup.meta.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("From", value: backup.meta.deviceName)
                    if backup.pumpSettings != nil { LabeledContent("Pump", value: backup.meta.pumpModel) }
                } header: { Text("This backup") }

                Section {
                    if backup.appSettings != nil { Toggle("App settings", isOn: $restoreApp) }
                    if backup.secrets != nil { Toggle("Credentials & pairing", isOn: $restoreSecrets) }
                    if backup.pumpSettings != nil {
                        NavigationLink {
                            PumpReconfigureView(model: model, pump: backup.pumpSettings!)
                        } label: { Label("Pump settings…", systemImage: "cross.case") }
                    }
                } header: { Text("Restore") } footer: {
                    Text(backup.pumpSettings == nil ? "App settings apply immediately."
                         : "App settings apply immediately. Pump settings open a review — auto-applied only to a Mobi, shown for manual entry on a t:slim.")
                }

                Section {
                    Button("Restore app settings" + (backup.secrets != nil && restoreSecrets ? " + credentials" : "")) {
                        if restoreApp, let a = backup.appSettings { SettingsBackup.applyAppSettings(a) }
                        if restoreSecrets, let s = backup.secrets { SettingsBackup.applySecrets(s) }
                        message = "Restored. Some changes may need reopening the app."
                    }
                    .disabled(!(restoreApp && backup.appSettings != nil) && !(restoreSecrets && backup.secrets != nil))
                }
                if let message { Section { Text(message).font(.caption).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Review the backed-up pump settings and (Mobi only) apply them to the current pump.
private struct PumpReconfigureView: View {
    @Bindable var model: AppModel
    let pump: PumpSettingsBackup
    @State private var confirming = false
    @State private var busy = false
    @State private var result: String?

    private var canApply: Bool { model.canApplyPumpSettings }

    var body: some View {
        Form {
            Section {
                Text(canApply
                     ? "⚠️ This will **create** these profiles on the connected Mobi and set Control-IQ + max bolus. It's experimental and not FDA-cleared — **verify every value against your prescription / clinician** before and after applying."
                     : "This pump can't be auto-configured (t:slim X2, or Advanced control is off). Use these values to re-enter the settings on the pump yourself.")
                    .font(.callout)
            }
            ForEach(Array(pump.profiles.enumerated()), id: \.offset) { _, p in
                Section {
                    LabeledContent("Insulin duration", value: p.insulinDurationMinutes > 0 ? "\(p.insulinDurationMinutes) min" : "—")
                    ForEach(Array(p.segments.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timeLabel(s.startTimeMinutes)).font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "basal %.3f U/hr · CR %.0f g/U · ISF %d · target %d",
                                        s.basalRateUnitsPerHour, s.carbRatioGramsPerUnit, s.isf, s.targetBg))
                                .font(.callout.monospacedDigit())
                        }
                    }
                } header: { Text("\(p.name)\(p.active ? " (active)" : "")") }
            }
            Section {
                if let mb = pump.maxBolusUnits { LabeledContent("Max bolus", value: String(format: "%.1f U", mb)) }
                if let mbasal = pump.maxBasalUnitsPerHour { LabeledContent("Max basal", value: String(format: "%.2f U/hr", mbasal)) }
                if let e = pump.controlIQEnabled { LabeledContent("Control-IQ", value: e ? "On" : "Off") }
                if let w = pump.controlIQWeightLbs { LabeledContent("Weight", value: "\(w) lb") }
                if let t = pump.controlIQTotalDailyInsulin { LabeledContent("Total daily insulin", value: "\(t) U") }
            } header: { Text("Limits & Control-IQ") }

            if canApply {
                Section {
                    Button(role: .destructive) { confirming = true } label: {
                        HStack { Text("Apply to this pump"); if busy { Spacer(); ProgressView() } }
                    }.disabled(busy)
                }
            }
            if let result { Section { Text(result).font(.caption).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Pump settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Write these settings to the pump?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply to pump", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates the profiles above and sets Control-IQ + max bolus on the connected Mobi. Experimental — verify against your prescription.")
        }
    }

    private func apply() async {
        busy = true; defer { busy = false }
        let ok = await model.applyPumpSettings(pump)
        result = ok ? "Applied. Review the pump to confirm every value is correct."
                    : (model.lastError ?? "Something went wrong; check the pump before relying on it.")
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
