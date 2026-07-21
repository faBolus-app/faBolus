import SwiftUI
import faBolusCore

// MARK: - Status (glucose + trend + pills)

/// Big current glucose + trend arrow, grayed/aged when stale, plus a connection note.
struct MacStatusView: View {
    var model: MacRemoteModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayGlucose)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(model.isGlucoseStale ? Color.secondary : MacTheme.glucoseColor(model.glucose))
                Text(model.trend).font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
            if let age = model.ageLabel {
                Text(age).font(.caption).foregroundStyle(.secondary)
            }
            if !model.reachable {
                Label("iPhone not reachable", systemImage: "wifi.slash")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !model.connection.isEmpty {
                Text(model.connection).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact status pills — IOB, reservoir, battery, last bolus.
struct MacStatusPills: View {
    var model: MacRemoteModel

    var body: some View {
        HStack(spacing: 8) {
            pill("IOB", String(format: "%.2f U", model.iobUnits))
            pill("Reservoir", String(format: "%.0f U", model.reservoirUnits))
            pill("Battery", "\(model.batteryPercent)%")
            if let last = model.lastBolusUnits {
                pill("Last", String(format: "%.2f U", last))
            }
        }
    }

    private func pill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).fontWeight(.medium)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Bolus entry

/// Units/carbs entry that relays a bolus to the phone (which converts carbs→units and executes it).
/// Requires a confirmation before sending — never a one-click dispense. While a bolus is in flight
/// it shows progress + a Cancel button.
struct MacBolusEntryView: View {
    var model: MacRemoteModel
    @State private var mode: String = "carbs"
    @State private var amount: Double = 0
    @State private var confirming = false

    private var isDelivering: Bool { model.lastStatus == .delivering }
    private var isCarbs: Bool { mode == "carbs" }
    private var step: Double { isCarbs ? model.carbIncrement : model.bolusIncrement }
    private var maxV: Double { isCarbs ? 200 : (model.maxBolusUnits > 0 ? model.maxBolusUnits : 25) }
    private var unitLabel: String { isCarbs ? "g" : "U" }
    private var canDeliver: Bool {
        model.reachable && !isDelivering && amount >= (isCarbs ? 1 : 0.05) && amount <= maxV
    }

    var body: some View {
        VStack(spacing: 10) {
            if isDelivering {
                deliveringView
            } else {
                Picker("", selection: $mode) {
                    Text("Carbs").tag("carbs")
                    Text("Units").tag("units")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in amount = 0 }

                HStack {
                    Stepper(value: $amount, in: 0...maxV, step: step) {
                        Text(String(format: isCarbs ? "%.0f %@" : "%.2f %@", amount, unitLabel))
                            .font(.title3.monospacedDigit())
                    }
                }

                Button {
                    confirming = true
                } label: {
                    Text(isCarbs ? "Bolus \(Int(amount)) g" : String(format: "Bolus %.2f U", amount))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDeliver)
                .confirmationDialog("Deliver this bolus?", isPresented: $confirming) {
                    Button(isCarbs ? "Deliver \(Int(amount)) g" : String(format: "Deliver %.2f U", amount),
                           role: .destructive) {
                        if isCarbs { model.deliverCarbs(amount) } else { model.deliverUnits(amount) }
                        amount = 0
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(isCarbs ? "The iPhone will calculate the dose and deliver it on the pump."
                                 : "The iPhone will deliver this on the pump.")
                }
            }
        }
        .onAppear { mode = model.defaultMode }
    }

    private var deliveringView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.statusMessage ?? "Delivering…").font(.callout)
            }
            Button("Cancel bolus", role: .destructive) { model.cancel() }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Alerts

/// Active pump alerts with a dismiss action (relayed to the phone).
struct MacAlertsView: View {
    var model: MacRemoteModel

    var body: some View {
        if model.alerts.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.alerts.enumerated()), id: \.offset) { _, alert in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(alert.title).font(.callout)
                        Spacer()
                        Button("Dismiss") { model.dismissAlert(alert) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }
}
