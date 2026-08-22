import SwiftUI
import faBolusCore

/// Data & History settings — time-in-range from the persisted store, storage size, an optional
/// retention (auto-delete) control, and a clear-history action. Storage is ~1 MB/month, so the default
/// is "keep everything"; the retention picker only exists for data-minimization. See MIGRATION.md.
struct DataHistoryView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var confirmClear = false
    @State private var stats: GlucoseStatistics?

    private let retentionOptions: [(label: String, days: Int)] = [
        ("Keep everything", 0), ("90 days", 90), ("1 year", 365),
    ]

    var body: some View {
        Form {
            Section("Time in range (last 90 days)") {
                if let s = stats, s.count > 0 {
                    LabeledContent("Time in range", value: "\(Int(s.timeInRangePct))%")
                    // WR-01 gap closure (04-07): route through the display-unit funnel — was a
                    // second, un-funneled "Average" glucose metric distinct from StatsCardView's.
                    // Owner-requested toggle: bare value (no unit suffix) when labels are hidden.
                    LabeledContent("Average", value: settings.showGlucoseUnitLabels
                        ? "\(settings.glucoseDisplayUnit.format(mgdl: Int(s.mean))) \(settings.glucoseDisplayUnit == .mmol ? "mmol/L" : "mg/dL")"
                        : settings.glucoseDisplayUnit.format(mgdl: Int(s.mean)))
                    LabeledContent("GMI", value: String(format: "%.1f%%", s.gmi))
                    LabeledContent("Readings", value: "\(s.count)")
                } else {
                    Text("No stored history yet — it fills in as glucose comes in.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Stored on this device", value: sizeText)
                Picker("Keep history for", selection: $settings.historyRetentionDays) {
                    ForEach(retentionOptions, id: \.days) { Text($0.label).tag($0.days) }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("faBolus keeps your glucose, insulin and carb history on this device to power stats, charts, and retrospective insights — about **1 MB per month**, so keeping everything is fine. This control is only if you prefer to auto-delete older data.")
            }

            // Phase 09.7-02 (D-01/D-05): surfaces the gap-aware sync from Plan 01. Bounded by the
            // `historyRetentionDays` picker above — this section deliberately adds no second depth
            // control (D-03/UI-SPEC assumption 3) and never shows the raw coverage map, only a
            // human-readable "Last synced" timestamp and, while active, a "Syncing…" indicator
            // (UI-SPEC assumption 4). Uses plain `Color.accentColor`, never `AppTheme.insulin` — a
            // data/observability control must never look like a dosing control (UI-SPEC F7 hard exclusion).
            Section {
                Toggle("Auto-sync pump history", isOn: $settings.historySyncEnabled)
                    .tint(Color.accentColor)

                Button {
                    model.syncHistoryNow()
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        if isHistorySyncing { Spacer(); ProgressView() }
                    }
                }
                .tint(Color.accentColor)
                .disabled(isHistorySyncing)

                historySyncStatusRow

                if isHistorySyncing {
                    // Plain (non-destructive) — this pauses a resumable operation, it never deletes
                    // anything (the coverage map already makes the next connect/retry resume
                    // correctly), so it must NOT use `role: .destructive` or red (UI-SPEC Color).
                    Button("Stop syncing") { model.stopHistorySync() }
                        .tint(Color.accentColor)
                }
            } header: {
                Text("Pump history sync")
            } footer: {
                Text("faBolus fetches only the pump-history records it doesn't already have, and keeps them on this device — this is never uploaded.")
            }

            Section {
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear stored history", systemImage: "trash")
                }
            } footer: {
                Text("Permanently deletes all stored glucose/insulin/carb history from this device. Your pump and CGM are not affected.")
            }
        }
        .navigationTitle("Data & History")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all stored history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { model.clearStoredHistory(); reload() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { model.applyRetention(days: settings.historyRetentionDays); reload() }
        .onChange(of: settings.historyRetentionDays) { _, days in
            model.applyRetention(days: days); reload()
        }
    }

    private var sizeText: String {
        let mb = Double(model.storedHistoryApproxBytes()) / 1_000_000
        return mb < 1 ? String(format: "~%.0f KB", mb * 1000) : String(format: "~%.1f MB", mb)
    }

    private func reload() {
        stats = model.storedStatistics(days: 90)
    }

    // MARK: - Pump history sync (Phase 09.7-02, D-01/D-05)

    private var isHistorySyncing: Bool {
        if case .syncing = model.historySyncState { return true }
        return false
    }

    /// UI-SPEC state coverage: empty ("Not synced yet"), loading ("Syncing…"), partial/interrupted
    /// ("Sync paused…", non-red), error ("Sync error…", red), and the populated "Last synced" readout.
    @ViewBuilder
    private var historySyncStatusRow: some View {
        switch model.historySyncState {
        case .idle(let lastSynced):
            if let lastSynced {
                LabeledContent("Last synced", value: lastSynced.formatted(.relative(presentation: .named)))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not synced yet").font(.subheadline.weight(.semibold))
                    Text("faBolus will sync automatically the next time your pump connects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .syncing:
            HStack {
                Text("Syncing…")
                Spacer()
                ProgressView()
            }
        case .paused:
            // Benign/resumable (the coverage map guarantees a correct resume) — NOT styled as an error.
            Text("Sync paused — reconnect your pump to resume.").foregroundStyle(.secondary)
        case .error(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
