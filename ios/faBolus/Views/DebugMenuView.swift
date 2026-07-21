import SwiftUI
import faBolusCore

/// Hidden Debug menu (Workstream B4) — read-only diagnostics for power users, revealed by tapping
/// the Settings disclaimer 7×. Intentionally contains NO destructive/arbitrary-send actions:
/// factory reset, shelf mode, and the arbitrary-message console are ported at the protocol layer
/// but deliberately not wired to a button here (too dangerous without deliberate key handling).
struct DebugMenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
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
            Section {
                Text("Read-only diagnostics. Destructive protocol commands (factory reset, shelf "
                     + "mode, arbitrary message) are intentionally not exposed here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Debug")
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}
