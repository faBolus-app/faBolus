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

/// Settings tab. Grouped into category subscreens (Bolus / Display / CGM / Pump / Watch & Garmin /
/// About) instead of one long list, with a search field that jumps to any setting, plus a Help link.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
    @State private var query = ""

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
                    Section {
                        NavigationLink { ChildModeView(settings: settings) } label: {
                            Label(settings.childModeEnabled ? "Child mode (on)" : "Child mode", systemImage: "lock.fill")
                        }
                    } footer: {
                        Text("Lock this device for a child: block boluses/settings behind a PIN.")
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
        case .remotes: return "Watch & Garmin"
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
        .init(title: "iPhone increments", keywords: "bolus carb step 0.05", category: .bolus),
        .init(title: "Watch & Garmin increments", keywords: "bolus carb step remote", category: .bolus),
        .init(title: "Missed-bolus nudge", keywords: "unannounced meal reminder rising nudge", category: .bolus),
        .init(title: "Extended bolus & reasoning", keywords: "combo square wave extended duration max safe reasoning iob", category: .bolus),
        .init(title: "Chart series (glucose / IOB / bolus)", keywords: "graph axis show hide", category: .display),
        .init(title: "Phone details rows", keywords: "reorder hide fields customize", category: .display),
        .init(title: "Dashboard pills", keywords: "reorder hide pills iob reservoir carb isf target", category: .display),
        .init(title: "Statistics card", keywords: "time in range tir gmi average cv stats a1c", category: .display),
        .init(title: "Simulated CGM (testing)", keywords: "test failover fake simulator cgm", category: .cgm),
        .init(title: "Watch details rows", keywords: "reorder hide fields customize watch garmin", category: .remotes),
        .init(title: "Watch chart ranges", keywords: "3 6 12 24 hours tap watch", category: .remotes),
        .init(title: "Failover CGM source", keywords: "dexcom libre nightscout share xdrip", category: .cgm),
        .init(title: "CGM account credentials", keywords: "login libre share nightscout transmitter", category: .cgm),
        .init(title: "Glucose staleness", keywords: "stale hide minutes old reading", category: .cgm),
        .init(title: "Alert auto-rules", keywords: "auto snooze dismiss time of day overnight quiet hours condition", category: .alerts),
        .init(title: "Pump connection", keywords: "connect disconnect pair pairing", category: .pump),
        .init(title: "Advanced control", keywords: "suspend resume temp basal mode cartridge profile", category: .pump),
        .init(title: "Pump backend", keywords: "tandem mock", category: .pump),
        .init(title: "Garmin screen order", keywords: "swipe screens remote", category: .remotes),
        .init(title: "Garmin complication display", keywords: "watch face color trend arrow", category: .remotes),
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
                Picker("Default mode", selection: $settings.defaultBolusMode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
            } header: { Text("Bolus entry") } footer: { Text("Default entry mode for the iPhone, the widget, and the remotes.") }
            Section {
                Picker("Bolus increment", selection: $settings.bolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.carbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                }
            } header: { Text("iPhone increments") } footer: { Text("Steps for the iPhone bolus screen and the Home-Screen widget.") }
            Section {
                Picker("Bolus increment", selection: $settings.watchBolusIncrement) {
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
            Section {
                Toggle("Missed-bolus nudge", isOn: $settings.missedBolusNudgeEnabled)
                if settings.missedBolusNudgeEnabled {
                    Stepper("When above \(settings.missedBolusNudgeMgdl) mg/dL", value: $settings.missedBolusNudgeMgdl, in: 120...300, step: 10)
                }
            } header: { Text("Reminders") } footer: {
                Text("Off by default. When on, shows a local reminder if glucose is climbing above this level with little insulin on board and no recent bolus — a possible unannounced meal. Advisory only; it never doses, and only fires while the app is running or woken by the pump.")
            }
        }
        .navigationTitle("Bolus & entry")
    }
}

// MARK: - Display & chart

struct DisplaySettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
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
                Text("Choose which detail rows and pills appear on the phone dashboard. (Watch details + chart ranges are under Watch & Garmin.)")
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
    var body: some View {
        Form {
            Section {
                Picker("Failover CGM", selection: $selectedGlucoseSource) {
                    Text("None (pump only)").tag("")
                    ForEach(GlucoseSourceRegistry.enabled) { Text($0.name).tag($0.id) }
                    if settings.simulatedCgmEnabled {
                        ForEach(GlucoseSourceRegistry.testing) { Text($0.name).tag($0.id) }
                    }
                }
                .onChange(of: selectedGlucoseSource) { _, id in GlucoseSourceRegistry.select(id.isEmpty ? nil : id) }
                NavigationLink("CGM account credentials") { CgmCredentialsView(model: model) }
            } header: { Text("Glucose failover") } footer: {
                Text("An independent CGM feed used when the pump's glucose goes stale (pump, phone, or sensor link dropped). Old readings are shown marked, never as current. Takes effect after you reopen the app.")
            }
            Section {
                Toggle("Simulated CGM (testing)", isOn: $settings.simulatedCgmEnabled)
                    .onChange(of: settings.simulatedCgmEnabled) { _, on in
                        // Turning it off while it's the active source clears the selection so fake
                        // data can't linger as the failover feed.
                        if !on, selectedGlucoseSource == "simulated" {
                            selectedGlucoseSource = ""
                            GlucoseSourceRegistry.select(nil)
                        }
                    }
            } header: { Text("Testing") } footer: {
                Text("Adds a **Simulated CGM** option above that emits fake glucose (a smooth sweep through low/in-range/high) so you can test the failover badge, chart, and staleness without a real sensor or a cloud login. **Never leave this selected in real use — the readings are not real.**")
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
    var body: some View {
        Form {
            Section("Pump") {
                LabeledContent("Status", value: model.snapshot.connection.rawValue)
                connectionControls
                if model.hasStoredPairing && model.capabilities.supportsPairing {
                    Button("Forget pairing", role: .destructive) { model.forgetPairing() }
                }
            }
            // Advanced control is Mobi-only, so the whole section is hidden unless a Mobi is paired
            // (or it's already enabled, so it can still be turned off). t:slim users never see it.
            if model.snapshot.isMobi || settings.advancedControlEnabled {
                Section {
                    Toggle("Advanced control", isOn: $settings.advancedControlEnabled)
                    if settings.advancedControlEnabled {
                        if model.advancedControlAllowed {
                            NavigationLink { PumpControlView(model: model) } label: {
                                Label("Pump Control", systemImage: "slider.horizontal.3")
                            }
                        } else {
                            Text(model.snapshot.isMobi ? "Connect to a Mobi to enable pump control."
                                 : "Advanced control requires a Tandem Mobi pump.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Advanced control") } footer: {
                    Text("Suspend/resume, temp basal, modes, cartridge & fill, CGM session, profiles, limits, and reminders. Mobi only, off by default. Insulin-affecting actions ask for confirmation.")
                }
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
    }

    @ViewBuilder private var connectionControls: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            if !model.capabilities.supportsPairing {
                Button("Connect") { Task { await model.connect() } }
            } else if model.hasStoredPairing {
                Button("Connect (saved pairing)") { Task { await model.connect() } }
                Button("Re-pair with new code") { model.forgetPairing(); showPairing = true }
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

// MARK: - Watch & Garmin

struct RemotesSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    static let siriPhrases = [
        "What's my glucose in faBolus", "Insulin on board in faBolus", "Pump status in faBolus",
        "Any alerts in faBolus", "Last bolus in faBolus",
    ]
    var body: some View {
        Form {
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
            } header: { Text("Garmin remote") } footer: {
                Text("Reorder the Garmin app's swipe screens, and choose how the watch-face BG complication looks. Applied on the watch's next update. ⚠️ If the complication doesn't show correctly, switch the display mode — the color path uses a complication field that's unverified on-device (see docs/UNVERIFIED-GUESSES.md).")
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
                NavigationLink {
                    MacPairingView()
                } label: {
                    Label("Mac remote", systemImage: "laptopcomputer")
                }
            } header: { Text("Mac") } footer: {
                Text("Pair the faBolus Mac app to view status and send boluses from your Mac. First-time pairing needs a one-time code.")
            }
            Section {
                ForEach(RemotesSettingsView.siriPhrases, id: \.self) { p in
                    Label("“\(p)”", systemImage: "mic.fill").font(.callout)
                }
            } header: { Text("Siri (read-only)") } footer: {
                Text("These work automatically — no setup needed. Say “Hey Siri” then a phrase, or add them in the Shortcuts app. Siri never delivers a bolus.")
            }
        }
        .navigationTitle("Watch & Garmin")
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
                Text("faBolus is an independent, open-source project, in development for experimental use. Not FDA-cleared. Not affiliated with Tandem Diabetes Care or Dexcom.")
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
