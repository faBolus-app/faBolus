import SwiftUI
import faBolusCore

/// Settings shown inside the menu-bar popover, organized into collapsible sections so it isn't
/// overwhelming. Connection is expanded by default; the rest start collapsed.
struct MacSettingsPane: View {
    var model: MacRemoteModel
    @Bindable var display: MacDisplayModel

    @State private var showConnection = true
    @State private var showMenuBar = false
    @State private var showBolus = false
    @State private var showDetails = false
    @State private var showAppearance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            group("Connection", $showConnection) { MacConnectionView(model: model) }
            group("Menu bar", $showMenuBar) { menuBar }
            group("Bolus entry", $showBolus) { bolus }
            group("Status details", $showDetails) { details }
            group("Appearance", $showAppearance) { appearance }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
    }

    /// A titled collapsible section with a hairline separator.
    @ViewBuilder private func group<Content: View>(_ title: String, _ isOpen: Binding<Bool>,
                                                   @ViewBuilder _ content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: isOpen) {
            content().padding(.top, 6).padding(.leading, 2)
        } label: {
            Text(title).font(.callout.weight(.semibold))
        }
        .padding(.vertical, 4)
        Divider()
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Color value by glucose range", isOn: $display.menuBarColorByRange)
            Toggle("Trend arrow", isOn: $display.menuBarShowTrend)
            Toggle("Delta from last reading", isOn: $display.menuBarShowDelta)
            Toggle("Insulin on board (IOB)", isOn: $display.menuBarShowIOB)
            Toggle("\"mg/dL\" unit label", isOn: $display.menuBarShowUnits)
        }
    }

    private var bolus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Default mode", selection: $display.defaultBolusMode) {
                Text("Carbs").tag("carbs")
                Text("Units").tag("units")
            }
            Picker("Units step", selection: $display.bolusIncrement) {
                ForEach([0.05, 0.1, 0.5, 1.0], id: \.self) { Text(String(format: "%.2f U", $0)).tag($0) }
            }
            Picker("Carbs step", selection: $display.carbIncrement) {
                ForEach([1.0, 5.0, 10.0, 15.0], id: \.self) { Text("\(Int($0)) g").tag($0) }
            }
        }
        .pickerStyle(.menu)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Insulin on board", isOn: $display.showIOB)
            Toggle("Reservoir", isOn: $display.showReservoir)
            Toggle("Battery", isOn: $display.showBattery)
            Toggle("Last bolus", isOn: $display.showLastBolus)
            Toggle("Color glucose by range in widgets", isOn: $display.widgetColorByRange)
        }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Solid background", isOn: $display.solidBackground)
            Text("Turn off the translucent menu-bar window in favor of a solid one.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Connection pane: pick and pair the iPhone this Mac controls. The Mac discovers iPhones running
/// faBolus over Bluetooth LE (it scans for faBolus's service, so only devices with the app appear —
/// a real faBolus device is never filtered out). Pairing remembers one and reconnects automatically.
struct MacConnectionView: View {
    var model: MacRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.pairing.connected ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(model.pairing.connected ? "Connected" : "Not connected")
                    .font(.callout)
                Spacer()
                if let paired = model.pairing.pairedPhone {
                    Text(paired).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if model.pairing.pairedPhone != nil {
                Button("Forget this iPhone", role: .destructive) { model.pairing.forget() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            Text("Available iPhones").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.pairing.discoveredPhones.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.pairing.discoveredPhones, id: \.self) { name in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        Text(name).lineLimit(1)
                        Spacer()
                        if model.pairing.pairedPhone == name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(model.pairing.connected ? .green : .secondary)
                        } else {
                            Button("Pair") { model.pairing.pair(with: name) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

            Text("Keep both devices nearby (Bluetooth). Open faBolus on the iPhone at least once so it can advertise.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
