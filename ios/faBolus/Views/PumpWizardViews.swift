import SwiftUI
import faBolusCore

// Mobi control wizards (Plan A / A4). Reached from PumpControlView, so already behind the
// advanced-control + Mobi + capability gate. Insulin-affecting steps use hold-to-confirm; all of
// these must be bench-validated on saline before being relied on. Mirrors controlX2's flows.

/// Press-and-hold confirm for the highest-risk (insulin-affecting) steps — a deliberate gesture,
/// not a single tap. Fills over `duration`, then fires once.
struct HoldToConfirmButton: View {
    let title: String
    let systemImage: String
    var duration: Double = 1.2
    let action: () async -> Void

    @State private var progress: Double = 0
    @State private var firing = false

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.25))
                    .frame(width: geo.size.width * progress)
            }
            Label(firing ? "Working…" : "Hold to \(title)", systemImage: systemImage)
                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: duration)
                .onChanged { _ in withAnimation(.linear(duration: duration)) { progress = 1 } }
                .onEnded { _ in fire() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).onEnded { _ in
                if !firing { withAnimation(.easeOut(duration: 0.2)) { progress = 0 } }
            }
        )
        .disabled(firing)
    }

    private func fire() {
        guard !firing else { return }
        firing = true
        Task { await action(); firing = false; progress = 0 }
    }
}

// MARK: - CGM sensor session

struct CgmSessionView: View {
    @Bindable var model: AppModel
    enum Kind: String, CaseIterable, Identifiable { case g6 = "G6 / G5 / ONE", g7 = "G7 / ONE+"; var id: String { rawValue } }
    @State private var kind: Kind = .g7
    @State private var transmitterID = ""
    @State private var sensorCode = ""
    @State private var pairingCode = ""
    @State private var busy = false
    @State private var readingTx = false

    var body: some View {
        Form {
            Section {
                Label(model.snapshot.cgmSessionActive ? "A CGM session is active." : "No CGM session active.",
                      systemImage: model.snapshot.cgmSessionActive ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(model.snapshot.cgmSessionActive ? AppTheme.inRange : .secondary)
            }

            Picker("Sensor", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            if kind == .g6 {
                Section {
                    HStack {
                        TextField("Transmitter ID (6 chars)", text: $transmitterID)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button {
                            readingTx = true
                            Task { if let id = await model.readG6TransmitterId() { transmitterID = id }; readingTx = false }
                        } label: { if readingTx { ProgressView() } else { Image(systemName: "arrow.down.circle") } }
                            .disabled(readingTx)
                    }
                    TextField("Sensor code (or 0000 to join)", text: $sensorCode)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("The sensor code is on the applicator/box. Enter 0000 to join an already-running session. “Read” fills the transmitter ID from the pump.")
                }
                Section {
                    Button { start { await model.startG6Session(transmitterId: transmitterID, sensorCode: Int(sensorCode) ?? 0) } }
                        label: { Label("Start G6 session", systemImage: "play.circle") }
                        .disabled(busy)
                }
            } else {
                Section {
                    TextField("Pairing code", text: $pairingCode).keyboardType(.numberPad)
                } footer: {
                    Text("The G7/ONE+ pairing code is on the sensor applicator.")
                }
                Section {
                    Button { start { await model.startG7Session(pairingCode: Int(pairingCode) ?? 0) } }
                        label: { Label("Start G7 session", systemImage: "play.circle") }
                        .disabled(busy || Int(pairingCode) == nil)
                }
            }

            if model.snapshot.cgmSessionActive {
                Section {
                    Button(role: .destructive) { start { await model.stopCgmSession() } }
                        label: { Label("Stop CGM session", systemImage: "stop.circle") }
                        .disabled(busy)
                } footer: {
                    Text("Stopping ends the current sensor session on the pump.")
                }
            }

            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("CGM Session")
        .task { await model.refreshCgmSession() }
    }

    private func start(_ op: @escaping () async -> Void) {
        busy = true
        Task { await op(); await model.refreshCgmSession(); busy = false }
    }
}

// MARK: - Cartridge change / fill wizard

struct CartridgeWizardView: View {
    @Bindable var model: AppModel
    @State private var primeUnits: Double = 0.3
    @State private var busy = false

    private var loadStateLabel: String {
        switch model.snapshot.cartridgeLoadState {
        case 0: return "Change cartridge"
        case 1: return "Load cartridge"
        case 2: return "Prime tubing"
        case 3: return "Prime cannula"
        case 4: return "Prime nudge"
        case 5: return "Invalid"
        default: return "Idle / unknown"
        }
    }

    var body: some View {
        Form {
            Section {
                Label("These steps stop and restart insulin delivery. Follow the pump's on-screen "
                      + "prompts too. Bench-validate on saline before using on a body.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                LabeledContent("Pump load state", value: loadStateLabel)
                Button { Task { await model.refreshLoadStatus() } } label: { Label("Refresh state", systemImage: "arrow.clockwise") }
            }

            if model.hasActiveNotifications {
                Section {
                    Label("Clear active pump notifications first (Alerts tab) — the pump won't enter "
                          + "change-cartridge mode while notifications are pending.", systemImage: "bell.badge")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("1 · Change cartridge") {
                HoldToConfirmButton(title: "enter change mode", systemImage: "cross.vial") {
                    await run { await model.enterChangeCartridgeMode() }
                }.disabled(busy || model.hasActiveNotifications)
                Button { Task { await run { await model.exitChangeCartridgeMode() } } }
                    label: { Label("Cartridge swapped — finish & detect", systemImage: "checkmark.circle") }
                    .disabled(busy)
            }

            Section("2 · Fill tubing") {
                HoldToConfirmButton(title: "start fill tubing", systemImage: "drop.triangle") {
                    await run { await model.enterFillTubingMode() }
                }.disabled(busy)
                Button { Task { await run { await model.exitFillTubingMode() } } }
                    label: { Label("Tubing filled — finish", systemImage: "checkmark.circle") }
                    .disabled(busy)
            }

            Section("3 · Fill cannula") {
                VStack(alignment: .leading) {
                    Text("Prime amount: \(String(format: "%.2f", primeUnits)) U").font(.subheadline)
                    Slider(value: $primeUnits, in: 0.05...(Double(FillLimits.maxCannulaMilliunits) / 1000), step: 0.05)
                }
                HoldToConfirmButton(title: "fill cannula", systemImage: "drop.fill") {
                    await run { await model.fillCannula(milliunits: Int((primeUnits * 1000).rounded())) }
                }.disabled(busy)
            }

            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Cartridge & Fill")
        .task { await model.refreshLoadStatus() }
    }

    private func run(_ op: () async -> Void) async {
        busy = true; await op(); await model.refreshLoadStatus(); busy = false
    }
}

// MARK: - Delivery limits

struct PumpLimitsView: View {
    @Bindable var model: AppModel
    @State private var maxBolus: Double = 10
    @State private var maxBasal: Double = 3
    @State private var busy = false

    var body: some View {
        Form {
            Section("Max bolus") {
                Stepper(value: $maxBolus, in: 0.5...Interlocks.absoluteMaxUnits, step: 0.5) {
                    Text("\(String(format: "%.1f", maxBolus)) U")
                }
                Button { set { await model.setMaxBolus(units: maxBolus) } }
                    label: { Label("Set max bolus", systemImage: "checkmark.circle") }.disabled(busy)
            }
            Section {
                Stepper(value: $maxBasal, in: 0...15, step: 0.5) { Text("\(String(format: "%.1f", maxBasal)) U/hr") }
                Button { set { await model.setMaxBasal(unitsPerHour: maxBasal) } }
                    label: { Label("Set max basal", systemImage: "checkmark.circle") }.disabled(busy)
            } header: {
                Text("Max basal")
            } footer: {
                Text("These are the pump's safety ceilings. The bolus screen still caps at the pump's max bolus.")
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Delivery Limits")
        .onAppear { maxBolus = min(max(0.5, model.snapshot.maxBolusUnits), Interlocks.absoluteMaxUnits) }
    }

    private func set(_ op: @escaping () async -> Void) { busy = true; Task { await op(); busy = false } }
}
