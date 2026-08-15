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
    @State private var showClinicianTierAck = false

    private struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let destructive: Bool
        let run: () async -> Void
    }

    private var caps: PumpCapabilities { model.capabilities }
    /// C1 (§2.4): the connected pump's Control-IQ family name (Control-IQ vs Control-IQ+), from the pump's
    /// own op-79 bits, with a generic "Control-IQ" fallback for the pre-feature-read window. Used only in
    /// the Control-IQ-capability-gated sections below. Display only.
    private var ciq: String { model.snapshot.controlIQBrandName }
    /// P14 S8: does this pump expose any clinician-tier section here? Gates the one-time disclosure.
    private var hasClinicianTierSection: Bool {
        caps.supportsLimits || caps.supportsControlIQSettings || caps.supportsProfiles
    }

    var body: some View {
        Form {
            if !model.pumpReady {
                Section {
                    Label("Pump not connected. Reconnect to make changes — these controls stay disabled until the pump is back.",
                          systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Label("Advanced control is enabled for this Mobi. Insulin-affecting actions ask for "
                      + "confirmation and are bench-validated. Use with care.", systemImage: "exclamationmark.shield.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if caps.supportsSuspendResume {
                Section {
                    if model.snapshot.deliverySuspended {
                        Button { ask("Resume insulin?", "Insulin delivery will resume at the active basal rate.", destructive: false) { await model.resumeDelivery() } }
                            label: { Label("Resume insulin", systemImage: "play.fill") }
                    } else {
                        Button(role: .destructive) { ask("Suspend insulin?", "All insulin delivery (basal + \(ciq)) stops until you resume.", destructive: true) { await model.suspendDelivery() } }
                            label: { Label("Suspend insulin", systemImage: "pause.fill") }
                    }
                } header: {
                    Text("Insulin delivery")
                } footer: {
                    // 09.2-02 (D-01/D-05, SC1): the honest recovery guidance a wizard Exit lands on — reuses
                    // the existing shared `deliverySuspended` snapshot field (already surfaced at
                    // StatusPillsView/widgets/Live Activity). Presentation copy only: no delivery-path call,
                    // no change to the suspend/resume button logic above.
                    if model.snapshot.deliverySuspended {
                        Text("Insulin delivery is suspended. Finish the cartridge change or tubing/cannula fill, or reconnect to the pump, then resume above.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if caps.supportsTempBasal {
                Section("Temp basal") {
                    VStack(alignment: .leading) {
                        Text("Rate: \(Int(tempPercent))% of basal").font(.subheadline)
                        // P13c-5: bounds sourced from the kit's firmware limits (drift-guarded), not a literal.
                        Slider(value: $tempPercent,
                               in: Double(PumpControlBounds.tempRateMinPercent)...Double(PumpControlBounds.tempRateMaxPercent),
                               step: 5)
                    }
                    Picker("Duration", selection: $tempDurationMin) {
                        ForEach([30, 60, 120, 180, 240], id: \.self) { Text("\($0 / 60 == 0 ? "\($0) min" : "\($0 / 60) h")").tag($0) }
                    }
                    Button {
                        // D-02 (Phase 09.5): the experimental build no longer enforces the CIQ-off
                        // precondition (AppModel.setTempBasal), so its confirm copy must not assert one
                        // it no longer requires — the #if here mirrors the one there exactly.
                        #if !FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL
                        let confirmBody = "\(Int(tempPercent))% for \(tempDurationMin) min. \(ciq) must be off."
                        #else
                        let confirmBody = "\(Int(tempPercent))% for \(tempDurationMin) min."
                        #endif
                        ask("Set temp basal?", confirmBody, destructive: true) {
                        await model.setTempBasal(percent: Int(tempPercent), durationMinutes: tempDurationMin) } }
                        label: { Label("Start temp basal", systemImage: "timer") }
                    Button(role: .destructive) { ask("Stop temp basal?", "Return to the scheduled basal rate.", destructive: false) { await model.stopTempBasal() } }
                        label: { Label("Stop temp basal", systemImage: "timer.slash") }
                }
            }

            if caps.supportsModes {
                Section {
                    Text("Current: \(modeName(model.snapshot.controlIQMode))").font(.subheadline).foregroundStyle(.secondary)
                    // P16 S3: stamp the manual mode change so scheduled automation defers to this hands-on
                    // action for the next hour (see AppModel.noteManualModeChange / ModeAutomation).
                    Button { ask("Set Normal mode?", "Clears Sleep/Exercise and returns \(ciq) to normal targets.", destructive: true) { model.noteManualModeChange(); await model.setNormalMode() } }
                        label: { Label("Normal", systemImage: "checkmark.circle") }
                    Button { ask("Set Sleep mode?", "\(ciq) uses your sleep glucose targets.", destructive: true) { model.noteManualModeChange(); await model.setSleepMode(true) } }
                        label: { Label("Sleep", systemImage: "moon.zzz.fill") }
                    Button { ask("Set Exercise mode?", "\(ciq) raises your glucose target for activity.", destructive: true) { model.noteManualModeChange(); await model.setExerciseMode(true) } }
                        label: { Label("Exercise", systemImage: "figure.run") }
                } header: { Text("Mode") } footer: {
                    Text("Requires \(ciq) to be on. Available on Mobi. Can also be automated — see Activity & sleep automation in Settings.")
                }
            }

            // Phase 09.10 D-04 / RESEARCH Pitfall 2: the READ is universal — this NavigationLink is
            // deliberately UNGATED (no `if caps.supportsX`), a sibling of the ungated "Pump" section
            // below, reachable on any connected pump (Mobi or t:slim) whenever pumpReady. Only
            // SleepScheduleView's INTERNAL write controls branch on `caps.supportsSleepScheduleWrite`.
            Section("Sleep schedule") {
                NavigationLink { SleepScheduleView(model: model) } label: {
                    Label("Sleep schedule", systemImage: "moon.zzz.fill")
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
                Section {
                    NavigationLink { PumpLimitsView(model: model) } label: {
                        Label("Delivery limits", systemImage: "slider.horizontal.3")
                    }
                } header: { Text("Limits") } footer: { Text(ClinicianTierAck.sectionLabel).font(.footnote) }
            }

            if caps.supportsTimeSync {
                Section("Time") {
                    Button { ask("Sync pump time?", "Set the pump clock to this phone's current time.", destructive: false) { await model.syncTimeToNow() } }
                        label: { Label("Sync pump time to phone", systemImage: "clock.arrow.2.circlepath") }
                }
            }

            if caps.supportsControlIQSettings {
                Section {
                    NavigationLink { ControlIQSettingsView(model: model) } label: {
                        Label("\(ciq) settings", systemImage: "brain.head.profile")
                    }
                } header: { Text(ciq) } footer: { Text(ClinicianTierAck.sectionLabel).font(.footnote) }
            }

            if caps.supportsProfiles {
                Section {
                    NavigationLink { ProfilesView(model: model) } label: {
                        Label("Insulin profiles", systemImage: "person.crop.circle")
                    }
                } header: { Text("Profiles") } footer: { Text(ClinicianTierAck.sectionLabel).font(.footnote) }
            }

            // §2.1(3) B1(b): the therapy-settings change log (origin + before/after + when). Read-only
            // disclosure, here in the therapy hub (already advanced-control + not-read-only gated), so a
            // plain caregiver/viewer phone never surfaces it.
            Section {
                NavigationLink { SettingChangeLogView(model: model) } label: {
                    Label("Change log", systemImage: "clock.arrow.circlepath")
                }
            } footer: { Text("Every therapy-setting change, with its origin and time — stays on this device.").font(.footnote) }

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
        // P14 S8 (§2.1(2)): first-use clinician-tier disclosure — shown once ever (persisted), and only
        // when a clinician-tier section is present. Non-blocking: the settings stay usable regardless;
        // this only records that clinical ownership was disclosed (it is NOT a gate / DenialReason).
        .onAppear {
            if !AppSettings.shared.hasAcknowledgedClinicianTier && hasClinicianTierSection {
                showClinicianTierAck = true
            }
        }
        .alert("Clinician-tier settings", isPresented: $showClinicianTierAck) {
            Button("I understand") { AppSettings.shared.acknowledgeClinicianTier() }
        } message: {
            Text(ClinicianTierAck.disclosure)
        }
        // Gate every action (and the NavigationLinks into the wizards) on a live pump connection.
        .disabled(busy || !model.pumpReady)
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
