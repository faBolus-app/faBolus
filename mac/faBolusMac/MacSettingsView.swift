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

    /// A titled collapsible section. Uses a plain Button header (not DisclosureGroup) — the
    /// disclosure toggle is unreliable inside the menu-bar popover; a Button always registers.
    @ViewBuilder private func group<Content: View>(_ title: String, _ isOpen: Binding<Bool>,
                                                   @ViewBuilder _ content: () -> Content) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())   // whole row is the hit target
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)

        if isOpen.wrappedValue {
            content().padding(.bottom, 4).padding(.leading, 2)
        }
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

    // Segmented pickers (not .menu) — a pop-up menu won't open inside the menu-bar popover.
    private var bolus: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Default mode") {
                Picker("", selection: $display.defaultBolusMode) {
                    Text("Carbs").tag("carbs")
                    Text("Units").tag("units")
                }
            }
            labeled("Units step (U)") {
                Picker("", selection: $display.bolusIncrement) {
                    Text("0.05").tag(0.05); Text("0.1").tag(0.1); Text("0.5").tag(0.5); Text("1").tag(1.0)
                }
            }
            labeled("Carbs step (g)") {
                Picker("", selection: $display.carbIncrement) {
                    Text("1").tag(1.0); Text("5").tag(5.0); Text("10").tag(10.0); Text("15").tag(15.0)
                }
            }
            Toggle("Show carb bolus button in units", isOn: $display.carbButtonInUnits)
        }
    }

    @ViewBuilder private func labeled<P: View>(_ title: String, @ViewBuilder _ picker: () -> P) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            picker().pickerStyle(.segmented).labelsHidden()
        }
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
