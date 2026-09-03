import SwiftUI
import UIKit
import faBolusCore
import faBolusDesign

/// Hidden Debug menu — read-only diagnostics for power users, revealed by tapping the Settings
/// disclaimer 7×. Intentionally contains NO destructive/arbitrary-send actions: factory reset,
/// shelf mode, and the arbitrary-message console are ported at the protocol layer but deliberately
/// not wired to a button here (too dangerous without deliberate key handling).
///
/// An in-app debug console on this same hidden surface: a single opt-in toggle, plus read-only
/// views of the already-recorded connection telemetry, the notification telemetry, and an
/// in-memory BLE-session log. Everything is LOCAL-ONLY — diagnostics stay on the device and are
/// never uploaded; export is clipboard-only.
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
            // MARK: - Diagnostics opt-in
            Section {
                Toggle("Share local diagnostics", isOn: $shareDiagnostics)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text(
                    "Turns on local diagnostics collection (connection telemetry and an in-memory "
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
                Text(
                    "Which published Garmin app the phone pairs with. After changing, re-run “Set up Garmin remote” (Settings → Watch & Garmin) or reopen the app for it to take effect. Beta = the original app id; Official = the second store copy."
                )
            }
            Section("Pump identity") {
                row("Model", model.snapshot.pumpModelName.isEmpty ? "—" : model.snapshot.pumpModelName)
                row("Software", model.snapshot.softwareVersion.isEmpty ? "—" : model.snapshot.softwareVersion)
                row("Is Mobi", model.snapshot.isMobi ? "yes" : "no")
                row("Connection", model.snapshot.connection.rawValue)
            }
            Section("Build") {
                // Same rendered value the export's `[Build]` section carries — one injected constant,
                // two renderers, so the screen and the export can never disagree about which binary
                // produced them.
                row("Build", Self.renderedBuildStamp)
            }
            Section("Live snapshot") {
                // Reachable via 7-tap, not #if DEBUG — same display-unit funnel as every other surface.
                row(
                    "Glucose",
                    model.snapshot.glucose.map {
                        "\(settings.glucoseDisplayUnit.format(mgdl: $0)) \(settings.glucoseDisplayUnit == .mmol ? "mmol/L" : "mg/dL")"
                    } ?? "—")
                // `…IfRead` funnels, same reason as the Reservoir/Battery rows below: the Debug menu is
                // where a support diagnosis starts, so a read the pump never answered must read "—",
                // never a confident `0.00 U` / `0.00 U/hr`. A real 0 (no active insulin, a suspend)
                // still prints as 0.
                // Age-gated on the IOB dose gate's own window; own `TimelineView` for the same
                // one-row-per-cell reason as the Reservoir/Battery rows below.
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    row(
                        "IOB",
                        PumpValuePresentation.text(
                            model.snapshot.iobUnitsIfFresh(now: ctx.date), format: "%.2f U"))
                }
                row(
                    "Basal",
                    PumpValuePresentation.text(model.snapshot.basalRateUnitsPerHourIfRead, format: "%.2f U/hr"))
                row("Suspended", model.snapshot.deliverySuspended ? "yes" : "no")
                row(
                    "Control-IQ",
                    "\(model.snapshot.controlIQEnabled ? "on" : "off") mode \(model.snapshot.controlIQMode)")
                // Age-gated `…IfFresh(now:)` funnel: the Debug menu is where a support diagnosis
                // starts, so it must never show a fabricated 0 for a read the pump never answered
                // (debug `tslim-reservoir-battery-zero`) NOR a number the pump stopped confirming
                // however long ago (debug `pump-value-decay-to-unknown`). An aged reading presented
                // without qualification is the same class of false certainty as a fabricated one, and a
                // support diagnosis is exactly where that misleads hardest. The `TimelineView` wrapper
                // supplies `ctx.date` so these decay on a tick, not only on the next pump read.
                // One `TimelineView` PER ROW, not one around both: inside a `Form`, a container holding
                // two rows collapses them into a single list cell and loses the row separator.
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    row(
                        "Reservoir",
                        ReservoirPresentation.make(units: model.snapshot.reservoirUnitsIfFresh(now: ctx.date))
                            .valueText)
                }
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    row(
                        "Battery",
                        BatteryChargingPresentation.make(
                            percent: model.snapshot.batteryPercentIfFresh(now: ctx.date),
                            charging: model.snapshot.batteryCharging
                        ).valueText)
                }
                row("Max bolus", String(format: "%.2f U", model.snapshot.maxBolusUnits))
            }

            // MARK: - Connection telemetry (read-only)
            connectionTelemetrySection

            // MARK: - Notification telemetry (read-only)
            notificationTelemetrySection

            // MARK: - BLE-session log (in-memory ring buffer, read-only)
            bleSessionLogSection

            // MARK: - Pump read exclusions + safety-degraded disclosure
            pumpReadExclusionsSection

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

            // MARK: - Clipboard-only export (no share-sheet, no network)
            Section {
                Button {
                    UIPasteboard.general.string = diagnosticsText
                    didCopy = true
                    writeDiagnosticsExportFile(diagnosticsText)
                } label: {
                    Label(didCopy ? "Copied to clipboard" : "Copy diagnostics", systemImage: "doc.on.doc")
                }
                // Same plaintext via the share sheet — no .fileExporter, no network.
                ShareLink(item: diagnosticsText) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(
                    "Copies the diagnostics above to the clipboard so you can paste them into a support "
                        + "message you choose to send. faBolus never uploads or transmits them itself.")
            }

            Section {
                Text(
                    "Read-only diagnostics. Destructive protocol commands (factory reset, shelf "
                        + "mode, arbitrary message) are intentionally not exposed here."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Debug")
        .onAppear {
            shareDiagnostics = settings.notificationTelemetryEnabled
            // Write the export file on open so `devicectl device copy from` has a stable path
            // without waiting for a button tap.
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
            row("Window start", Self.formatWindowStart(t.windowStart))
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
            Text(
                model.connectionTelemetry.enabled
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
                Text(
                    model.bleSessionLog.enabled
                        ? "No connection events recorded yet."
                        : "Turn on “Share local diagnostics” above to record connection events."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
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

    /// Reads this pump auto-excluded, plus cartridge pre-check. When a safety-relevant read
    /// (op-20 cartridge) is unavailable, faBolus relies on the pump's own protection.
    @ViewBuilder private var pumpReadExclusionsSection: some View {
        let excluded = model.badOpcodesForDiagnostics
        let notes = PumpReadCatalog.safetyDegradedNotes(excludedOpcodes: excluded)
        Section {
            if excluded.isEmpty {
                row("Rejected reads", "none")
            } else {
                ForEach(excluded.sorted(), id: \.self) { op in
                    row(PumpReadCatalog.readName(for: op), "op-\(op)")
                }
            }
            row("Cartridge pre-check", cartridgeReadinessLabel(model.snapshot.cartridgeReadiness))
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.shield")
                    .font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
            }
            // Q3 recovery (debug `tslim-reservoir-battery-zero`): an exclusion learned from a transient
            // error is no longer permanent, but a pump ALREADY in that state needs a way out that isn't
            // a full unpair. Read-only in the safety sense — it re-enables SENDING the reads and cannot
            // fabricate a reading or turn an unknown pre-guard into confirmed-ready.
            if !excluded.isEmpty {
                Button("Re-probe rejected reads") { model.resetLearnedReadExclusions() }
                    .disabled(!model.snapshot.isLinked)
            }
        } header: {
            Text("Pump read exclusions")
        } footer: {
            Text(
                "Reads this pump rejected and the app has stopped sending (learned per pump). When a "
                    + "safety-relevant read like the cartridge pre-check is unavailable, faBolus relies on the "
                    + "pump's own protection for that check.")
        }
    }

    /// Human-readable label for the tri-state cartridge readiness.
    private func cartridgeReadinessLabel(_ readiness: PumpSnapshot.CartridgeReadiness) -> String {
        switch readiness {
        case .ready: return "ready (confirmed)"
        case .notReady: return "not ready — cartridge change/load in progress"
        case .unknown: return "unknown — relying on the pump's own protection"
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    /// The one injected constant both renderers read: `AppRevision.short`, plus a trailing "+" when
    /// the build tree was dirty. `AppRevision` is generated by scripts/stamp-revision.sh before every
    /// build, so this never re-derives anything from git itself.
    static var renderedBuildStamp: String {
        AppRevision.dirty ? AppRevision.short + "+" : AppRevision.short
    }

    /// Renders `ConnectionTelemetry.windowStart` for both surfaces. Never backfills `now` for an
    /// absent value — an absent window start means "unknown," not "today."
    static func formatWindowStart(_ date: Date?) -> String {
        guard let date else { return "unknown — accrued across an unknown set of builds" }
        return date.formatted(date: .abbreviated, time: .shortened)
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

    /// BLE session log export lines — extracted so capacity/oldest-dropped is unit-testable.
    static func bleSessionLogExportLines(entries: [BLESessionLog.Entry], capacity: Int) -> String {
        var lines: [String] = ["", "[BLE session log] (in-memory, last \(capacity))"]
        guard !entries.isEmpty else {
            lines.append("—")
            return lines.joined(separator: "\n")
        }
        // Per-connect duration on the disconnect line that closed each span.
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

    /// Best-effort write to a fixed filename in Documents so `devicectl device copy from` has a
    /// stable path. Use `.completeFileProtectionUntilFirstUserAuthentication` (not complete) so a
    /// pull after first unlock still works. Swallow write failures — never a user-facing error.
    private func writeDiagnosticsExportFile(_ text: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("faBolus-diagnostics.txt")
        do {
            try Data(text.utf8).write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // no-op — best-effort debug affordance, never blocks or errors the UI
        }
    }

    /// Clipboard/share/file all consume this same string — no second export path.
    private var diagnosticsText: String {
        let t = model.connectionTelemetry.snapshot
        let notif = NotificationRuntime().telemetry

        // Already-tracked Garmin state; never issues a new ConnectIQ send.
        let garminState: GarminDiagnostics.BridgeState? = {
            guard let bridge = GarminRemoteBridge.shared, bridge.hasDevice else { return nil }
            // Full projection (queue/send/watchdog/device plus the bug-2.2 stall discriminators:
            // message-readiness, echo-vs-status queue breakdown, last-send progress bytes, late
            // completions, auto-recovery count, app-install state) is assembled on the bridge, so a new
            // diagnostics field can never be silently forgotten here — which is exactly how
            // `appInstallState` ended up tracked but unreadable.
            return bridge.diagnosticsBridgeState
        }()

        let sections: [String] = [
            // Always present, no opt-in gate — which binary produced this export.
            DiagnosticsBundle.buildProvenanceSection(buildStamp: Self.renderedBuildStamp),
            DiagnosticsBundle.pumpIdentitySection(
                modelName: model.snapshot.pumpModelName,
                softwareVersion: model.snapshot.softwareVersion,
                isMobi: model.snapshot.isMobi,
                connection: model.snapshot.connection.rawValue),
            DiagnosticsBundle.connectionTelemetrySection(
                connectCount: t.connectCount,
                totalUptimeFormatted: Self.formatUptime(t.totalUptimeSeconds),
                disconnects: t.disconnects.sorted(by: { $0.key < $1.key }).map { (key: $0.key, count: $0.value) },
                reconcile: t.reconcile.sorted(by: { $0.key < $1.key }).map { (key: $0.key, count: $0.value) },
                windowStartFormatted: Self.formatWindowStart(t.windowStart)),
            DiagnosticsBundle.notificationTelemetrySection(
                counts: notif.sorted(by: { $0.key < $1.key }).map {
                    (
                        category: $0.key, delivered: $0.value.delivered, dismissed: $0.value.dismissed,
                        actedUpon: $0.value.actedUpon
                    )
                }),
            Self.bleSessionLogExportLines(entries: model.bleSessionLog.entries, capacity: model.bleSessionLog.capacity),
            // Cached backend state, same opt-in as the other gated sections.
            CapabilityDiagnostics.section(
                capabilities: model.capabilities,
                badOpcodes: model.badOpcodesForDiagnostics,
                enabled: shareDiagnostics),
            // Same provenance the live "via <source>" badge uses; never re-runs GlucoseArbiter.merge.
            CgmArbiterDiagnostics.section(
                provenance: model.glucoseProvenance,
                sourceStatuses: model.glucoseSourceDiagnosticsInfo,
                enabled: shareDiagnostics),
            GarminDiagnostics.section(state: garminState, enabled: shareDiagnostics)
        ]

        let preamble =
            "faBolus diagnostics (local-only, never uploaded)\n"
            + "Generated: \(Date().formatted(date: .abbreviated, time: .standard))"
        return preamble + "\n" + DiagnosticsBundle.build(sections: sections)
    }
}
