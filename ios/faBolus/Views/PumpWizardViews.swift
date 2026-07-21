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

// MARK: - Control-IQ settings

struct ControlIQSettingsView: View {
    @Bindable var model: AppModel
    @State private var enabled = true
    @State private var weightLbs: Double = 150
    @State private var tdi: Double = 40
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Control-IQ closed loop", isOn: $enabled)
            } footer: {
                Text("Turning Control-IQ off stops automatic basal adjustments. Weight and total daily insulin are used by the algorithm.")
            }
            Section("Weight") {
                Stepper(value: $weightLbs, in: 40...400, step: 1) { Text("\(Int(weightLbs)) lb") }
            }
            Section("Total daily insulin") {
                Stepper(value: $tdi, in: 1...300, step: 1) { Text("\(Int(tdi)) U/day") }
            }
            Section {
                Button { save() } label: { Label(busy ? "Saving…" : "Save Control-IQ settings", systemImage: "checkmark.circle") }
                    .disabled(busy)
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Control-IQ")
        .task {
            await model.refreshControlIQSettings()
            if !loaded {
                enabled = model.snapshot.controlIQEnabled
                if model.snapshot.controlIQWeightLbs > 0 { weightLbs = Double(model.snapshot.controlIQWeightLbs) }
                if model.snapshot.controlIQTotalDailyInsulin > 0 { tdi = Double(model.snapshot.controlIQTotalDailyInsulin) }
                loaded = true
            }
        }
    }

    private func save() {
        busy = true
        Task { await model.setControlIQ(enabled: enabled, weightLbs: Int(weightLbs), totalDailyInsulinUnits: Int(tdi)); busy = false }
    }
}

// MARK: - Insulin profiles (switch / rename / delete)

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var busy = false
    @State private var switchTo: PumpProfileInfo?
    @State private var deleteTarget: PumpProfileInfo?
    @State private var renameTarget: PumpProfileInfo?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                ForEach(model.snapshot.profiles) { p in
                    NavigationLink {
                        ProfileSegmentsView(model: model, idpId: p.idpId, profileName: p.name.isEmpty ? "Profile \(p.idpId)" : p.name)
                    } label: {
                        HStack {
                            Image(systemName: p.active ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(p.active ? AppTheme.inRange : .secondary)
                            Text(p.name.isEmpty ? "Profile \(p.idpId)" : p.name)
                            if p.active { Spacer(); Text("Active").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { deleteTarget = p } label: { Label("Delete", systemImage: "trash") }
                            .disabled(p.active)
                        Button { renameTarget = p; renameText = p.name } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                        if !p.active { Button { switchTo = p } label: { Label("Switch", systemImage: "arrow.left.arrow.right") }.tint(.green) }
                    }
                }
                if model.snapshot.profiles.isEmpty { Text("No profiles loaded yet.").foregroundStyle(.secondary) }
            } footer: {
                Text("Tap a profile to view/edit its time segments. Swipe to switch (changes your basal schedule), rename, or delete. The active profile can't be deleted.")
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Profiles")
        .disabled(busy)
        .toolbar {
            NavigationLink { ProfileCreateView(model: model) } label: { Image(systemName: "plus") }
        }
        .task { await model.refreshProfiles() }
        .alert("Switch profile?", isPresented: Binding(get: { switchTo != nil }, set: { if !$0 { switchTo = nil } })) {
            Button("Switch", role: .destructive) { if let p = switchTo { run { await model.setActiveProfile(idpId: p.idpId) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Make “\(switchTo?.name ?? "")” the active profile? This changes your basal schedule.") }
        .alert("Delete profile?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) { if let p = deleteTarget { run { await model.deleteProfile(idpId: p.idpId) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Delete “\(deleteTarget?.name ?? "")”? This can't be undone.") }
        .alert("Rename profile", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let p = renameTarget { run { await model.renameProfile(idpId: p.idpId, name: renameText) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func run(_ op: @escaping () async -> Void) { busy = true; Task { await op(); busy = false } }
}

// MARK: - Reminders & alert settings

struct RemindersAlertsView: View {
    @Bindable var model: AppModel
    @State private var lowInsulin: Double = 20
    @State private var autoOffOn = true
    @State private var autoOffHrs: Double = 12
    @State private var siteOn = true
    @State private var siteDays: Double = 3
    @State private var snoozeOn = true
    @State private var snoozeMin: Double = 30
    @State private var cgmHigh: Double = 180
    @State private var cgmLow: Double = 70
    @State private var cgmOorOn = true
    @State private var cgmOorDelay: Double = 20
    @State private var busy = false

    var body: some View {
        Form {
            Section("Low insulin alert") {
                Stepper(value: $lowInsulin, in: 5...50, step: 5) { Text("Alert at \(Int(lowInsulin)) U") }
                setButton { await model.setLowInsulinAlert(thresholdUnits: Int(lowInsulin)) }
            }
            Section("Auto-off") {
                Toggle("Enabled", isOn: $autoOffOn)
                Stepper(value: $autoOffHrs, in: 1...24, step: 1) { Text("\(Int(autoOffHrs)) h without interaction") }
                setButton { await model.setAutoOffAlert(enabled: autoOffOn, durationMinutes: Int(autoOffHrs) * 60) }
            }
            Section("Site-change reminder") {
                Toggle("Enabled", isOn: $siteOn)
                Stepper(value: $siteDays, in: 1...5, step: 1) { Text("Every \(Int(siteDays)) days") }
                setButton { await model.setSiteChangeReminder(enabled: siteOn, days: Int(siteDays), timeOfDayMinutes: 9 * 60) }
            }
            Section("Alert snooze") {
                Toggle("Enabled", isOn: $snoozeOn)
                Stepper(value: $snoozeMin, in: 5...120, step: 5) { Text("\(Int(snoozeMin)) min") }
                setButton { await model.setAlertSnooze(enabled: snoozeOn, durationMinutes: Int(snoozeMin)) }
            }
            Section {
                Stepper(value: $cgmHigh, in: 120...300, step: 5) { Text("High alert at \(Int(cgmHigh)) mg/dL") }
                setButton { await model.setCgmHighLowAlert(alertType: 1, thresholdMgdl: Int(cgmHigh), repeatMinutes: 0, enabled: true) }
                Stepper(value: $cgmLow, in: 60...120, step: 5) { Text("Low alert at \(Int(cgmLow)) mg/dL") }
                setButton { await model.setCgmHighLowAlert(alertType: 0, thresholdMgdl: Int(cgmLow), repeatMinutes: 0, enabled: true) }
            } header: {
                Text("CGM high / low alerts")
            } footer: {
                Text("⚠️ Experimental: the high vs low alert-type mapping is an **unverified best guess** — after setting, check on the pump that the intended threshold actually changed. See docs/UNVERIFIED-GUESSES.md.")
            }
            Section("CGM out-of-range alert") {
                Toggle("Enabled", isOn: $cgmOorOn)
                Stepper(value: $cgmOorDelay, in: 20...300, step: 5) { Text("After \(Int(cgmOorDelay)) min") }
                setButton { await model.setCgmOutOfRangeAlert(enabled: cgmOorOn, delayMinutes: Int(cgmOorDelay)) }
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("Reminders & Alerts")
        .disabled(busy)
    }

    @ViewBuilder private func setButton(_ op: @escaping () async -> Void) -> some View {
        Button { busy = true; Task { await op(); busy = false } } label: {
            Label("Set", systemImage: "checkmark.circle").font(.subheadline)
        }.disabled(busy)
    }
}

// MARK: - Profile create + segment editor

/// Editable fields for one profile time-segment (reused by create + add/edit segment).
struct SegmentFields {
    var startHour: Double = 0            // 0–23; segments start on the hour here
    var basal: Double = 0.8              // U/hr
    var carbRatio: Double = 10           // g/U
    var isf: Double = 40                 // mg/dL per U
    var target: Double = 110             // mg/dL
}

struct ProfileCreateView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var f = SegmentFields()
    @State private var insulinDurationMin: Double = 300
    @State private var busy = false

    var body: some View {
        Form {
            Section("Name") { TextField("Profile name", text: $name) }
            SegmentFieldsEditor(f: $f, showStart: false)
            Section("Insulin duration") {
                Stepper(value: $insulinDurationMin, in: 120...480, step: 15) {
                    Text("\(Int(insulinDurationMin)) min (\(String(format: "%.1f", insulinDurationMin/60)) h)")
                }
            }
            Section {
                HoldToConfirmButton(title: "create profile", systemImage: "person.crop.circle.badge.plus") {
                    busy = true
                    await model.createProfile(name: name, basalRateUnitsPerHour: f.basal, carbRatioGramsPerUnit: f.carbRatio,
                                              isf: Int(f.isf), targetBg: Int(f.target), insulinDurationMinutes: Int(insulinDurationMin))
                    busy = false
                    if model.lastError == nil { dismiss() }
                }.disabled(busy || name.isEmpty)
            } footer: {
                Text("Creates a new profile with one time-segment starting at midnight. Add more segments after. ⚠️ Experimental: some profile parameters use **unverified default values** (idpStatusId, bitmasks) — verify the created profile on the pump. Insulin-affecting — bench-validate on saline. See docs/UNVERIFIED-GUESSES.md.")
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("New Profile")
    }
}

struct ProfileSegmentsView: View {
    @Bindable var model: AppModel
    let idpId: Int
    let profileName: String
    @State private var editing: PumpProfileSegment?    // non-nil = edit sheet
    @State private var adding = false
    @State private var busy = false

    private func hhmm(_ min: Int) -> String { String(format: "%02d:%02d", min / 60, min % 60) }

    var body: some View {
        List {
            Section {
                ForEach(model.snapshot.viewedProfileSegments) { s in
                    Button { editing = s } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hhmm(s.startTimeMinutes)) · \(String(format: "%.2f", s.basalRateUnitsPerHour)) U/hr").fontWeight(.medium)
                            Text("CR \(String(format: "%.0f", s.carbRatioGramsPerUnit)) g/U · ISF \(s.isf) · Target \(s.targetBg)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { run { await model.deleteProfileSegment(idpId: idpId, segmentIndex: s.segmentIndex) } }
                            label: { Label("Delete", systemImage: "trash") }
                    }
                }
                if model.snapshot.viewedProfileSegments.isEmpty { Text("Loading segments…").foregroundStyle(.secondary) }
            } header: { Text("Time segments") } footer: {
                Text("Each segment sets basal, carb ratio, ISF, and target from its start time until the next. ⚠️ Experimental: segment writes use an unverified idpStatusId (0) — verify the result on the pump. Editing the basal schedule is insulin-affecting — bench-validate on saline. See docs/UNVERIFIED-GUESSES.md.")
            }
            if let err = model.lastError { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle(profileName)
        .disabled(busy)
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .task { await model.refreshProfileSegments(idpId: idpId) }
        .sheet(item: $editing) { seg in
            SegmentEditSheet(title: "Edit segment", initial: seg) { f in
                run { await model.modifyProfileSegment(idpId: idpId, segmentIndex: seg.segmentIndex, startTimeMinutes: Int(f.startHour) * 60,
                                                       basalRateUnitsPerHour: f.basal, carbRatioGramsPerUnit: f.carbRatio, isf: Int(f.isf), targetBg: Int(f.target)) }
            }
        }
        .sheet(isPresented: $adding) {
            SegmentEditSheet(title: "Add segment", initial: nil) { f in
                run { await model.addProfileSegment(idpId: idpId, startTimeMinutes: Int(f.startHour) * 60,
                                                    basalRateUnitsPerHour: f.basal, carbRatioGramsPerUnit: f.carbRatio, isf: Int(f.isf), targetBg: Int(f.target)) }
            }
        }
    }

    private func run(_ op: @escaping () async -> Void) { busy = true; Task { await op(); busy = false } }
}

/// Sheet wrapping the segment-fields editor with a hold-to-confirm save (insulin-affecting).
struct SegmentEditSheet: View {
    let title: String
    let initial: PumpProfileSegment?
    let onSave: (SegmentFields) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var f = SegmentFields()

    var body: some View {
        NavigationStack {
            Form {
                SegmentFieldsEditor(f: $f, showStart: true)
                Section {
                    HoldToConfirmButton(title: "save segment", systemImage: "checkmark.circle") {
                        onSave(f); dismiss()
                    }
                }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if let s = initial {
                    f = SegmentFields(startHour: Double(s.startTimeMinutes / 60), basal: s.basalRateUnitsPerHour,
                                      carbRatio: s.carbRatioGramsPerUnit, isf: Double(s.isf), target: Double(s.targetBg))
                }
            }
        }
    }
}

/// The shared set of steppers for a segment's clinical values.
struct SegmentFieldsEditor: View {
    @Binding var f: SegmentFields
    let showStart: Bool
    var body: some View {
        if showStart {
            Section("Start time") {
                Stepper(value: $f.startHour, in: 0...23, step: 1) { Text(String(format: "%02d:00", Int(f.startHour))) }
            }
        }
        Section("Basal rate") { Stepper(value: $f.basal, in: 0...15, step: 0.05) { Text("\(String(format: "%.2f", f.basal)) U/hr") } }
        Section("Carb ratio") { Stepper(value: $f.carbRatio, in: 1...150, step: 1) { Text("\(Int(f.carbRatio)) g/U") } }
        Section("Correction factor (ISF)") { Stepper(value: $f.isf, in: 5...400, step: 1) { Text("\(Int(f.isf)) mg/dL/U") } }
        Section("Target glucose") { Stepper(value: $f.target, in: 70...180, step: 1) { Text("\(Int(f.target)) mg/dL") } }
    }
}
