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
            Toggle("Hide stale reading (show \"—\")", isOn: $display.menuBarHideStale)
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
/// faBolus over Bluetooth LE. First-time pairing requires the one-time code shown on the phone; once
/// paired, a stored token reconnects automatically. "Connected" means authenticated, not just linked.
struct MacConnectionView: View {
    var model: MacRemoteModel
    @State private var codeEntry = ""
    @State private var showScanner = false

    private var pairing: MacConnection { model.pairing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(statusText).font(.callout)
                Spacer()
                if let paired = pairing.pairedPhone {
                    Text(paired).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if !pairing.authenticated {
                Button { showScanner = true } label: { Label("Scan pairing QR", systemImage: "qrcode.viewfinder") }
                    .controlSize(.small)
            }

            if pairing.needsCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan the QR shown in faBolus on \(pairing.pairingPhone ?? "your iPhone") (Settings → Watch & Garmin → Remote access → Pair a remote), or type the code:")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("123456", text: $codeEntry)
                            .textFieldStyle(.roundedBorder).frame(width: 90).onSubmit(submit)
                        Button("Connect", action: submit)
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(codeEntry.filter(\.isNumber).count < MacPairing.codeLength)
                        Button("Cancel") { codeEntry = ""; model.cancelPairing() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }

            if let err = pairing.pairingError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pairing.pairedPhone != nil && pairing.authenticated {
                Button("Forget this iPhone", role: .destructive) { model.pairing.forget() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider()

            Text("Available iPhones").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if pairing.discoveredPhones.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(pairing.discoveredPhones, id: \.self) { name in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        Text(name).lineLimit(1)
                        Spacer()
                        if pairing.pairedPhone == name {
                            Image(systemName: pairing.authenticated ? "checkmark.circle.fill" : "ellipsis.circle")
                                .foregroundStyle(pairing.authenticated ? .green : .secondary)
                        } else {
                            Button("Pair") { codeEntry = ""; model.beginPair(with: name) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

            Text("Keep both devices nearby (Bluetooth). On the iPhone, turn on Settings → Watch & Garmin → Remote access, then Pair a remote. Scan its QR here, or type the one-time code.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showScanner) {
            VStack(spacing: 12) {
                Text("Scan the QR shown on your iPhone").font(.headline)
                MacQRScanner { scanned in
                    showScanner = false
                    if let payload = PeerPairingPayload(qrString: scanned) { model.applyScannedPayload(payload) }
                }
                .frame(width: 360, height: 360)
                Button("Cancel") { showScanner = false }
            }
            .padding()
        }
    }

    private func submit() {
        let code = codeEntry.filter(\.isNumber)
        guard code.count == MacPairing.codeLength else { return }
        model.submitCode(code)
        codeEntry = ""
    }

    private var statusText: String {
        if pairing.authenticated { return "Connected" }
        if pairing.connected { return "Pairing…" }
        return "Not connected"
    }
    private var statusColor: Color {
        if pairing.authenticated { return .green }
        if pairing.connected { return .orange }
        return .secondary
    }
}
