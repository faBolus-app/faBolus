import SwiftUI

/// Loop-style main screen: glucose chart, status ring, HUD pills, and a bottom toolbar for
/// carb/bolus/connection actions. ControlX2 is a manual remote-bolus + status viewer.
struct MainHUDView: View {
    @Bindable var model: AppModel
    @State private var showBolus = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GlucoseChartView(readings: model.glucoseHistory)
                        .padding(.horizontal)

                    StatusRingView(snapshot: model.snapshot)

                    if let u = model.snapshot.lastBolusUnits, let d = model.snapshot.lastBolusDate {
                        Text("Last bolus: \(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) { StatusPillsView(snapshot: model.snapshot) }
                        .padding(.horizontal)

                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(LoopTheme.low).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("ControlX2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { connectionButton }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { showBolus = true } label: { Label("Bolus", systemImage: "drop.fill") }
                        .disabled(model.snapshot.connection != .connected)
                    Spacer()
                    Text("Bench PoC — saline only").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if model.snapshot.connection == .bolusing {
                        Button(role: .destructive) { Task { await model.cancelBolus() } } label: {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $showBolus) { BolusEntryView(model: model) }
            .alert("Remote bolus request", isPresented: .constant(model.pendingRemoteBolus != nil)) {
                Button("Deliver \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0))", role: .destructive) {
                    Task { await model.confirmRemoteBolus() }
                }
                Button("Reject", role: .cancel) { model.rejectRemoteBolus() }
            } message: {
                Text("A remote requested \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0)) of SALINE. Confirm to deliver on the bench.")
            }
        }
    }

    @ViewBuilder private var connectionButton: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            Button("Connect") { Task { await model.connect() } }
        case .connected, .bolusing:
            Button("Disconnect") { model.disconnect() }
        default:
            ProgressView()
        }
    }
}

#Preview {
    MainHUDView(model: AppModel(source: MockPumpDataSource()))
}
