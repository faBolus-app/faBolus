import SwiftUI
import UIKit
import faBolusCore

/// Hidden Debug menu (Workstream B4 / P16 F7) — read-only diagnostics for power users, revealed by tapping
/// the Settings disclaimer 7×. Intentionally contains NO destructive/arbitrary-send actions:
/// factory reset, shelf mode, and the arbitrary-message console are ported at the protocol layer
/// but deliberately not wired to a button here (too dangerous without deliberate key handling).
///
/// P16 F7 ("Mobi debug alternative") folds an **in-app debug console** into this same hidden surface:
/// a single opt-in toggle, plus read-only views of the already-recorded connection telemetry (P12
/// §5.2.8), the notification telemetry (P9), and an in-memory BLE-session log (F7). Everything is
/// LOCAL-ONLY — diagnostics stay on the device and are never uploaded; export is clipboard-only.
struct DebugMenuView: View {
    @Bindable var model: AppModel
    @Bindable private var settings = AppSettings.shared

    /// Mirror of the shared "share local diagnostics" opt-in (App-Group-backed, so not observation-tracked);
    /// initialized in `.onAppear` and written back through `onChange`. Default OFF (never changed here).
    @State private var shareDiagnostics = false
    /// One-shot confirmation that "Copy diagnostics" put the text on the clipboard.
    @State private var didCopy = false

    var body: some View {
        Form {
            // MARK: F7 — opt-in (TOP of the console)
            Section {
                Toggle("Share local diagnostics", isOn: $shareDiagnostics)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Turns on local diagnostics collection (connection telemetry and an in-memory "
                     + "BLE-session log). Diagnostics stay on this device and are never uploaded or "
                     + "transmitted. This is read-only and never changes how the pump connects or doses. "
                     + "Off by default.")
            }

            Section {
                Picker("Garmin target app", selection: $settings.garminTargetApp) {
                    Text("Beta (faBolus Beta)").tag("beta")
                    Text("Official (faBolus)").tag("official")
                }
            } header: {
                Text("Developer — Garmin remote")
            } footer: {
                Text("Which published Garmin app the phone pairs with. After changing, re-run “Set up Garmin remote” (Settings → Watch & Garmin) or reopen the app for it to take effect. Beta = the original app id; Official = the second store copy.")
            }
            Section("Pump identity") {
                row("Model", model.snapshot.pumpModelName.isEmpty ? "—" : model.snapshot.pumpModelName)
                row("Software", model.snapshot.softwareVersion.isEmpty ? "—" : model.snapshot.softwareVersion)
                row("Is Mobi", model.snapshot.isMobi ? "yes" : "no")
                row("Connection", model.snapshot.connection.rawValue)
            }
            Section("Live snapshot") {
                row("Glucose", model.snapshot.glucose.map { "\($0) mg/dL" } ?? "—")
                row("IOB", String(format: "%.2f U", model.snapshot.iobUnits))
                row("Basal", String(format: "%.2f U/hr", model.snapshot.basalRateUnitsPerHour))
                row("Suspended", model.snapshot.deliverySuspended ? "yes" : "no")
                row("Control-IQ", "\(model.snapshot.controlIQEnabled ? "on" : "off") mode \(model.snapshot.controlIQMode)")
                row("Reservoir", String(format: "%.0f U", model.snapshot.reservoirUnits))
                row("Battery", "\(model.snapshot.batteryPercent)%")
                row("Max bolus", String(format: "%.2f U", model.snapshot.maxBolusUnits))
            }

            // MARK: F7 — connection telemetry (P12 §5.2.8), read-only
            connectionTelemetrySection

            // MARK: F7 — notification telemetry (P9), read-only
            notificationTelemetrySection

            // MARK: F7 — BLE-session log (in-memory ring buffer), read-only
            bleSessionLogSection

            Section("Alerts (raw)") {
                Text(model.alertDebug.isEmpty ? "—" : model.alertDebug)
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("History") {
                row("Decoded events", "\(model.historyEvents.count)")
                if let last = model.historyEvents.first {
                    row("Newest", "\(last.title) · \(last.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if let err = model.lastError {
                Section("Last error") { Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }

            // MARK: F7 — clipboard-only export (no share-sheet, no network)
            Section {
                Button {
                    UIPasteboard.general.string = diagnosticsText
                    didCopy = true
                    writeDiagnosticsExportFile(diagnosticsText)
                } label: {
                    Label(didCopy ? "Copied to clipboard" : "Copy diagnostics", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("Copies the diagnostics above to the clipboard so you can paste them into a support "
                     + "message you choose to send. faBolus never uploads or transmits them itself.")
            }

            Section {
                Text("Read-only diagnostics. Destructive protocol commands (factory reset, shelf "
                     + "mode, arbitrary message) are intentionally not exposed here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Debug")
        .onAppear {
            shareDiagnostics = settings.notificationTelemetryEnabled
            // D-01a/Pitfall 4: write the export file as soon as the console is opened, so the fixed-name
            // Documents file exists before anyone runs `devicectl device copy from` — not gated behind a
            // button tap that may never happen on this install.
            writeDiagnosticsExportFile(diagnosticsText)
        }
        .onChange(of: shareDiagnostics) { _, on in
            settings.notificationTelemetryEnabled = on
        }
    }

    // MARK: - Sections

    @ViewBuilder private var connectionTelemetrySection: some View {
        let t = model.connectionTelemetry.snapshot
        Section {
            row("Connects", "\(t.connectCount)")
            row("Total uptime", Self.formatUptime(t.totalUptimeSeconds))
            if t.disconnects.isEmpty {
                row("Disconnects", "—")
            } else {
                ForEach(t.disconnects.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    row("Disconnect · \(k)", "\(v)")
                }
            }
            if !t.reconcile.isEmpty {
                ForEach(t.reconcile.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    row("Reconcile · \(k)", "\(v)")
                }
            }
        } header: {
            Text("Connection telemetry")
        } footer: {
            Text(model.connectionTelemetry.enabled
                 ? "Cumulative counters (uptime, why the link dropped, how unresolved deliveries settled). Local-only."
                 : "Turn on “Share local diagnostics” above to start collecting these counters.")
        }
    }

    @ViewBuilder private var notificationTelemetrySection: some View {
        let telemetry = NotificationRuntime().telemetry
        Section {
            if telemetry.isEmpty {
                row("Notifications", "—")
            } else {
                ForEach(telemetry.sorted(by: { $0.key < $1.key }), id: \.key) { cat, c in
                    row(cat, "d\(c.delivered) · x\(c.dismissed) · a\(c.actedUpon)")
                }
            }
        } header: {
            Text("Notification telemetry")
        } footer: {
            Text("Per-category counts: delivered (d), dismissed (x), acted-upon (a). Local-only, never uploaded.")
        }
    }

    @ViewBuilder private var bleSessionLogSection: some View {
        let entries = model.bleSessionLog.entries
        Section {
            if entries.isEmpty {
                Text(model.bleSessionLog.enabled
                     ? "No connection events recorded yet."
                     : "Turn on “Share local diagnostics” above to record connection events.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // Newest first for readability.
                ForEach(entries.reversed()) { e in
                    LabeledContent {
                        Text(e.detail.isEmpty ? e.kind.rawValue : "\(e.kind.rawValue) · \(e.detail)")
                            .font(.caption.monospaced())
                    } label: {
                        Text(e.at.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("BLE session log (last \(model.bleSessionLog.capacity))")
        } footer: {
            Text("In-memory only — connect/disconnect edges since launch, forgotten on restart. Never uploaded.")
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    /// Compact uptime string (e.g. "3h 12m", "45s"). Cumulative across sessions.
    static func formatUptime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "—" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// D-01a/D-09/D-10 — best-effort write of `diagnosticsText` verbatim to a FIXED filename in the app's
    /// OWN Documents directory (no date/timestamp in the name, so `xcrun devicectl device copy from` has a
    /// stable, predictable path to pull with zero on-device UI). `.completeFileProtectionUntilFirstUserAuthentication`
    /// is passed EXPLICITLY (not the ambient default) so the file stays pullable after the first unlock
    /// since boot — do NOT change this to `.completeFileProtection` (would make a locked-device pull fail).
    /// A write failure is swallowed: this is a debug-only affordance and must never surface as a
    /// user-facing error. No network/upload code — the file never leaves the app's own sandbox (F7, D-02).
    private func writeDiagnosticsExportFile(_ text: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("faBolus-diagnostics.txt")
        do {
            try Data(text.utf8).write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // no-op — best-effort debug affordance, never blocks or errors the UI
        }
    }

    /// Plain-text snapshot of everything the console surfaces, for the clipboard-only export.
    private var diagnosticsText: String {
        var lines: [String] = ["faBolus diagnostics (local-only, never uploaded)"]
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("")
        lines.append("[Pump identity]")
        lines.append("Model: \(model.snapshot.pumpModelName.isEmpty ? "—" : model.snapshot.pumpModelName)")
        lines.append("Software: \(model.snapshot.softwareVersion.isEmpty ? "—" : model.snapshot.softwareVersion)")
        lines.append("Is Mobi: \(model.snapshot.isMobi ? "yes" : "no")")
        lines.append("Connection: \(model.snapshot.connection.rawValue)")
        lines.append("")
        let t = model.connectionTelemetry.snapshot
        lines.append("[Connection telemetry]")
        lines.append("Connects: \(t.connectCount)")
        lines.append("Total uptime: \(Self.formatUptime(t.totalUptimeSeconds))")
        for (k, v) in t.disconnects.sorted(by: { $0.key < $1.key }) { lines.append("Disconnect \(k): \(v)") }
        for (k, v) in t.reconcile.sorted(by: { $0.key < $1.key }) { lines.append("Reconcile \(k): \(v)") }
        lines.append("")
        lines.append("[Notification telemetry]")
        let notif = NotificationRuntime().telemetry
        if notif.isEmpty { lines.append("—") }
        for (cat, c) in notif.sorted(by: { $0.key < $1.key }) {
            lines.append("\(cat): delivered \(c.delivered), dismissed \(c.dismissed), acted \(c.actedUpon)")
        }
        lines.append("")
        lines.append("[BLE session log] (in-memory, last \(model.bleSessionLog.capacity))")
        let entries = model.bleSessionLog.entries
        if entries.isEmpty { lines.append("—") }
        for e in entries {
            let ts = e.at.formatted(date: .omitted, time: .standard)
            lines.append("\(ts) \(e.kind.rawValue)\(e.detail.isEmpty ? "" : " · \(e.detail)")")
        }
        return lines.joined(separator: "\n")
    }
}
