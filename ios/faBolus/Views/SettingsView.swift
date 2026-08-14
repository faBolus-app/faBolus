import SwiftUI
import faBolusCore

// MARK: - Shared helpers

private func fmtU(_ v: Double) -> String {
    v < 0.1 ? String(format: "%.2f U", v) : (v < 1 ? String(format: "%.1f U", v) : String(format: "%.0f U", v))
}
private func hideDelayLabel(_ opt: Int?) -> String {
    switch opt {
    case .none: return "Never"
    case .some(0): return "Immediately"
    case .some(let n): return "\(n) min after"
    }
}
/// Docs / help site.
let faBolusHelpURL = URL(string: "https://faBolus.org")!

// MARK: - Settings root (categorized + searchable, iOS-Settings style)

/// Settings tab. Grouped into category subscreens (Bolus / Display / CGM / Pump / Remotes & devices /
/// About) instead of one long list, with a search field that jumps to any setting, plus a Help link.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var query = ""
    // P14 S3: injected by RootContainerView (same idiom as AppRouter). Drives Settings → Mode.
    @Environment(ModeStore.self) private var modeStore

    var body: some View {
        NavigationStack {
            SettingsLockGate(settings: settings) { settingsList }
                .navigationTitle("Settings")
        }
    }

    @ViewBuilder private var settingsList: some View {
            List {
                if query.isEmpty {
                    Section {
                        ForEach(SettingsCategory.allCases) { cat in
                            NavigationLink { destination(cat) } label: {
                                Label(cat.title, systemImage: cat.icon)
                            }
                        }
                    }
                    // P14 S3: mode selector. Shows the current mode; opens the unlock/opt-out controls.
                    Section {
                        NavigationLink { ModeSettingsView() } label: {
                            Label("Mode: \(modeStore.activeMode.title)", systemImage: "dial.medium")
                        }
                    } footer: {
                        Text("How much of faBolus is shown — Simple, Standard, or Advanced. Start simple; unlock more as you go.")
                    }
                    Section {
                        Toggle("Read-only mode", isOn: $settings.phoneReadOnly)
                        if settings.phoneReadOnly {
                            Toggle("Still allow clearing alerts", isOn: $settings.readOnlyAllowAlertClear)
                        }
                    } header: { Text("Safety") } footer: {
                        Text("Turns this phone into a **safe viewer**: bolusing and pump control are disabled and their screens hidden — good for a caregiver or backup phone that should only watch pump + CGM data. Clearing pump alerts is off too unless you allow it above. (The Apple Watch / Garmin have their own switch under Remotes & devices.)")
                    }
                    Section {
                        NavigationLink { ChildModeView(settings: settings) } label: {
                            Label(settings.childModeEnabled ? "Child mode (on)" : "Child mode", systemImage: "lock.fill")
                        }
                        NavigationLink { BackupRestoreView(model: model) } label: {
                            Label("Backup & restore", systemImage: "arrow.clockwise.icloud")
                        }
                        NavigationLink { DataHistoryView(model: model) } label: {
                            Label("Data & history", systemImage: "chart.bar.doc.horizontal")
                        }
                        NavigationLink { PrivacyDataView(model: model) } label: {
                            Label("Privacy & data", systemImage: "hand.raised")
                        }
                        #if FABOLUS_NUDGE
                        NavigationLink { SmartAssistSettingsView(settings: settings) } label: {
                            Label(settings.eatingNudgesEnabled
                                  ? "Smart Assist (on)" : "Smart Assist", systemImage: "sparkles")
                        }
                        #else
                        // E6: show a DISABLED row rather than hiding Smart Assist, so a build without the
                        // faBolusNudge SDK still discloses that the feature exists but isn't compiled in
                        // (a hidden section reads as "never existed"). Non-interactive + greyed.
                        Label("Smart Assist — unavailable in this build", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                        #endif
                    } footer: {
                        Text("Child mode locks this device behind a PIN. Backup & restore saves your settings (and optionally pump settings) to a file in your own iCloud/Files — never our servers.")
                    }
                    Section {
                        Link(destination: faBolusHelpURL) {
                            Label("Help & documentation", systemImage: "questionmark.circle")
                        }
                    } footer: {
                        Text("Opens faBolus.org.")
                    }
                } else {
                    let hits = SettingsIndex.entries.filter { $0.matches(query) }
                    if hits.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ForEach(hits) { e in
                            NavigationLink { destination(e.category) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title)
                                    Text(e.category.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
    }

    @ViewBuilder private func destination(_ cat: SettingsCategory) -> some View {
        switch cat {
        case .bolus:   BolusSettingsView(settings: settings)
        case .display: DisplaySettingsView(model: model, settings: settings)
        case .cgm:     CgmSettingsView(model: model, settings: settings)
        case .alerts:  AlertRulesView(settings: settings)
        case .pump:    PumpSettingsView(model: model, settings: settings)
        case .remotes: RemotesSettingsView(model: model, settings: settings)
        case .about:   AboutSettingsView(model: model)
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case bolus, display, cgm, alerts, pump, remotes, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bolus: return "Bolus & entry"
        case .display: return "Display & chart"
        case .cgm: return "CGM & failover"
        case .alerts: return "Alert rules"
        case .pump: return "Pump & control"
        case .remotes: return "Remotes & devices"
        case .about: return "About & help"
        }
    }
    var icon: String {
        switch self {
        case .bolus: return "syringe.fill"
        case .display: return "chart.xyaxis.line"
        case .cgm: return "sensor.tag.radiowaves.forward.fill"
        case .alerts: return "bell.badge.fill"
        case .pump: return "cross.case.fill"
        case .remotes: return "applewatch.radiowaves.left.and.right"
        case .about: return "info.circle"
        }
    }
}

/// Flat index of individual settings so search can jump to the category that holds each one.
enum SettingsIndex {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let keywords: String
        let category: SettingsCategory
        func matches(_ q: String) -> Bool {
            let s = q.lowercased()
            return title.lowercased().contains(s) || keywords.lowercased().contains(s) || category.title.lowercased().contains(s)
        }
    }
    static let entries: [Entry] = [
        .init(title: "Default bolus mode", keywords: "carbs units entry", category: .bolus),
        .init(title: "iPhone increments", keywords: "unit bolus carb step 0.05", category: .bolus),
        .init(title: "Watch & Garmin increments", keywords: "unit bolus carb step remote", category: .bolus),
        .init(title: "Extended bolus & reasoning", keywords: "combo square wave extended duration max safe reasoning iob", category: .bolus),
        .init(title: "Glucose unit", keywords: "mmol mg/dl mg dl unit display convert show unit labels caption", category: .display),
        .init(title: "Chart series (glucose / IOB / bolus)", keywords: "graph axis show hide", category: .display),
        .init(title: "Phone details rows", keywords: "reorder hide fields customize", category: .display),
        .init(title: "Dashboard pills", keywords: "reorder hide pills iob reservoir carb isf target", category: .display),
        .init(title: "Statistics card", keywords: "time in range tir gmi average cv stats a1c", category: .display),
        .init(title: "Watch details rows", keywords: "reorder hide fields customize watch garmin", category: .remotes),
        .init(title: "Watch chart ranges", keywords: "3 6 12 24 hours tap watch", category: .remotes),
        .init(title: "Allow bolusing from Watch & Garmin", keywords: "allow enable remote bolus watch garmin deliver read only view only", category: .remotes),
        .init(title: "Remote bolus size limit", keywords: "ceiling cap max units remote bolus limit dose watch garmin", category: .remotes),
        .init(title: "Failover CGM source", keywords: "dexcom libre nightscout share xdrip", category: .cgm),
        .init(title: "CGM account credentials", keywords: "login libre share nightscout transmitter", category: .cgm),
        .init(title: "Glucose staleness", keywords: "stale hide minutes old reading", category: .cgm),
        .init(title: "Alert auto-rules", keywords: "auto snooze dismiss time of day overnight quiet hours condition", category: .alerts),
        .init(title: "Pump connection", keywords: "connect disconnect pair pairing", category: .pump),
        .init(title: "Advanced control", keywords: "suspend resume temp basal mode cartridge profile", category: .pump),
        .init(title: "Activity & sleep automation", keywords: "exercise sleep mode workout focus shortcuts automation temp rate profile activation", category: .pump),
        .init(title: "Pump backend", keywords: "tandem mock", category: .pump),
        .init(title: "Garmin screen order", keywords: "swipe screens remote", category: .remotes),
        .init(title: "Garmin complication display", keywords: "watch face color trend arrow", category: .remotes),
        .init(title: "Garmin analog clock face", keywords: "analog digital clock face hands watch", category: .remotes),
        .init(title: "Set up Garmin remote", keywords: "connect iq install", category: .remotes),
        .init(title: "Siri phrases", keywords: "voice shortcuts", category: .remotes),
        .init(title: "Help & documentation", keywords: "docs website fabolus.org support", category: .about),
        .init(title: "Debug diagnostics", keywords: "logs developer", category: .about),
    ]
}

// MARK: - Bolus & entry

struct BolusSettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Picker("Phone default mode", selection: $settings.defaultBolusMode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
                Picker("Watch/Garmin default mode", selection: $settings.watchDefaultBolusMode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
            } header: { Text("Bolus entry") } footer: { Text("Default entry mode. **Phone** covers the iPhone and the widget; **Watch/Garmin** is independent, for the Apple Watch and Garmin bolus screens.") }
            Section {
                Picker("Unit increment", selection: $settings.bolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.carbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                }
            } header: { Text("iPhone increments") } footer: { Text("Steps for the iPhone bolus screen and the Home-Screen widget.") }
            Section {
                Picker("Unit increment", selection: $settings.watchBolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.watchCarbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                }
            } header: { Text("Watch & Garmin increments") } footer: { Text("Steps for the Apple Watch and Garmin bolus screens (independent of the iPhone).") }
            Section {
                Toggle("Show recommendation reasoning", isOn: $settings.showBolusReasoning)
                Toggle("Extended (combo) bolus", isOn: $settings.extendedBolusEnabled)
            } header: { Text("Bolus screen") } footer: {
                Text("**Reasoning**: a collapsible breakdown (IOB, carb + correction, an advisory max-safe estimate) under the recommended dose. **Extended bolus**: split a dose into now + over-a-duration. Both off/hidden keep the screen simple.")
            }
        }
        .navigationTitle("Bolus & entry")
    }
}

// MARK: - Display & chart

struct DisplaySettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var showBadgeMmolWarning = false

    /// WR-01/CR-01: enabling the glucose badge while the display unit is mmol requires an explicit
    /// confirm (the badge rounds to a whole number in mmol); enabling in mg/dL, or turning it off, is
    /// always immediate. Routed through the shared `guardedToggle` factory (09.3-01, D-05/SC3) — the one
    /// idiom every confirm-gated settings toggle uses.
    private var glucoseBadgeBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.glucoseBadgeEnabled },
            set: { settings.glucoseBadgeEnabled = $0 },
            skipConfirmIf: { settings.glucoseDisplayUnit != .mmol },
            requestConfirm: { showBadgeMmolWarning = true }
        )
    }
    var body: some View {
        Form {
            Section {
                Picker("Glucose unit", selection: $settings.glucoseDisplayUnit) {
                    Text("mg/dL").tag(GlucoseUnit.mgdl)
                    Text("mmol/L").tag(GlucoseUnit.mmol)
                }
                .pickerStyle(.segmented)
                // Owner request: hides/shows the persistent mg/dL·mmol/L CAPTION on ambient display
                // surfaces only. Default OFF. Dose prompts, VoiceOver, config/setup screens, and this
                // picker are never affected — see `AppSettings.showGlucoseUnitLabels`.
                Toggle("Show unit labels", isOn: $settings.showGlucoseUnitLabels)
            } header: { Text("Glucose unit") } footer: {
                // WR-08 gap closure (04-07): narrowed from "everywhere" — the developer debug menu
                // (reachable via a 7-tap gesture, not mainline UI) intentionally stays mg/dL-only.
                Text("Applies to the glucose reading, correction factor (ISF), and target on every mainline screen where they're shown or entered. The pump and every wire message stay mg/dL internally; only display and entry convert. \"Show unit labels\" shows or hides the mg/dL/mmol/L caption on glucose readouts, widgets, and the chart — dose prompts, VoiceOver, and this picker always show the unit regardless.")
            }
            Section("Chart") {
                Toggle("Show glucose axis", isOn: $settings.showGlucoseAxis)
                Toggle("Show insulin (IOB) line", isOn: $settings.showIOBAxis)
                Toggle("Show bolus bars", isOn: $settings.showBolusBars)
            }
            Section {
                Toggle("Show statistics card", isOn: $settings.showStats)
            } header: { Text("Statistics") } footer: {
                Text("Adds a dashboard card with Time-in-Range, GMI, average, and variability (CV) over the last ~24 hours of readings held in memory. Off by default to keep the dashboard clean.")
            }
            Section {
                NavigationLink {
                    CustomizeListView(title: "Details", allIds: AppSettings.detailFields,
                                      label: AppSettings.detailFieldLabel, order: $settings.detailsOrder,
                                      shownFooter: "Rows shown on the phone Details card. Drag to reorder, swipe to hide.")
                } label: { LabeledContent("Phone details rows", value: "\(settings.detailsOrder.count) shown") }
                NavigationLink {
                    CustomizeListView(title: "Pills", allIds: AppSettings.pillItems,
                                      label: AppSettings.pillLabel, order: $settings.pillsOrder,
                                      shownFooter: "Status pills shown on the dashboard. Drag to reorder, swipe to hide.")
                } label: { LabeledContent("Dashboard pills", value: "\(settings.pillsOrder.count) shown") }
            } header: { Text("Customize") } footer: {
                Text("Choose which detail rows and pills appear on the phone dashboard. (Watch details + chart ranges are under Remotes & devices.)")
            }
            Section {
                Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
                if settings.liveActivityEnabled {
                    NavigationLink {
                        CustomizeListView(title: "Live Activity fields", allIds: AppSettings.laFieldItems,
                                          label: AppSettings.laFieldLabel, order: $settings.liveActivityFields,
                                          shownFooter: "Fields shown on the Lock Screen, Dynamic Island, and CarPlay. Drag to reorder, swipe to hide.")
                    } label: { LabeledContent("Fields shown", value: "\(settings.liveActivityFields.count) shown") }
                }
            } header: { Text("Live Activity") } footer: {
                Text("Shows your glucose (and, optionally, pump status) on the Lock Screen and Dynamic Island. Off by default. faBolus never doses from here — this is a read-only ambient display.")
            }
            // WR-01 gap closure (05-06): the opt-in existed end-to-end (AppSettings.glucoseBadgeEnabled,
            // default OFF, SettingsCatalog descriptor) but had no reachable UI — mirrors the "Live
            // Activity" section above exactly. Copy is the D-14 plain-language caveat verbatim
            // (05-UI-SPEC.md), plus a short note on the mmol rounding CR-01 introduced.
            Section {
                Toggle("Glucose badge", isOn: glucoseBadgeBinding)
            } header: { Text("Glucose badge") } footer: {
                Text("Shows your current glucose number on the app icon. It can't show units, trend, or how old the reading is — it clears automatically whenever the reading goes stale, so it should never show an old number as current. In mmol/L, the badge rounds to the nearest whole number.")
            }
            .confirmationDialog("Glucose badge rounds in mmol/L", isPresented: $showBadgeMmolWarning,
                                 titleVisibility: .visible) {
                Button("Enable") { settings.glucoseBadgeEnabled = true }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The app-icon badge can only show a whole number, so in mmol/L your glucose will be shown ROUNDED to the nearest whole number (e.g. 5.5 shows as 6).")
            }
        }
        .navigationTitle("Display & chart")
    }
}

// MARK: - CGM & failover

struct CgmSettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var selectedGlucoseSource = GlucoseSourceRegistry.selectedId() ?? ""
    @State private var showExperimentalCgmWarning = false
    /// FB-07: an experimental source is NOT committed to the registry until the user accepts the warning.
    /// `pendingExperimentalId` holds the not-yet-committed choice; `lastCommittedSource` is what we roll
    /// the picker back to on Cancel; `isReverting` suppresses the re-entrant onChange from that rollback.
    @State private var pendingExperimentalId: String?
    @State private var lastCommittedSource = GlucoseSourceRegistry.selectedId() ?? ""
    @State private var isReverting = false
    /// Failover sources whose direct-BLE path is an unverified best guess (docs/UNVERIFIED-GUESSES.md #5):
    /// selecting one raises a blocking warning that it will likely not connect.
    private static let experimentalCgmSourceIds: Set<String> = ["dexcom-g6-ble"]
    var body: some View {
        Form {
            Section {
                // 09.3-03 (D-05/SC3): intentional, documented exception to the unified Bool guardedToggle
                // idiom — this picker is String/GlucoseSourceRegistry-backed, not an AppSettings Bool, so
                // guardedToggle cannot type-check it (09.3-RESEARCH.md Open Question 1, Pitfall 3). Its
                // own pending/lastCommitted/isReverting confirm-and-rollback shape below is left as-is.
                Picker("Failover CGM", selection: $selectedGlucoseSource) {
                    Text("None (pump only)").tag("")
                    ForEach(GlucoseSourceRegistry.enabled) { Text($0.name).tag($0.id) }
                }
                .onChange(of: selectedGlucoseSource) { _, id in
                    if isReverting { isReverting = false; return }   // programmatic rollback, don't re-handle
                    if Self.experimentalCgmSourceIds.contains(id) {
                        // FB-07: defer the commit until the warning is accepted; roll back on Cancel.
                        pendingExperimentalId = id
                        showExperimentalCgmWarning = true
                    } else {
                        GlucoseSourceRegistry.select(id.isEmpty ? nil : id)
                        lastCommittedSource = id
                    }
                }
                NavigationLink("CGM credentials & testing") { CgmCredentialsView(model: model) }
            } header: { Text("Glucose failover") } footer: {
                Text("An independent CGM feed used when the pump's glucose goes stale (pump, phone, or sensor link dropped). Old readings are shown marked, never as current. Takes effect after you reopen the app.")
            }
            .alert("Untested source", isPresented: $showExperimentalCgmWarning) {
                Button("Use it anyway", role: .destructive) {
                    if let id = pendingExperimentalId {
                        GlucoseSourceRegistry.select(id)   // commit only now
                        lastCommittedSource = id
                    }
                    pendingExperimentalId = nil
                }
                Button("Cancel", role: .cancel) {
                    // Nothing was committed; roll the picker back to the last accepted source.
                    pendingExperimentalId = nil
                    isReverting = true
                    selectedGlucoseSource = lastCommittedSource
                }
            } message: {
                Text("⚠️ The direct-BLE Dexcom source is experimental and has NOT been verified — a passive read likely will NOT connect (the sensor needs an authenticated session). Prefer Dexcom Share or the xDrip App Group. See docs/operate/cgm-failover.md.")
            }
            Section {
                Toggle("Upload to Nightscout", isOn: $settings.nightscoutUploadEnabled)
            } header: { Text("Nightscout upload") } footer: {
                Text("Pushes glucose, boluses, and pump status (IOB / reservoir / battery) to your Nightscout site. **Off by default — this sends your health data off-device.** Set the site URL, token, and (optional) API secret under **CGM credentials & testing**.")
            }
            Section {
                Picker("Mark stale after", selection: $settings.glucoseStaleMinutes) {
                    ForEach(AppSettings.glucoseStaleOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Hide (\u{2013}\u{2013})", selection: $settings.glucoseHideDelayMinutes) {
                    ForEach(AppSettings.glucoseHideDelayOptions, id: \.self) { opt in Text(hideDelayLabel(opt)).tag(opt) }
                }
            } header: { Text("Glucose staleness") } footer: {
                Text("**Mark stale**: after this long, a reading is greyed and no longer auto-fills a correction. **Hide**: how long after that to keep showing the greyed value before it becomes “–”.")
            }
        }
        .navigationTitle("CGM & failover")
    }
}

// MARK: - Pump & control

struct PumpSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @State private var showPairing = false
    @State private var selectedBackend = BackendRegistry.selected().id
    // P14 S12 (§2.2.3): the unpair flow. `repairAfter` re-opens pairing after unpair (the "Re-pair with
    // new code" path). One funnel for both unpair entry points. A4 (owner 2026-08-09): the flow is now
    // TWO steps — step 1 offers a settings backup (or explicit skip), step 2 is the model-appropriate
    // confirm — so an unpair can't complete without a backup-or-skip choice first (UnpairAdvisory.steps).
    @State private var unpairStep: UnpairStep?
    private enum UnpairStep: Identifiable {
        case backup(repairAfter: Bool)    // step 1: back up or skip
        case confirm(repairAfter: Bool)   // step 2: S12 charging-base confirm
        var id: String { switch self { case .backup(let r): return "backup-\(r)"; case .confirm(let r): return "confirm-\(r)" } }
        var repairAfter: Bool { switch self { case .backup(let r), .confirm(let r): return r } }
    }
    @State private var showBackupSheet = false
    @State private var repairAfterBackup = false
    var body: some View {
        Form {
            Section("Pump") {
                LabeledContent("Status", value: model.snapshot.connection.rawValue)
                connectionControls
                if model.hasStoredPairing && model.capabilities.supportsPairing {
                    // P14 S12 (§2.2.3): confirm before an unpair; a Mobi gets the unconditional
                    // charging-base warning (re-pairing needs the base). A4: step 1 is the backup gate.
                    Button("Forget pairing", role: .destructive) { unpairStep = .backup(repairAfter: false) }
                }
            }
            // Pump clock sync isn't advanced control, so it's its own section — no need to enable
            // advanced control. Only shown on pumps that honor the time write (Mobi; t:slim X2 rejects it).
            if model.capabilities.supportsTimeSync {
                Section {
                    Toggle("Keep pump clock synced to phone", isOn: $settings.autoSyncPumpTime)
                    Button {
                        Task { await model.syncTimeToNow() }
                    } label: { Label("Sync pump time now", systemImage: "clock.arrow.2.circlepath") }
                        .disabled(model.snapshot.connection != .connected)
                } header: { Text("Pump clock") } footer: {
                    Text("Sets the pump's clock to this phone — automatically at most once a day while connected, and immediately when your phone's time or time zone changes (travel / DST).")
                }
            }
            // Advanced control needs a pump that advertises it (Mobi-only in practice), so the whole
            // section is hidden unless the pump has an advanced capability (or it's already enabled, so
            // it can still be turned off). P13: keyed on the pump-derived capability set, not `isMobi`.
            if model.capabilities.supportsAnyAdvancedControl || settings.advancedControlEnabled {
                Section {
                    Toggle("Advanced control", isOn: $settings.advancedControlEnabled)
                    if settings.advancedControlEnabled {
                        if model.advancedControlAllowed {
                            NavigationLink { PumpControlView(model: model) } label: {
                                Label("Pump Control", systemImage: "slider.horizontal.3")
                            }
                        } else {
                            // P13c: user-facing BRAND copy, now keyed on the typed `PumpModel` identity
                            // (not a raw `isMobi` read) — a model-identity fact, not a capability gate.
                            Text(model.snapshot.pumpModel == .mobi ? "Connect to a Mobi to enable pump control."
                                 : "Advanced control requires a Tandem Mobi pump.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Advanced control") } footer: {
                    Text("Suspend/resume, temp basal, modes, cartridge & fill, CGM session, profiles, limits, and reminders. Mobi only, off by default. Insulin-affecting actions ask for confirmation.")
                }
            }
            Section {
                Toggle("Allow auto Exercise mode", isOn: $settings.autoExerciseMode)
                Toggle("Allow auto Sleep mode", isOn: $settings.autoSleepMode)
                Toggle("Allow auto temp rate", isOn: $settings.autoTempRate)
                Toggle("Allow auto profile activation", isOn: $settings.autoProfileActivation)
                Toggle("Remind me when it can't switch", isOn: $settings.modeReminders)
                NavigationLink { ModeAutomationHelpView() } label: {
                    Label("Set up the Shortcuts automation", systemImage: "wand.and.stars")
                }
            } header: { Text("Activity & sleep automation") } footer: {
                Text("**Two steps are required — the switch alone does nothing.** (1) Turn a switch on above: that only *permits* faBolus to change the mode. (2) Create the one-time Apple **Shortcuts automation** that actually triggers it (tap **Set up the Shortcuts automation**) — iOS won't let faBolus create it for you. Once both are in place, the pump switches to **Exercise** when a workout starts and **Sleep** when your iPhone enters Sleep Focus. **Mobi-only** (needs Advanced control); a t:slim can't be switched — turn on reminders to be nudged to do it yourself. All off by default.")
            }
            if BackendRegistry.enabled.count > 1 {
                Section {
                    Picker("Pump backend", selection: $selectedBackend) {
                        ForEach(BackendRegistry.enabled) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: selectedBackend) { _, id in BackendRegistry.select(id) }
                } header: { Text("Backend") } footer: { Text("Which pump this build talks to. Takes effect after you reopen the app.") }
            }
        }
        .navigationTitle("Pump & control")
        .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
        // A4 (§2.2.3, owner 2026-08-09): STEP 1 — the backup gate. Before the unpair confirm, offer a
        // settings backup or an explicit skip (never a default), so an unpair can't complete without that
        // choice. "Back up settings" opens the Backup & restore sheet; whichever way that sheet is
        // dismissed, the flow advances to step 2 (the user was given the chance to back up).
        .confirmationDialog(UnpairAdvisory.backupPromptTitle,
                            isPresented: Binding(get: { if case .backup = unpairStep { return true } else { return false } },
                                                 set: { if !$0, case .backup = unpairStep { unpairStep = nil } }),
                            titleVisibility: .visible) {
            if case .backup(let repair) = unpairStep {
                Button(UnpairAdvisory.backUpNowLabel) {
                    repairAfterBackup = repair
                    unpairStep = nil
                    showBackupSheet = true
                }
                Button(UnpairAdvisory.skipBackupLabel, role: .destructive) {
                    unpairStep = .confirm(repairAfter: repair)   // explicit skip → straight to the confirm
                }
                Button("Cancel", role: .cancel) { unpairStep = nil }
            }
        } message: {
            Text(UnpairAdvisory.backupPromptMessage)
        }
        // The backup sheet; on dismiss (saved or not) advance to the model-appropriate confirm.
        .sheet(isPresented: $showBackupSheet, onDismiss: { unpairStep = .confirm(repairAfter: repairAfterBackup) }) {
            NavigationStack { BackupRestoreView(model: model) }
        }
        // P14 S12 (§2.2.3): STEP 2 — the unpair confirm, carrying the model-appropriate warning
        // (Mobi ⇒ charging-base caveat). One funnel for both entry points. Presented as a
        // confirmationDialog (09.3-03, D-05/SC3) to match step 1's presentation above.
        .confirmationDialog("Forget pairing?",
               isPresented: Binding(get: { if case .confirm = unpairStep { return true } else { return false } },
                                    set: { if !$0, case .confirm = unpairStep { unpairStep = nil } }),
               titleVisibility: .visible) {
            Button("Forget pairing", role: .destructive) {
                let repair = unpairStep?.repairAfter ?? false
                unpairStep = nil
                model.forgetPairing()
                if repair { showPairing = true }
            }
            Button("Cancel", role: .cancel) { unpairStep = nil }
        } message: {
            Text(model.unpairConfirmation)
        }
    }

    @ViewBuilder private var connectionControls: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            if !model.capabilities.supportsPairing {
                Button("Connect") { Task { await model.connect() } }
            } else if model.hasStoredPairing {
                Button("Connect (saved pairing)") { Task { await model.connect() } }
                Button("Re-pair with new code") { unpairStep = .backup(repairAfter: true) }
            } else {
                Button("Connect") { showPairing = true }
            }
        case .connected, .bolusing:
            Button("Disconnect", role: .destructive) { model.disconnect() }
        default:
            HStack { Text("Connecting…").foregroundStyle(.secondary); Spacer(); ProgressView() }
        }
    }
}

// MARK: - Remotes & devices

struct RemotesSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @Environment(AppRouter.self) private var router
    // §2.3 (G5): the one-time warning shown the FIRST time each surface's bolusing is enabled.
    @State private var showWatchBolusWarning = false
    @State private var showGarminBolusWarning = false
    // C2 §2.3: the OPTIONAL Garmin bolus passcode set-UI. `passcodeSet` mirrors the Keychain-backed
    // `BolusPasscodeStore.isRequired` (refreshed on appear + after every set/clear) so the section shows
    // the right state without making the store observable.
    @State private var showSetPasscode = false
    @State private var passcodeSet = false
    static let siriPhrases = [
        "What's my glucose in faBolus", "Insulin on board in faBolus", "Pump status in faBolus",
        "Any alerts in faBolus", "Last bolus in faBolus",
    ]

    /// §2.3: turning an enable ON routes through the one-time warning on first use (Confirm arms it +
    /// records the ack; Cancel leaves it off — the binding's `get` reads the real, still-false flag so the
    /// switch snaps back). A subsequent turn-on (already acknowledged, or after turning it off) arms
    /// directly. Turning OFF is always immediate. Routed through the shared `guardedToggle` factory
    /// (09.3-01, D-05/SC3) — the one idiom every confirm-gated settings toggle uses.
    private var watchBolusBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.watchBolusEnabled },
            set: { settings.watchBolusEnabled = $0 },
            skipConfirmIf: { settings.hasAcknowledgedWatchBolusWarning },
            requestConfirm: { showWatchBolusWarning = true }
        )
    }
    private var garminBolusBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.garminBolusEnabled },
            set: { settings.garminBolusEnabled = $0 },
            skipConfirmIf: { settings.hasAcknowledgedGarminBolusWarning },
            requestConfirm: { showGarminBolusWarning = true }
        )
    }
    /// §2.3: the optional remote-only dose ceiling. The toggle arms it at the default cap; the picker edits
    /// the value. `nil` (off) ⇒ the pump's max alone governs remote boluses.
    private var remoteCeilingOn: Binding<Bool> {
        Binding(get: { settings.remoteBolusCeiling != nil },
                set: { on in settings.remoteBolusCeiling = on ? (settings.remoteBolusCeiling ?? AppSettings.defaultRemoteBolusCeiling) : nil })
    }
    private var remoteCeilingValue: Binding<Double> {
        Binding(get: { settings.remoteBolusCeiling ?? AppSettings.defaultRemoteBolusCeiling },
                set: { settings.remoteBolusCeiling = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow bolusing from Apple Watch", isOn: watchBolusBinding)
                Toggle("Allow bolusing from Garmin", isOn: garminBolusBinding)
                if settings.watchBolusEnabled || settings.garminBolusEnabled {
                    Toggle("Limit remote bolus size", isOn: remoteCeilingOn)
                    if settings.remoteBolusCeiling != nil {
                        Picker("Max per remote bolus", selection: remoteCeilingValue) {
                            ForEach(AppSettings.remoteBolusCeilingOptions, id: \.self) { Text(fmtU($0)).tag($0) }
                        }
                    }
                }
                Toggle("Read-only (view only)", isOn: $settings.remotesReadOnly)
            } header: { Text("Watch & Garmin bolusing") } footer: {
                Text("**Bolusing from the Apple Watch and Garmin is off by default.** Turn on a switch above to let that device deliver a bolus — you'll confirm a one-time warning the first time. **Limit remote bolus size** optionally caps how many units a single Watch/Garmin bolus can be, on top of your pump's max bolus; the iPhone is never affected. **Read-only** overrides everything: while on, the Watch and Garmin show pump + CGM data only and can't deliver, whatever the switches above say. The iPhone is always unaffected — this is separate from the phone's own read-only mode.")
            }
            // C2 §2.3: the OPTIONAL Garmin bolus passcode. Gates GARMIN delivery only (Apple Watch is exempt
            // — wrist detection). Shown when Garmin bolusing is enabled; the code is verified on the phone.
            if settings.garminBolusEnabled {
                Section {
                    if passcodeSet {
                        Label("A passcode is required to bolus from Garmin", systemImage: "lock.fill")
                            .foregroundStyle(.indigo)
                        Button("Change passcode") { showSetPasscode = true }
                        Button("Remove passcode", role: .destructive) {
                            BolusPasscodeStore.setPasscode(nil); passcodeSet = BolusPasscodeStore.isRequired
                        }
                    } else {
                        Button { showSetPasscode = true } label: {
                            Label("Require a passcode to bolus from Garmin", systemImage: "lock")
                        }
                    }
                } header: { Text("Garmin bolus passcode") } footer: {
                    Text("Optional. When set, delivering a bolus from your Garmin watch asks for this **4-digit passcode instead of** the tap-to-confirm — a stronger check for a watch with no wrist detection. The code is verified on this phone (stored only as a salted hash); the watch never stores it. Wrong entries slow down with a soft lockout that resets itself — never a permanent lock. You can change or remove it here anytime. The Apple Watch doesn't use a passcode: its wrist detection already confirms you're wearing it.")
                }
            }
            #if GARMIN
            Section {
                Button { model.setupGarmin?() } label: {
                    Label("Set up Garmin remote", systemImage: "applewatch.radiowaves.left.and.right")
                }
                NavigationLink {
                    GarminScreensView(settings: settings)
                } label: {
                    LabeledContent("Screen order",
                                   value: AppSettings.garminScreenLabel(settings.garminDefaultScreen).components(separatedBy: " (").first ?? settings.garminDefaultScreen)
                }
                Picker("Complication display", selection: $settings.garminComplicationDisplay) {
                    ForEach(AppSettings.complicationDisplayOptions, id: \.self) { Text(AppSettings.complicationDisplayLabel($0)).tag($0) }
                }
                Toggle("Analog clock face", isOn: $settings.garminClockAnalog)
            } header: { Text("Garmin remote") } footer: {
                Text("Reorder the Garmin app's swipe screens, and choose how the watch-face BG complication looks. Applied on the watch's next update. ⚠️ If the complication doesn't show correctly, switch the display mode — the color path uses a complication field that's unverified on-device (see docs/UNVERIFIED-GUESSES.md).")
            }
            #else
            Section {
                Label("Garmin remote unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } header: { Text("Garmin remote") } footer: {
                Text("This build was compiled **without the Garmin Connect IQ SDK**, so the Garmin remote can't be enabled. To use a Garmin watch, install the Connect IQ SDK and rebuild (see the README / scripts/generate-project.sh).")
            }
            #endif
            #if !WATCH_EMBEDDED
            Section {
                Label("Apple Watch app not included", systemImage: "applewatch.slash")
                    .foregroundStyle(.secondary)
            } header: { Text("Apple Watch") } footer: {
                Text("This build was compiled without the Apple Watch app (FABOLUS_WATCH=0), so nothing installs to a paired watch. Rebuild with the watch enabled (the default) to use it — see scripts/generate-project.sh.")
            }
            #endif
            Section {
                Picker("Default mode", selection: $settings.watchDefaultBolusMode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
                Picker("Unit increment", selection: $settings.watchBolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.watchCarbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                }
            } header: { Text("Watch/Garmin bolus") } footer: {
                Text("Default entry mode and increments for the Apple Watch and Garmin bolus screens (independent of the iPhone). Same settings as under Bolus & entry.")
            }
            Section {
                NavigationLink {
                    CustomizeListView(title: "Watch details", allIds: AppSettings.detailFields,
                                      label: AppSettings.detailFieldLabel, order: $settings.watchDetailsOrder,
                                      shownFooter: "Rows shown on the watch/Garmin Details page (independent of the phone). Drag to reorder, swipe to hide.")
                } label: { LabeledContent("Watch details rows", value: "\(settings.watchDetailsOrder.count) shown") }
                NavigationLink { WatchChartRangesView(settings: settings) } label: {
                    LabeledContent("Watch chart ranges", value: settings.watchChartRanges.map { "\($0)h" }.joined(separator: " "))
                }
            } header: { Text("Watch display") } footer: {
                Text("Customize the watch/Garmin Details page and the history-chart tap ranges — separate from the phone. Mirrored to the remotes on the next update.")
            }
            if let g = model.garminStatus {
                Section { Text(g).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Allow remote devices (Bluetooth)", isOn: $settings.remoteBluetoothEnabled)
            } header: { Text("Remote access") } footer: {
                Text("Lets a paired **Mac** or **parent iPhone** connect over Bluetooth to view status and (with permission) deliver boluses — even when this phone is locked. Each device's permissions (view-only vs. control) are set when you pair it and editable under **Pair a remote → the device**. Pairing is authenticated and end-to-end encrypted, **but turning this on makes the phone advertise a connectable Bluetooth service, a small added attack surface. Leave it off unless you use a remote.** (Your Apple Watch and Garmin are unaffected.)")
            }
            Section {
                if settings.remoteBluetoothEnabled {
                    NavigationLink { MacPairingView() } label: {
                        Label("Pair a remote (Mac or iPhone)", systemImage: "laptopcomputer")
                    }
                } else {
                    Label("Turn on “Allow remote devices” above to pair", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Enable remote access") { settings.remoteBluetoothEnabled = true }
                }
            } header: { Text("Remotes") } footer: {
                Text("Pair the faBolus Mac app or a parent's iPhone to view status and send boluses. First-time pairing needs a one-time code or QR scan; the host grants each remote its own permissions.")
            }
            Section {
                ForEach(RemotesSettingsView.siriPhrases, id: \.self) { p in
                    Label("“\(p)”", systemImage: "mic.fill").font(.callout)
                }
            } header: { Text("Siri (read-only)") } footer: {
                Text("These work automatically — no setup needed. Say “Hey Siri” then a phrase, or add them in the Shortcuts app. Siri never delivers a bolus.")
            }
            // Switch the whole app between controlling this phone's pump and acting as a remote for
            // another phone. Kept at the bottom since it's a mode change, not a per-remote setting.
            ControllingSection()
        }
        .navigationTitle("Remotes & devices")
        // C2 §2.3: keep the passcode section's state in sync with the Keychain-backed store.
        .onAppear { passcodeSet = BolusPasscodeStore.isRequired }
        .sheet(isPresented: $showSetPasscode) {
            BolusPasscodeEntryView { code in
                BolusPasscodeStore.setPasscode(code)
                passcodeSet = BolusPasscodeStore.isRequired
            }
        }
        // §2.3: one-time warnings. Confirm arms the enable + records the ack; Cancel leaves it off. The
        // Apple Watch copy notes that wrist detection makes an accidental tap materially less likely than
        // on Garmin, but the enable is still explicit and off by default.
        .confirmationDialog("Allow bolusing from Apple Watch?", isPresented: $showWatchBolusWarning,
                             titleVisibility: .visible) {
            Button("Allow bolusing") { settings.acknowledgeWatchBolusWarning(); settings.watchBolusEnabled = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This lets you deliver real insulin from your Apple Watch, right from your wrist. The Watch's wrist detection makes an accidental tap materially less likely than on Garmin, but you're still turning on insulin delivery — it stays off until you allow it here, and every bolus still needs your confirmation on the Watch. You can turn this off any time.")
        }
        .confirmationDialog("Allow bolusing from Garmin?", isPresented: $showGarminBolusWarning,
                             titleVisibility: .visible) {
            Button("Allow bolusing") { settings.acknowledgeGarminBolusWarning(); settings.garminBolusEnabled = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This lets you deliver real insulin from your Garmin watch. A Garmin has no wrist detection, so take extra care that a bolus is never started by an accidental button press — it stays off until you allow it here, and every bolus still needs your confirmation on the watch. You can turn this off any time.")
        }
    }
}

/// C2 §2.3 — set (or change) the OPTIONAL 4-digit Garmin bolus passcode. Enters it twice to confirm and
/// stores it via `BolusPasscodeStore` (salted SHA-256 in the Keychain; the raw code is never persisted).
/// Modeled on `PinEntryView`'s `.set` mode but fixed at exactly 4 digits (`BolusPasscodeStore.isValidFormat`),
/// with its own store so the bolus passcode and the child-mode PIN stay fully independent.
struct BolusPasscodeEntryView: View {
    /// The validated 4-digit code to store.
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("4-digit passcode", text: $pin)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    SecureField("Confirm passcode", text: $confirm)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                    else { Text("Choose a 4-digit passcode. You'll enter it on your Garmin watch to confirm a bolus. It's stored only as a salted hash on this phone — never sent to the watch.") }
                }
            }
            .navigationTitle("Garmin bolus passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { submit() } }
            }
        }
    }

    private func submit() {
        let digits = pin.filter(\.isNumber)
        guard BolusPasscodeStore.isValidFormat(digits) else { error = "Use exactly 4 digits."; return }
        guard pin == confirm else { error = "Passcodes don't match."; return }
        onSet(digits); dismiss()
    }
}

// MARK: - About & help

struct AboutSettingsView: View {
    @Bindable var model: AppModel
    @State private var debugTaps = 0
    @State private var showDebug = false
    var body: some View {
        Form {
            Section {
                Link(destination: faBolusHelpURL) { Label("Help & documentation", systemImage: "questionmark.circle") }
            } footer: { Text("Opens faBolus.org.") }
            Section {
                if let g = model.garminStatus { Text(g).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text(RegulatoryCopy.about)
                    .contentShape(Rectangle())
                    .onTapGesture { debugTaps += 1; if debugTaps >= 7 { showDebug = true } }
            }
            if showDebug {
                Section {
                    NavigationLink { DebugMenuView(model: model) } label: {
                        Label("Debug diagnostics", systemImage: "ladybug.fill")
                    }
                } footer: { Text("Read-only diagnostics.") }
            }
        }
        .navigationTitle("About & help")
    }
}

// MARK: - Reorder/customize sub-editors (unchanged)

/// Choose which Garmin screens appear, their swipe order, and which opens first. Toggle screens
/// on/off, drag to reorder (Edit), and pick the default. Pushed to the watch on its next status update.
struct GarminScreensView: View {
    @Bindable var settings: AppSettings

    private var hidden: [String] {
        AppSettings.garminScreens.filter { !settings.garminScreenOrder.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Opens first", selection: $settings.garminDefaultScreen) {
                    ForEach(settings.garminScreenOrder, id: \.self) { id in
                        Text(AppSettings.garminScreenLabel(id)).tag(id)
                    }
                }
            } footer: {
                Text("The screen shown when the Garmin app launches (from the shown screens).")
            }

            Section {
                ForEach(settings.garminScreenOrder, id: \.self) { id in
                    Label(AppSettings.garminScreenLabel(id),
                          systemImage: id == settings.garminDefaultScreen ? "star.fill" : "line.3.horizontal")
                        .foregroundStyle(id == settings.garminDefaultScreen ? Color.accentColor : .primary)
                }
                .onMove { from, to in
                    settings.garminScreenOrder.move(fromOffsets: from, toOffset: to)
                }
                .onDelete { idx in hideScreens(idx) }
            } header: {
                Text("Shown on watch (top → bottom)")
            } footer: {
                Text("Swiping up on the watch moves down this list. Swipe a row left to hide it — at least one screen must stay shown.")
            }

            if !hidden.isEmpty {
                Section {
                    ForEach(hidden, id: \.self) { id in
                        Button {
                            settings.garminScreenOrder = settings.garminScreenOrder + [id]
                        } label: {
                            Label(AppSettings.garminScreenLabel(id), systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Hidden")
                } footer: {
                    Text("Tap to show a screen on the watch.")
                }
            }
        }
        .navigationTitle("Garmin Screens")
        .toolbar { EditButton() }
    }

    private func hideScreens(_ idx: IndexSet) {
        guard settings.garminScreenOrder.count - idx.count >= 1 else { return }
        var order = settings.garminScreenOrder
        order.remove(atOffsets: idx)
        settings.garminScreenOrder = order
        if !order.contains(settings.garminDefaultScreen) {
            settings.garminDefaultScreen = order.first ?? "glance"
        }
    }
}

/// Generic reorder/hide editor for a list of field ids (Details rows, dashboard Pills). Mirrors
/// `GarminScreensView`: drag to reorder, swipe to hide, tap to add back. At least one stays shown.
struct CustomizeListView: View {
    let title: String
    let allIds: [String]
    let label: (String) -> String
    @Binding var order: [String]
    let shownFooter: String

    private var hidden: [String] { allIds.filter { !order.contains($0) } }

    var body: some View {
        Form {
            Section {
                ForEach(order, id: \.self) { id in
                    Label(label(id), systemImage: "line.3.horizontal")
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
                .onDelete { idx in if order.count - idx.count >= 1 { order.remove(atOffsets: idx) } }
            } header: {
                Text("Shown (top → bottom)")
            } footer: {
                Text(shownFooter)
            }
            if !hidden.isEmpty {
                Section("Hidden") {
                    ForEach(hidden, id: \.self) { id in
                        Button { order.append(id) } label: {
                            Label(label(id), systemImage: "plus.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Customize \(title)")
        .toolbar { EditButton() }
    }
}

/// Pick which time ranges the watch history chart cycles through on tap (3/6/12/24 h). At least one
/// stays enabled. Mirrored to the watch on its next status update.
struct WatchChartRangesView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(AppSettings.chartRangeOptions, id: \.self) { h in
                    Toggle("\(h) hours", isOn: Binding(
                        get: { settings.watchChartRanges.contains(h) },
                        set: { on in
                            var r = Set(settings.watchChartRanges)
                            if on { r.insert(h) } else if r.count > 1 { r.remove(h) }
                            settings.watchChartRanges = r.sorted()
                        }))
                }
            } footer: {
                Text("Tapping the watch history chart cycles through the enabled ranges. At least one must stay enabled.")
            }
        }
        .navigationTitle("Watch Chart Ranges")
    }
}
