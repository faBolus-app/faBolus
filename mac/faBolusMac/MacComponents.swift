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
        let d = model.display
        HStack(spacing: 8) {
            if d.showIOB { pill("IOB", String(format: "%.2f U", model.iobUnits)) }
            if d.showReservoir { pill("Reservoir", String(format: "%.0f U", model.reservoirUnits)) }
            if d.showBattery { pill("Battery", "\(model.batteryPercent)%") }
            if d.showLastBolus, let last = model.lastBolusUnits {
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
    // Optional so the field starts empty (no stale value, no "0" to clear before typing).
    @State private var amount: Double? = nil
    @State private var confirming = false

    private var isDelivering: Bool { model.lastStatus == .delivering }
    private var isCarbs: Bool { mode == "carbs" }
    private var step: Double { isCarbs ? model.display.carbIncrement : model.display.bolusIncrement }
    private var maxV: Double { isCarbs ? 200 : (model.maxBolusUnits > 0 ? model.maxBolusUnits : 25) }
    private var unitLabel: String { isCarbs ? "g" : "U" }
    private var value: Double { amount ?? 0 }
    private var canDeliver: Bool {
        model.reachable && !isDelivering && value >= (isCarbs ? 1 : 0.05) && value <= maxV
    }
    /// Non-optional binding for the Stepper (treats an empty field as 0).
    private var stepperBinding: Binding<Double> {
        Binding(get: { amount ?? 0 }, set: { amount = $0 })
    }
    private var amountText: String { String(format: isCarbs ? "%.0f %@" : "%.2f %@", value, unitLabel) }

    var body: some View {
        VStack(spacing: 10) {
            if isDelivering {
                deliveringView
            } else if confirming {
                // Inline confirm — a system confirmationDialog dismisses the menu-bar popover, so the
                // second tap ("Deliver") never registers. Confirm in place instead.
                confirmView
            } else {
                Picker("", selection: $mode) {
                    Text("Carbs").tag("carbs")
                    Text("Units").tag("units")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in amount = nil }

                // Type a value directly, or use the − / + stepper. Both edit the same amount.
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    TextField("Amount", value: $amount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84)
                        .onSubmit { if let a = amount { amount = min(max(0, a), maxV) } }
                    Text(unitLabel).foregroundStyle(.secondary)
                    Stepper("", value: stepperBinding, in: 0...maxV, step: step)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                Button {
                    if let a = amount { amount = min(max(0, a), maxV) }   // clamp typed value
                    if canDeliver { confirming = true }
                } label: {
                    Text(amount == nil ? "Bolus"
                                       : (isCarbs ? "Bolus \(Int(value)) g" : String(format: "Bolus %.2f U", value)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDeliver)
            }
        }
        .onAppear { mode = model.display.defaultBolusMode }
    }

    private var confirmView: some View {
        VStack(spacing: 8) {
            Text(isCarbs ? "Deliver \(Int(value)) g?" : "Deliver \(amountText)?")
                .font(.callout.weight(.semibold))
            Text(isCarbs ? "The iPhone calculates the dose and delivers it on the pump."
                         : "The iPhone delivers this on the pump.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            HStack {
                Button("Back") { confirming = false }
                    .buttonStyle(.bordered)
                Button("Deliver") {
                    if isCarbs { model.deliverCarbs(value) } else { model.deliverUnits(value) }
                    amount = nil
                    confirming = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
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
