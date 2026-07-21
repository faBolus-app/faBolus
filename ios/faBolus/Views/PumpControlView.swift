import SwiftUI
import faBolusCore

/// Advanced pump control (Workstream B3). Reachable only when `model.advancedControlAllowed`
/// (opt-in "Advanced control" ON + a Mobi pump + backend capability). Insulin-affecting actions
/// require an explicit confirm; the backend additionally clamps + gates via WritePolicy, and these
/// commands must be bench-validated on saline before being relied upon.
struct PumpControlView: View {
    @Bindable var model: AppModel
    @State private var confirm: PendingAction?
    @State private var tempPercent: Double = 100
    @State private var tempDurationMin: Int = 60
    @State private var busy = false

    private struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let destructive: Bool
        let run: () async -> Void
    }

    private var caps: PumpCapabilities { model.capabilities }

    var body: some View {
        Form {
            Section {
                Label("Advanced control is enabled for this Mobi. Insulin-affecting actions ask for "
                      + "confirmation and are bench-validated. Use with care.", systemImage: "exclamationmark.shield.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if caps.supportsSuspendResume {
                Section("Insulin delivery") {
                    if model.snapshot.deliverySuspended {
                        Button { ask("Resume insulin?", "Insulin delivery will resume at the active basal rate.", destructive: false) { await model.resumeDelivery() } }
                            label: { Label("Resume insulin", systemImage: "play.fill") }
                    } else {
                        Button(role: .destructive) { ask("Suspend insulin?", "All insulin delivery (basal + Control-IQ) stops until you resume.", destructive: true) { await model.suspendDelivery() } }
                            label: { Label("Suspend insulin", systemImage: "pause.fill") }
                    }
                }
            }

            if caps.supportsTempBasal {
                Section("Temp basal") {
                    VStack(alignment: .leading) {
                        Text("Rate: \(Int(tempPercent))% of basal").font(.subheadline)
                        Slider(value: $tempPercent, in: 0...250, step: 5)
                    }
                    Picker("Duration", selection: $tempDurationMin) {
                        ForEach([30, 60, 120, 180, 240], id: \.self) { Text("\($0 / 60 == 0 ? "\($0) min" : "\($0 / 60) h")").tag($0) }
                    }
                    Button { ask("Set temp basal?", "\(Int(tempPercent))% for \(tempDurationMin) min. Control-IQ must be off.", destructive: true) {
                        await model.setTempBasal(percent: Int(tempPercent), durationMinutes: tempDurationMin) } }
                        label: { Label("Start temp basal", systemImage: "timer") }
                    Button(role: .destructive) { ask("Stop temp basal?", "Return to the scheduled basal rate.", destructive: false) { await model.stopTempBasal() } }
                        label: { Label("Stop temp basal", systemImage: "timer.slash") }
                }
            }

            if caps.supportsModes {
                Section("Mode") {
                    Text("Current: \(modeName(model.snapshot.controlIQMode))").font(.subheadline).foregroundStyle(.secondary)
                    ForEach([(0, "Normal"), (1, "Sleep"), (2, "Exercise")], id: \.0) { bitmap, name in
                        Button { ask("Set \(name) mode?", "Changes Control-IQ behavior.", destructive: true) { await model.setMode(bitmap: bitmap) } }
                            label: { Label(name, systemImage: bitmap == 1 ? "moon.zzz.fill" : bitmap == 2 ? "figure.run" : "checkmark.circle") }
                    }
                }
            }

            if caps.supportsCgmSession {
                Section("CGM sensor") {
                    NavigationLink { CgmSessionView(model: model) } label: {
                        Label(model.snapshot.cgmSessionActive ? "CGM session — active" : "Start / stop CGM session",
                              systemImage: "sensor.tag.radiowaves.forward.fill")
                    }
                }
            }

            if caps.supportsCartridgeFill {
                Section("Cartridge & site") {
                    NavigationLink { CartridgeWizardView(model: model) } label: {
                        Label("Change cartridge / fill", systemImage: "cross.vial.fill")
                    }
                }
            }

            if caps.supportsLimits {
                Section("Limits") {
                    NavigationLink { PumpLimitsView(model: model) } label: {
                        Label("Delivery limits", systemImage: "slider.horizontal.3")
                    }
                }
            }

            if caps.supportsTimeSync {
                Section("Time") {
                    Button { ask("Sync pump time?", "Set the pump clock to this phone's current time.", destructive: false) { await model.syncTimeToNow() } }
                        label: { Label("Sync pump time to phone", systemImage: "clock.arrow.2.circlepath") }
                }
            }

            if caps.supportsControlIQSettings {
                Section("Control-IQ") {
                    NavigationLink { ControlIQSettingsView(model: model) } label: {
                        Label("Control-IQ settings", systemImage: "brain.head.profile")
                    }
                }
            }

            if caps.supportsProfiles {
                Section("Profiles") {
                    NavigationLink { ProfilesView(model: model) } label: {
                        Label("Insulin profiles", systemImage: "person.crop.circle")
                    }
                }
            }

            if caps.supportsReminders {
                Section("Reminders & alerts") {
                    NavigationLink { RemindersAlertsView(model: model) } label: {
                        Label("Reminders & alert settings", systemImage: "bell.badge")
                    }
                }
            }

            Section("Pump") {
                Button { Task { busy = true; await model.playFindMyPump(); busy = false } }
                    label: { Label("Find my pump (play sound)", systemImage: "speaker.wave.3.fill") }
            }

            if let err = model.lastError {
                Section { Text(err).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Pump Control")
        .disabled(busy)
        .alert(item: $confirm) { action in
            Alert(title: Text(action.title), message: Text(action.message),
                  primaryButton: action.destructive
                    ? .destructive(Text("Confirm")) { run(action) }
                    : .default(Text("Confirm")) { run(action) },
                  secondaryButton: .cancel())
        }
    }

    private func ask(_ title: String, _ message: String, destructive: Bool, _ run: @escaping () async -> Void) {
        confirm = PendingAction(title: title, message: message, destructive: destructive, run: run)
    }
    private func run(_ action: PendingAction) {
        Task { busy = true; await action.run(); busy = false }
    }
    private func modeName(_ m: Int) -> String { m == 1 ? "Sleep" : m == 2 ? "Exercise" : "Normal" }
}
