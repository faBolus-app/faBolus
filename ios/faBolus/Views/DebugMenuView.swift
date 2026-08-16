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
                // 04-08 gap closure (SC1, WR-07): this screen is reachable via an undocumented 7-tap
                // gesture on the Settings disclaimer footer (not #if DEBUG-gated) — 04-REVIEW.md flagged
                // it as "technically user-reachable, not purely a developer tool." Route through the
                // same funnel as every other mainline glucose surface rather than documenting an
                // exception, since converting is no riskier than the mirror-the-pattern fix elsewhere.
                row("Glucose", model.snapshot.glucose.map { "\(settings.glucoseDisplayUnit.format(mgdl: $0)) \(settings.glucoseDisplayUnit == .mmol ? "mmol/L" : "mg/dL")" } ?? "—")
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
                // D-01b — a second, zero-tooling export path: the OS share sheet (AirDrop/Files/Messages),
                // sharing the same plaintext diagnosticsText directly. No .fileExporter/BackupDocument save
                // dialog (D-02) and no network — mirrors SettingChangeLogView's ShareLink idiom.
                ShareLink(item: diagnosticsText) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
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
            // Phase 09.6-07 (D-03.1, Pitfall 3): issue the watch-diagnostics REQUEST only when the
            // shared opt-in is on — no new opt-in, no collection while it's off. The reply (if any)
            // lands via PhoneRemoteHost before the next diagnosticsText rebuild; this view doesn't
            // wait for it (the placeholder covers "no reply yet" gracefully).
            if shareDiagnostics { PhoneRemoteHost.shared?.requestWatchDiagnostics() }
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

    /// D-02b (09.6-02): pure `[BLE session log]` diagnostics-text line-builder — extracted verbatim
    /// from `diagnosticsText`'s prior inline block (mirrors `CapabilityDiagnostics.section`'s pure-
    /// builder shape) so the ring buffer's presence in the export — up to `capacity`, oldest dropped
    /// first — is unit-testable (`BLESessionLogTests`) without instantiating this View. Reads nothing
    /// beyond its parameters: `entries` already reflects whatever `BLESessionLog` recorded (empty
    /// whenever the shared opt-in was off, since `BLESessionLog.record` no-ops then).
    static func bleSessionLogExportLines(entries: [BLESessionLog.Entry], capacity: Int) -> String {
        var lines: [String] = ["", "[BLE session log] (in-memory, last \(capacity))"]
        guard !entries.isEmpty else {
            lines.append("—")
            return lines.joined(separator: "\n")
        }
        // D-04: per-connect durations from the pure helper — matched back onto the disconnect line
        // that closed each span (spans and entries are both chronological, so a positional walk
        // suffices; no pairing logic is re-derived here).
        let spans = BLESessionLog.connectDurations(from: entries)
        var spanIndex = 0
        for e in entries {
            let ts = e.at.formatted(date: .omitted, time: .standard)
            lines.append("\(ts) \(e.kind.rawValue)\(e.detail.isEmpty ? "" : " · \(e.detail)")")
            if e.kind == .disconnect, spanIndex < spans.count, spans[spanIndex].end == e.at {
                let duration = spans[spanIndex].end.timeIntervalSince(spans[spanIndex].start)
                lines.append("  connected for \(Self.formatUptime(duration))")
                spanIndex += 1
            }
        }
        return lines.joined(separator: "\n")
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
    ///
    /// Phase 09.6-06 (Task 1, Part C-1, D-03.1): the preamble ("faBolus diagnostics…" + "Generated:")
    /// stays a plain document header; every surface below it is now assembled as an ordered array of
    /// already-formatted `[Bracket]` section strings and joined by the pure `DiagnosticsBundle.build`
    /// aggregator — this method itself no longer builds any section's line content directly (that
    /// responsibility moved to `DiagnosticsBundle`'s helpers or each Part C wrapper type). ShareLink
    /// and `writeDiagnosticsExportFile` below still consume this SAME string — no second export path.
    private var diagnosticsText: String {
        let t = model.connectionTelemetry.snapshot
        let notif = NotificationRuntime().telemetry

        // Task 2 (Part C-4b, D-03.4): [Remote role] — reads MacPairingCoordinator's already-tracked
        // paired-peer/connection/policy state directly; never re-derives the handshake or grant logic.
        let pairing = MacPairingCoordinator.shared
        let peers = pairing.pairedMacs.map {
            RemoteRoleDiagnostics.PeerInfo(
                displayName: $0.name,
                connected: pairing.connected && pairing.connectedName == $0.name,
                policy: pairing.policy(for: $0.id))
        }

        // Task 1 (Part C-4a, D-03.4): [Garmin CIQ] — reads GarminRemoteBridge's already-tracked send
        // queue/watchdog/device-connection state via its `.shared` app-wide reference; never issues a
        // new ConnectIQ send. `state` is nil (renders the explicit unreachable empty state) when no
        // Garmin device has ever been selected/paired.
        let garminState: GarminDiagnostics.BridgeState? = {
            guard let bridge = GarminRemoteBridge.shared, bridge.hasDevice else { return nil }
            return GarminDiagnostics.BridgeState(
                queueDepth: bridge.queueDepthForDiagnostics,
                lastSendOutcome: bridge.lastSendOutcomeForDiagnostics,
                watchdogFires: bridge.sendWatchdogFireCountForDiagnostics,
                deviceConnected: bridge.deviceConnectedForDiagnostics,
                deviceName: bridge.deviceNameForDiagnostics)
        }()

        // Task 1 (Part C-3a, D-03.3): [Watch WC] — reads PhoneRemoteHost's already-tracked
        // WatchConnectivity state via its `.shared` app-wide reference; never issues a new WC
        // round-trip. Falls back to `false`/`0` if the host hasn't been constructed yet (e.g. before
        // App.swift's `.task` runs) — the section then renders "Reachable: no" like any genuinely
        // unreachable watch, never a crash or an omitted header.
        let wcHost = PhoneRemoteHost.shared

        let sections: [String] = [
            // Extracted verbatim from the prior inline blocks (D-01/P12 §5.2.8/P9) — always present,
            // no opt-in gate.
            DiagnosticsBundle.pumpIdentitySection(
                modelName: model.snapshot.pumpModelName,
                softwareVersion: model.snapshot.softwareVersion,
                isMobi: model.snapshot.isMobi,
                connection: model.snapshot.connection.rawValue),
            DiagnosticsBundle.connectionTelemetrySection(
                connectCount: t.connectCount,
                totalUptimeFormatted: Self.formatUptime(t.totalUptimeSeconds),
                disconnects: t.disconnects.sorted(by: { $0.key < $1.key }).map { (key: $0.key, count: $0.value) },
                reconcile: t.reconcile.sorted(by: { $0.key < $1.key }).map { (key: $0.key, count: $0.value) }),
            DiagnosticsBundle.notificationTelemetrySection(
                counts: notif.sorted(by: { $0.key < $1.key }).map {
                    (category: $0.key, delivered: $0.value.delivered, dismissed: $0.value.dismissed, actedUpon: $0.value.actedUpon)
                }),
            // D-02b (09.6-02): pure extracted line-builder — proves (via BLESessionLogTests) that the
            // ring buffer's entries reach this export up to capacity, not silently dropped.
            Self.bleSessionLogExportLines(entries: model.bleSessionLog.entries, capacity: model.bleSessionLog.capacity),
            // Task 1 (TRACER, Part B-a, D-02a): [Capability/opcode] — reads already-cached backend
            // state only, gated on the SAME shareDiagnostics opt-in as every section here.
            CapabilityDiagnostics.section(
                capabilities: model.capabilities,
                badOpcodes: model.badOpcodesForDiagnostics,
                enabled: shareDiagnostics),
            // Task 1 (Part C-2, D-03.2): [CGM arbiter] — reads the SAME already-arbitrated provenance
            // the live "via <source>" badge uses; never re-runs GlucoseArbiter.merge.
            CgmArbiterDiagnostics.section(
                provenance: model.glucoseProvenance,
                sourceStatuses: model.glucoseSourceDiagnosticsInfo,
                enabled: shareDiagnostics),
            RemoteRoleDiagnostics.section(role: "host", peers: peers, enabled: shareDiagnostics),
            GarminDiagnostics.section(state: garminState, enabled: shareDiagnostics),
            WCDiagnostics.section(
                reachable: wcHost?.reachableForDiagnostics ?? false,
                sent: wcHost?.sentCountForDiagnostics ?? 0,
                undeliverable: wcHost?.undeliverableCountForDiagnostics ?? 0,
                enabled: shareDiagnostics),
            // Phase 09.6-07 (D-03.1, D-04): [Watch self] — the ninth (final) surface, closing the
            // 09.6-VERIFICATION.md gap. Reads PhoneRemoteHost's already-tracked
            // `lastWatchDiagnosticsText` (set only by the `.diagnosticsRead` reply handler); never
            // re-derives it or issues a new request from here (the request goes out from `.onAppear`
            // below, gated on the SAME opt-in).
            WatchSelfDiagnostics.phoneSection(
                body: wcHost?.lastWatchDiagnosticsText,
                enabled: shareDiagnostics),
        ]

        let preamble = "faBolus diagnostics (local-only, never uploaded)\n"
            + "Generated: \(Date().formatted(date: .abbreviated, time: .standard))"
        return preamble + "\n" + DiagnosticsBundle.build(sections: sections)
    }
}
