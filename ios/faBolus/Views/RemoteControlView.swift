import SwiftUI
import faBolusCore

/// "Control another phone" — this iPhone acting as a remote for another phone's pump. Pairs over BLE
/// (QR or code), then mirrors the host: status (reusing the host dashboard subviews), alerts, and a
/// bolus screen that confirms on THIS device. The central runs only while this screen is open.
struct RemoteControlView: View {
    @State private var model = PhoneRemoteClientModel()
    @State private var showScanner = false
    @State private var codeEntry = ""
    @State private var showBolus = false

    var body: some View {
        Group {
            if model.conn.authenticated {
                connectedBody
            } else {
                pairingBody
            }
        }
        .navigationTitle("Remote control")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { scanned in
                    showScanner = false
                    if let payload = PeerPairingPayload(qrString: scanned) { model.applyScannedPayload(payload) }
                }
                .ignoresSafeArea()
                .navigationTitle("Scan the host's QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
            }
        }
        .sheet(isPresented: $showBolus) { RemoteBolusSheet(model: model) }
        .alert("Approve bolus?", isPresented: Binding(
            get: { model.incomingApproval != nil },
            set: { if !$0 { model.respondToApproval(false) } }
        )) {
            Button("Approve", role: .destructive) { model.respondToApproval(true) }
            Button("Deny", role: .cancel) { model.respondToApproval(false) }
        } message: {
            Text("\(model.conn.pairedHost ?? "The host") is asking to deliver \(String(format: "%.2f U", model.incomingApproval?.units ?? 0)).")
        }
    }

    // MARK: Pairing

    private var pairingBody: some View {
        Form {
            Section {
                Button { showScanner = true } label: { Label("Scan the host's QR code", systemImage: "qrcode.viewfinder") }
                if model.conn.needsCode {
                    HStack {
                        TextField("6-digit code", text: $codeEntry).keyboardType(.numberPad)
                        Button("Pair") { model.submitCode(codeEntry); codeEntry = "" }
                            .disabled(codeEntry.filter(\.isNumber).count < 6)
                    }
                }
                if let err = model.conn.pairingError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
            } header: { Text("Pair with the host phone") } footer: {
                Text("On the host phone: Settings → Watch & Garmin → Remote access → turn on “Allow remote devices”, then Pair a remote → QR. Scan it here. The host controls what this phone may do.")
            }

            Section("Nearby hosts") {
                if model.conn.discoveredHosts.isEmpty {
                    Text("Searching… make sure the host phone has remote access enabled and is nearby.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.conn.discoveredHosts, id: \.self) { name in
                    Button { model.beginPair(with: name) } label: {
                        HStack {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            Text(name)
                            Spacer()
                            if model.conn.pairedHost == name {
                                Image(systemName: model.conn.connected ? "checkmark.circle.fill" : "ellipsis.circle")
                                    .foregroundStyle(model.conn.connected ? .green : .secondary)
                            }
                        }
                    }.tint(.primary)
                }
            }
        }
    }

    // MARK: Connected (full-parity mirror)

    private var connectedBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                StatusRingView(snapshot: model.asSnapshot)
                if !model.reachable {
                    Label("Reconnecting…", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                }
                StatusPillsView(snapshot: model.asSnapshot).padding(.horizontal)
                GlucoseChartView(readings: model.readings, iob: [], boluses: [], windowHours: 6,
                                 showGlucose: true, showIOB: false, showBolusBars: false)
                    .padding(.horizontal)

                if AppSettings.shared.showStats { StatsCardView(history: model.readings) }

                if !model.alerts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.alerts, id: \.id) { a in
                            HStack {
                                Label(a.title, systemImage: "bell.fill").font(.callout)
                                Spacer()
                                Button("Clear") { model.dismissAlert(a) }.font(.caption)
                            }
                        }
                    }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
                }

                Button { showBolus = true } label: {
                    Label("Bolus", systemImage: "syringe.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin).padding(.horizontal)
                .disabled(!model.reachable)

                if let msg = model.statusMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                Text("Remote — commands run on the host phone, which decides what's allowed.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                Button("Forget this host", role: .destructive) { model.conn.forget() }.font(.caption)
            }.padding(.vertical)
        }
    }
}

/// Compact remote bolus entry (carbs or units, optional extended split). Confirms on this device;
/// the host runs it (subject to the permissions the host granted this remote).
private struct RemoteBolusSheet: View {
    let model: PhoneRemoteClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0            // 0 = carbs, 1 = units
    @State private var carbs = ""
    @State private var units = ""
    @State private var extendedOn = false
    @State private var nowPct = 50
    @State private var durationMin = 120
    @State private var confirming = false

    private var enteredUnits: Double {
        if mode == 1 { return Double(units) ?? 0 }
        return model.estimatedUnits(forCarbs: Double(carbs) ?? 0) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) { Text("Carbs").tag(0); Text("Units").tag(1) }
                    .pickerStyle(.segmented)
                if mode == 0 {
                    HStack { TextField("0", text: $carbs).keyboardType(.numberPad); Text("g").foregroundStyle(.secondary) }
                    LabeledContent("Estimated", value: String(format: "%.2f U", enteredUnits))
                } else {
                    HStack { TextField("0", text: $units).keyboardType(.decimalPad); Text("U").foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Extended (combo)", isOn: $extendedOn)
                    if extendedOn {
                        Stepper("Now: \(nowPct)%", value: $nowPct, in: 0...100, step: 10)
                        Stepper("Over \(durationMin) min", value: $durationMin, in: 30...480, step: 30)
                    }
                }
                Button {
                    confirming = true
                } label: {
                    HStack { Spacer(); Text("Bolus \(String(format: "%.2f U", enteredUnits))"); Spacer() }
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.insulin)
                .disabled(enteredUnits < (extendedOn ? 0.4 : 0.05))
            }
            .navigationTitle("Remote bolus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Send \(String(format: "%.2f U", enteredUnits)) to the host pump?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Send \(String(format: "%.2f U", enteredUnits))", role: .destructive) { send() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("faBolus is experimental and not FDA-cleared. This delivers on the other phone's pump.")
            }
        }
    }

    private func send() {
        let u = enteredUnits
        if extendedOn {
            model.deliverExtended(totalUnits: u, nowUnits: u * Double(nowPct) / 100, durationMinutes: durationMin)
        } else if mode == 0 {
            model.deliverCarbs(Double(carbs) ?? 0)
        } else {
            model.deliverUnits(u)
        }
        dismiss()
    }
}

// MARK: - Adapter: present the remote read-model through the host's value-driven subviews.
private extension RemoteClientModel {
    var asSnapshot: PumpSnapshot {
        var s = PumpSnapshot()
        s.glucose = glucose
        s.glucoseDate = glucoseDate
        s.trend = GlucoseTrend(rawValue: trend)?.rawValue ?? trend
        s.iobUnits = iobUnits
        s.reservoirUnits = reservoirUnits
        s.batteryPercent = batteryPercent
        s.carbRatio = carbRatio
        s.isf = isf
        s.targetBg = targetBg
        s.maxBolusUnits = maxBolusUnits
        s.lastBolusUnits = lastBolusUnits
        s.connection = reachable ? .connected : .disconnected
        return s
    }
    /// Synthesize dated readings from the relayed mg/dL history (5-min spacing ending now) so the
    /// host's chart + stats views render unchanged.
    var readings: [GlucoseReading] {
        let now = glucoseDate ?? Date()
        let n = history.count
        return history.enumerated().map { i, mgdl in
            GlucoseReading(date: now.addingTimeInterval(Double(i - (n - 1)) * 300), mgdl: mgdl)
        }
    }
}
