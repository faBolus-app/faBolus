import SwiftUI
import faBolusCore
import faBolusDesign

// MARK: - Shared helpers

/// Footer copy for the host "Show statistics card" toggle.
enum StatsCardCopy {
    static let footer = "Adds a dashboard card with Time-in-Range, GMI, average, and variability (CV) over the last ~24 hours of readings held in memory."
}

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
    // Live read, never @State — rotation and iPad Split View/Slide Over re-trigger layout.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // Optional because iOS `List(selection:)` binds `Binding<SelectionValue?>` (the non-optional
    // overload is macOS-only). Behaviorally non-optional: defaults to `.bolus` and every read
    // falls back via `selectedItem ?? .category(.bolus)`.
    @State private var selectedItem: SettingsSidebarItem? = .category(.bolus)

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                sidebarList
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
                    .navigationTitle("Settings")
            } detail: {
                sidebarDestination(selectedItem ?? .category(.bolus))
            }
        } else {
            NavigationStack {
                settingsList
                    .navigationTitle("Settings")
            }
        }
    }

    // Regular-width sidebar: same categories as `settingsList`, as `List(selection:)` rows.
    // Extra Safety / Help rows are duplicated here rather than extracted from `settingsList`.
    @ViewBuilder private var sidebarList: some View {
        List(selection: $selectedItem) {
            if query.isEmpty {
                Section {
                    ForEach(SettingsCategory.allCases) { cat in
                        Label(cat.title, systemImage: cat.icon).tag(SettingsSidebarItem.category(cat))
                            .hoverEffect(.automatic)
                        // Privacy & data sits among categories (after Remotes, before About).
                        if cat == .remotes {
                            Label("Privacy & data", systemImage: "hand.raised")
                                .tag(SettingsSidebarItem.privacyData)
                                .hoverEffect(.automatic)
                        }
                    }
                }
                Section {
                    Label("Safety (read-only mode)", systemImage: "shield.lefthalf.filled")
                        .tag(SettingsSidebarItem.safety)
                        .hoverEffect(.automatic)
                    // Privacy & data lives in the category section above, not this Safety group.
                    // Not selection-based (no `.tag`) — opens Safari rather than a detail pane.
                    Link(destination: faBolusHelpURL) {
                        Label("Help & documentation", systemImage: "questionmark.circle")
                    }
                    .hoverEffect(.automatic)
                }
            } else {
                let categoryHits = SettingsIndex.entries.filter { $0.matches(query) }
                let extraHits = SettingsExtraIndex.entries.filter { $0.matches(query) }
                if categoryHits.isEmpty && extraHits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(categoryHits) { e in
                        Button { selectedItem = .category(e.category) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title)
                                Text(e.category.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.automatic)
                    }
                    ForEach(extraHits) { e in
                        Button { selectedItem = e.item } label: {
                            Text(e.title)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.automatic)
                    }
                }
            }
        }
    }

    /// Detail-pane router for `sidebarList` — `destination(_:)` plus Safety / Privacy.
    @ViewBuilder private func sidebarDestination(_ item: SettingsSidebarItem) -> some View {
        switch item {
        case .category(let cat): destination(cat)
        case .safety: SafetySettingsView(settings: settings)
        case .privacyData: PrivacyDataView(model: model)
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
                            .hoverEffect(.automatic)
                            // Privacy & data among categories (after Remotes, before About), not
                            // in a section below the Safety toggle.
                            if cat == .remotes {
                                NavigationLink { PrivacyDataView(model: model) } label: {
                                    Label("Privacy & data", systemImage: "hand.raised")
                                }
                                .hoverEffect(.automatic)
                            }
                        }
                    }
                    Section {
                        Toggle("Read-only mode", isOn: $settings.phoneReadOnly)
                        if settings.phoneReadOnly {
                            Toggle("Still allow clearing alerts", isOn: $settings.readOnlyAllowAlertClear)
                        }
                    } header: { Text("Safety") } footer: {
                        Text("Turns this phone into a **safe viewer**: bolusing and pump control are disabled and their screens hidden — good for a caregiver or backup phone that should only watch pump + CGM data. Clearing pump alerts is off too unless you allow it above. (Garmin has its own switch under Remotes & devices — the Apple Watch remote is removed, so it has no separate switch anymore.)")
                    }
                    Section {
                        Link(destination: faBolusHelpURL) {
                            Label("Help & documentation", systemImage: "questionmark.circle")
                        }
                        .hoverEffect(.automatic)
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
                            .hoverEffect(.automatic)
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
        case .notifications: NotificationSettingsView(model: model, settings: settings)
        case .pump:    PumpSettingsView(model: model, settings: settings)
        case .remotes: RemotesSettingsView(model: model, settings: settings)
        case .about:   AboutSettingsView(model: model)
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case bolus, display, cgm, notifications, pump, remotes, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bolus: return "Bolus & entry"
        case .display: return "Display & chart"
        case .cgm: return "CGM & failover"
        case .notifications: return "Notifications"
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
        case .notifications: return "bell.and.waves.left.and.right"
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
        .init(title: "Garmin increments", keywords: "unit bolus carb step remote watch", category: .bolus),
        .init(title: "Recommendation reasoning", keywords: "reasoning iob max safe estimate breakdown", category: .bolus),
        .init(title: "Chart series (glucose / IOB / bolus)", keywords: "graph axis show hide", category: .display),
        .init(title: "Phone details rows", keywords: "reorder hide fields customize", category: .display),
        .init(title: "Dashboard pills", keywords: "reorder hide pills iob reservoir carb isf target", category: .display),
        .init(title: "Statistics card", keywords: "time in range tir gmi average cv stats a1c", category: .display),
        .init(title: "Garmin details rows", keywords: "reorder hide fields customize watch garmin", category: .remotes),
        .init(title: "Garmin chart ranges", keywords: "3 6 12 24 hours tap watch", category: .remotes),
        .init(title: "Allow bolusing from Garmin", keywords: "allow enable remote bolus garmin deliver read only view only", category: .remotes),
        .init(title: "Remote bolus size limit", keywords: "ceiling cap max units remote bolus limit dose garmin", category: .remotes),
        .init(title: "Failover CGM source", keywords: "dexcom share", category: .cgm),
        .init(title: "CGM account credentials", keywords: "login share", category: .cgm),
        .init(title: "Glucose staleness", keywords: "stale hide minutes old reading", category: .cgm),
        .init(title: "Notification controls", keywords: "pump app critical breakthrough quiet hours per category mute silence", category: .notifications),
        .init(title: "Pump connection", keywords: "connect disconnect pair pairing", category: .pump),
        .init(title: "Pump backend", keywords: "tandem mock", category: .pump),
        .init(title: "Garmin screen order", keywords: "swipe screens remote", category: .remotes),
        .init(title: "Garmin complication display", keywords: "watch face color trend arrow", category: .remotes),
        .init(title: "Garmin complications", keywords: "watch face slots iob reservoir battery basal pump status", category: .remotes),
        .init(title: "Garmin alert intensity", keywords: "vibrate silent audible tone backlight do not disturb dnd critical alarm sound", category: .remotes),
        .init(title: "Garmin analog clock face", keywords: "analog digital clock face hands watch", category: .remotes),
        .init(title: "Set up Garmin remote", keywords: "connect iq install", category: .remotes),
        .init(title: "Help & documentation", keywords: "docs website fabolus.org support", category: .about),
        .init(title: "Debug diagnostics", keywords: "logs developer", category: .about),
    ]
}

/// Routable `SettingsCategory` plus the extra sidebar rows (Safety, Privacy) that share one
/// `List(selection:)` binding.
enum SettingsSidebarItem: Hashable {
    case category(SettingsCategory)
    case safety
    case privacyData

    /// Non-category sidebar rows. `SettingsSidebarParityTests` cross-checks this against
    /// `SettingsExtraIndex.entries` so the two cannot drift.
    static let allExtras: [SettingsSidebarItem] = [.safety, .privacyData]
}

/// Search entries for the extra (non-`SettingsCategory`) sidebar rows. Kept separate from
/// `SettingsIndex` because that index also drives iPhone `settingsList` search routing.
enum SettingsExtraIndex {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let keywords: String
        let item: SettingsSidebarItem
        func matches(_ q: String) -> Bool {
            let s = q.lowercased()
            return title.lowercased().contains(s) || keywords.lowercased().contains(s)
        }
    }
    static let entries: [Entry] = [
        .init(title: "Read-only mode", keywords: "safe viewer caregiver backup phone bolusing disabled pump control hidden clearing alerts", item: .safety),
        .init(title: "Privacy & data", keywords: "privacy data erase", item: .privacyData),
    ]
}

/// iPad sidebar detail for the Safety row — same bindings and copy as the compact Safety section.
struct SafetySettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Read-only mode", isOn: $settings.phoneReadOnly)
                if settings.phoneReadOnly {
                    Toggle("Still allow clearing alerts", isOn: $settings.readOnlyAllowAlertClear)
                }
            } header: { Text("Safety") } footer: {
                Text("Turns this phone into a **safe viewer**: bolusing and pump control are disabled and their screens hidden — good for a caregiver or backup phone that should only watch pump + CGM data. Clearing pump alerts is off too unless you allow it above. (Garmin has its own switch under Remotes & devices — the Apple Watch remote is removed, so it has no separate switch anymore.)")
            }
        }
        .navigationTitle("Safety")
    }
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
                Picker("Garmin default mode", selection: $settings.watchDefaultBolusMode) {
                    Text("Carbs").tag(BolusMode.carbs)
                    Text("Units").tag(BolusMode.units)
                }
            } header: { Text("Bolus entry") } footer: { Text("Default entry mode. **Phone** covers the iPhone and the widget; **Garmin** is independent, for the Garmin bolus screen (the Apple Watch remote is removed).") }
            Section {
                Picker("Unit increment", selection: $settings.bolusIncrement) {
                    ForEach(AppSettings.bolusIncrements, id: \.self) { Text(fmtU($0)).tag($0) }
                }
                Picker("Carb increment", selection: $settings.carbIncrement) {
                    ForEach(AppSettings.carbIncrements, id: \.self) { Text("\(Int($0)) g").tag($0) }
                }
            } header: { Text("iPhone increments") } footer: { Text("Steps for the iPhone bolus screen and the Home-Screen widget.") }
            Section {
                Toggle("Show recommendation reasoning", isOn: $settings.showBolusReasoning)
            } header: { Text("Bolus screen") } footer: {
                Text("A collapsible breakdown (IOB, carb + correction, an advisory max-safe estimate) under the recommended dose.")
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
                Picker("Plot ceiling", selection: $settings.glucosePlotCeiling) {
                    ForEach(AppSettings.glucosePlotCeilingOptions, id: \.self) { opt in
                        Text(GlucosePlotScale.boundLabel(opt, unit: settings.glucoseDisplayUnit)).tag(opt)
                    }
                }
                Picker("Plot floor", selection: $settings.glucosePlotFloor) {
                    ForEach(AppSettings.glucosePlotFloorOptions, id: \.self) { opt in
                        Text(GlucosePlotScale.boundLabel(opt, unit: settings.glucoseDisplayUnit)).tag(opt)
                    }
                }
            }
            Section {
                Toggle("Show statistics card", isOn: $settings.showStats)
            } header: { Text("Statistics") } footer: {
                Text(StatsCardCopy.footer + " Off by default to keep the dashboard clean.")
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
                Text("Choose which detail rows and pills appear on the phone dashboard. (Garmin details + chart ranges are under Remotes & devices.)")
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
                // String/registry-backed picker — not an AppSettings Bool, so `guardedToggle` doesn't apply.
                Picker("Failover CGM", selection: $selectedGlucoseSource) {
                    Text("None (pump only)").tag("")
                    ForEach(GlucoseSourceRegistry.enabled) { Text($0.name).tag($0.id) }
                }
                .onChange(of: selectedGlucoseSource) { _, id in
                    GlucoseSourceRegistry.select(id.isEmpty ? nil : id)
                }
            } header: { Text("1. Choose a source") } footer: {
                Text("An independent CGM feed used when the pump's glucose goes stale (pump, phone, or sensor link dropped). Old readings are shown marked, never as current. Takes effect after you reopen the app.")
            }
            Section {
                NavigationLink { CgmCredentialsView(model: model) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("CGM credentials & testing", systemImage: "key.fill")
                        Text(configureAndTestSubtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("2. Configure & test") } footer: {
                Text("Enter credentials for the selected source (if it needs any) and confirm it can get a reading.")
            }
            Section {
                NavigationLink { CgmStatusView(model: model) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("CGM source status", systemImage: "chart.line.uptrend.xyaxis")
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(statusSubtitleColor)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("3. Status") } footer: {
                Text("See live status, freshness, and the last test result for every configured source.")
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

    /// Section-2 subtitle — current selection, or guidance to step 1.
    private var configureAndTestSubtitle: String {
        guard let selected = GlucoseSourceRegistry.selected() else {
            return "Not selected — pick a source in step 1"
        }
        return "Selected: \(selected.name)"
    }

    /// Same `GlucoseSourceRegistry.selected()` basis as Section 2 so a stale persisted id cannot
    /// say "Selected" here while step 2 says "Not selected".
    private var currentSelectionSubtitle: (text: String, isActive: Bool) {
        let selected = GlucoseSourceRegistry.selected().map { (id: $0.id, name: $0.name) }
        return CgmStatusView.selectionStatusSubtitle(selected: selected,
                                                      armedId: model.glucoseSourceProbe?.id,
                                                      provenance: model.glucoseProvenance)
    }

    private var statusSubtitle: String { currentSelectionSubtitle.text }

    private var statusSubtitleColor: Color {
        currentSelectionSubtitle.isActive ? AppTheme.inRange : .secondary
    }
}

// MARK: - Pump & control

struct PumpSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var settings: AppSettings
    @State private var showPairing = false
    @State private var selectedBackend = BackendRegistry.selected().id
    @State private var unpairStep: UnpairStep?
    private enum UnpairStep: Identifiable {
        case confirm(repairAfter: Bool)   // charging-base confirm before unpair
        var id: String { switch self { case .confirm(let r): return "confirm-\(r)" } }
        var repairAfter: Bool { switch self { case .confirm(let r): return r } }
    }
    var body: some View {
        Form {
            Section("Pump") {
                LabeledContent("Status", value: model.snapshot.connection.rawValue)
                connectionControls
                if model.hasStoredPairing && model.capabilities.supportsPairing {
                    // Confirm before unpair; a Mobi needs the charging base to re-pair.
                    Button("Forget pairing", role: .destructive) { unpairStep = .confirm(repairAfter: false) }
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
        // Unpair confirm (Mobi copy includes the charging-base caveat).
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
        // Mobi reject-at-pairing: observe here so it outlives the transient PairingSheet.
        .onChange(of: model.snapshot.pumpModel) { _, _ in model.rejectMobiIfDetected() }
    }

    @ViewBuilder private var connectionControls: some View {
        switch model.snapshot.connection {
        case .disconnected, .error:
            if !model.capabilities.supportsPairing {
                Button("Connect") { Task { await model.connect() } }
            } else if model.hasStoredPairing {
                Button("Connect (saved pairing)") { Task { await model.connect() } }
                Button("Re-pair with new code") { unpairStep = .confirm(repairAfter: true) }
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
    // First-enable warning for Garmin bolusing.
    @State private var showGarminBolusWarning = false
    // Optional Garmin bolus passcode UI. `passcodeSet` mirrors Keychain-backed
    // `BolusPasscodeStore.isRequired` (refreshed on appear + after set/clear) — the store isn't Observable.
    @State private var showSetPasscode = false
    @State private var passcodeSet = false

    /// Turning enable ON routes through the one-time warning on first use (Confirm arms it +
    /// records the ack; Cancel leaves it off). Turning OFF is always immediate.
    private var garminBolusBinding: Binding<Bool> {
        guardedToggle(
            get: { settings.garminBolusEnabled },
            set: { settings.garminBolusEnabled = $0 },
            skipConfirmIf: { settings.hasAcknowledgedGarminBolusWarning },
            requestConfirm: { showGarminBolusWarning = true }
        )
    }
    /// Optional remote-only dose ceiling. Toggle arms the default cap; picker edits it.
    /// `nil` (off) ⇒ the pump's max alone governs remote boluses.
    private var remoteCeilingOn: Binding<Bool> {
        Binding(get: { settings.remoteBolusCeiling != nil },
                set: { on in settings.remoteBolusCeiling = on ? (settings.remoteBolusCeiling ?? AppSettings.defaultRemoteBolusCeiling) : nil })
    }
    private var remoteCeilingValue: Binding<Double> {
        Binding(get: { settings.remoteBolusCeiling ?? AppSettings.defaultRemoteBolusCeiling },
                set: { settings.remoteBolusCeiling = $0 })
    }
    /// Optional Watch/Garmin plot Y-axis override, treated as one unit — on/off is the Picker's
    /// first-row selection ("Same as phone" vs "Custom"). Off clears both keys to nil.
    private var smallPlotOverrideOn: Binding<Bool> {
        Binding(
            get: { settings.glucosePlotFloorSmall != nil },
            set: { on in
                if on {
                    let resolved = GlucosePlotScale.resolve(
                        storedFloor: settings.glucosePlotFloorSmall ?? settings.glucosePlotFloor,
                        storedCeiling: settings.glucosePlotCeilingSmall ?? settings.glucosePlotCeiling)
                    settings.glucosePlotFloorSmall = resolved.floor
                    settings.glucosePlotCeilingSmall = resolved.ceiling
                } else {
                    settings.glucosePlotFloorSmall = nil
                    settings.glucosePlotCeilingSmall = nil
                }
            })
    }
    private var smallPlotFloorValue: Binding<Int> {
        Binding(get: { settings.glucosePlotFloorSmall ?? settings.glucosePlotFloor },
                set: { settings.glucosePlotFloorSmall = $0 })
    }
    private var smallPlotCeilingValue: Binding<Int> {
        Binding(get: { settings.glucosePlotCeilingSmall ?? settings.glucosePlotCeiling },
                set: { settings.glucosePlotCeilingSmall = $0 })
    }

    /// One plain-language line summarizing the net effect of the toggles below — computed from
    /// current values, no new persisted state.
    private var garminBolusStatusSummary: String {
        if settings.remotesReadOnly { return "Garmin now: view only — it can't deliver a bolus." }
        if !settings.garminBolusEnabled { return "Garmin now: bolusing is off." }
        if let ceiling = settings.remoteBolusCeiling {
            return "Garmin now: can deliver a bolus, up to \(fmtU(ceiling)) per dose."
        }
        return "Garmin now: can deliver a bolus."
    }

    var body: some View {
        Form {
            // Read-only override listed first — it wins over enable and ceiling below.
            Section {
                Text(garminBolusStatusSummary)
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("Read-only (view only)", isOn: $settings.remotesReadOnly)
                Toggle("Allow bolusing from Garmin", isOn: garminBolusBinding)
                if settings.garminBolusEnabled {
                    Toggle("Limit remote bolus size", isOn: remoteCeilingOn)
                    if settings.remoteBolusCeiling != nil {
                        Picker("Max per remote bolus", selection: remoteCeilingValue) {
                            ForEach(AppSettings.remoteBolusCeilingOptions, id: \.self) { Text(fmtU($0)).tag($0) }
                        }
                    }
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
                }
            } header: { Text("Garmin bolusing") } footer: {
                Text("**Read-only overrides everything below**: while on, Garmin shows pump + CGM data only and can't deliver, whatever the other switches say. **Bolusing from Garmin is off by default** — turn it on to let Garmin deliver; you'll confirm a one-time warning the first time. **Limit remote bolus size** optionally caps how many units a single Garmin bolus can be, on top of your pump's max bolus. The optional **passcode** (shown once you turn bolusing on) asks for a 4-digit code instead of tap-to-confirm — a stronger check for a watch with no wrist detection. The iPhone is always unaffected by any switch here — its own read-only mode is separate, under Safety. (faBolus no longer includes an Apple Watch app — see the note below.)")
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
                Text("faBolus no longer includes an Apple Watch app — nothing installs to a paired watch. Use the Garmin remote below, or the iPhone app directly.")
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
            } header: { Text("Garmin bolus") } footer: {
                Text("Default entry mode and increments for the Garmin bolus screen (independent of the iPhone; the Apple Watch remote is removed). Same settings as under Bolus & entry.")
            }
            Section {
                NavigationLink {
                    CustomizeListView(title: "Garmin details", allIds: AppSettings.detailFields,
                                      label: AppSettings.detailFieldLabel, order: $settings.watchDetailsOrder,
                                      shownFooter: "Rows shown on the Garmin Details page (independent of the phone). Drag to reorder, swipe to hide.")
                } label: { LabeledContent("Garmin details rows", value: "\(settings.watchDetailsOrder.count) shown") }
                NavigationLink { WatchChartRangesView(settings: settings) } label: {
                    LabeledContent("Garmin chart ranges", value: settings.watchChartRanges.map { "\($0)h" }.joined(separator: " "))
                }
                Picker("Garmin plot range", selection: smallPlotOverrideOn) {
                    Text("Same as phone").tag(false)
                    Text("Custom").tag(true)
                }
                if settings.glucosePlotFloorSmall != nil {
                    Picker("Plot ceiling", selection: smallPlotCeilingValue) {
                        ForEach(AppSettings.glucosePlotCeilingOptions, id: \.self) { opt in
                            Text(GlucosePlotScale.boundLabel(opt, unit: settings.glucoseDisplayUnit)).tag(opt)
                        }
                    }
                    Picker("Plot floor", selection: smallPlotFloorValue) {
                        ForEach(AppSettings.glucosePlotFloorOptions, id: \.self) { opt in
                            Text(GlucosePlotScale.boundLabel(opt, unit: settings.glucoseDisplayUnit)).tag(opt)
                        }
                    }
                }
                NavigationLink { GarminComplicationsView(settings: settings) } label: {
                    LabeledContent("Garmin complications",
                                   value: settings.garminComplicationSlots.isEmpty ? "None"
                                        : settings.garminComplicationSlots.map { AppSettings.garminComplicationFieldLabel($0).components(separatedBy: " (").first ?? $0 }.joined(separator: ", "))
                }
            } header: { Text("Garmin display") } footer: {
                Text("Customize the Garmin Details page and the history-chart tap ranges — separate from the phone. \"Garmin plot range\" lets the small screens use a different glucose-chart range than the phone; \"Same as phone\" (default) keeps them matched. \"Garmin complications\" picks which pump-status readouts fill the watch face's three slots (alongside glucose). Mirrored to the remotes on the next update.")
            }
            Section {
                Picker("Alert intensity", selection: $settings.garminAlertIntensityMode) {
                    ForEach(AppSettings.alertIntensityModeOptions, id: \.self) {
                        Text(AppSettings.alertIntensityModeLabel($0)).tag($0)
                    }
                }
                if settings.garminAlertIntensityMode == "audible" {
                    Picker("Play tone for", selection: $settings.garminAlertAudibleMinSeverity) {
                        Text("All alerts").tag("info")
                        Text("High & critical").tag("high")
                        Text("Critical only").tag("critical")
                    }
                }
                Toggle("Critical alerts override Do Not Disturb", isOn: $settings.garminAlertCriticalOverridesDnd)
            } header: { Text("Garmin alerts") } footer: {
                Text("How the Garmin watch alerts you. **Vibration only** (default) buzzes for every alert; **Audible** adds a tone + backlight at/above the level you pick; **Silent** means the watch stays quiet and your phone is the only alert. \"Critical alerts override Do Not Disturb\" is off by default — turn it on to let a critical alert buzz through DND (in Silent mode that adds a vibration for critical alerts, never a tone). The phone always alerts regardless of this setting.")
            }
            if let g = model.garminStatus {
                Section { Text(g).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Remotes & devices")
        // Keep the passcode section in sync with the Keychain-backed store.
        .onAppear { passcodeSet = BolusPasscodeStore.isRequired }
        .sheet(isPresented: $showSetPasscode) {
            // Honor the store's Bool — a failed save keeps the sheet open.
            BolusPasscodeEntryView { code in
                let ok = BolusPasscodeStore.setPasscode(code)
                if ok { passcodeSet = BolusPasscodeStore.isRequired }
                return ok
            }
        }
        // One-time warning. Confirm arms the enable + records the ack; Cancel leaves it off.
        .confirmationDialog("Allow bolusing from Garmin?", isPresented: $showGarminBolusWarning,
                             titleVisibility: .visible) {
            Button("Allow bolusing") { settings.acknowledgeGarminBolusWarning(); settings.garminBolusEnabled = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This lets you deliver real insulin from your Garmin watch. A Garmin has no wrist detection, so take extra care that a bolus is never started by an accidental button press — it stays off until you allow it here, and every bolus still needs your confirmation on the watch. You can turn this off any time.")
        }
    }
}

/// Set (or change) the optional 4-digit Garmin bolus passcode. Entered twice to confirm; stored
/// via `BolusPasscodeStore` (salted SHA-256 in the Keychain; the raw code is never persisted).
struct BolusPasscodeEntryView: View {
    /// The validated 4-digit code to store. Returns whether it was actually stored.
    let onSet: (String) -> Bool
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
        // Failed save keeps the sheet open instead of dismissing as if the passcode changed.
        guard onSet(digits) else { error = "Couldn't save the passcode. Try again."; return }
        dismiss()
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

// MARK: - Reorder/customize sub-editors

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

/// Generic reorder/hide editor for a list of field ids (Details rows, dashboard Pills). At least
/// one stays shown unless `allowEmpty` is set.
struct CustomizeListView: View {
    let title: String
    let allIds: [String]
    let label: (String) -> String
    @Binding var order: [String]
    let shownFooter: String
    var allowEmpty: Bool = false

    private var hidden: [String] { allIds.filter { !order.contains($0) } }

    /// Whether removing items is allowed. `allowEmpty` bypasses the "at least one stays shown" floor.
    static func canDelete(currentCount: Int, removingCount: Int, allowEmpty: Bool) -> Bool {
        allowEmpty || currentCount - removingCount >= 1
    }

    var body: some View {
        Form {
            Section {
                if order.isEmpty {
                    Text("No fields shown — the Live Activity displays a minimal synced-status glyph. Add a field below to bring it back.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(order, id: \.self) { id in
                        Label(label(id), systemImage: "line.3.horizontal")
                    }
                    .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
                    .onDelete { idx in
                        if Self.canDelete(currentCount: order.count, removingCount: idx.count, allowEmpty: allowEmpty) {
                            order.remove(atOffsets: idx)
                        }
                    }
                }
            } header: {
                Text("Shown (top → bottom)")
            } footer: {
                // Don't show "drag to reorder" when there's nothing left to drag.
                if !order.isEmpty { Text(shownFooter) }
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
                Text("Tapping the Garmin history chart cycles through the enabled ranges. At least one must stay enabled.")
            }
        }
        .navigationTitle("Garmin Chart Ranges")
    }
}

/// Pick which pump-status fields fill the Garmin watch face's three user-assignable complication
/// slots (Connect IQ caps an app at four total, including the fixed glucose complication).
struct GarminComplicationsView: View {
    @Bindable var settings: AppSettings
    private let fields = AppSettings.garminComplicationFields   // iob / reservoir / battery / basal

    private func slotBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let s = settings.garminComplicationSlots
                return index < s.count ? s[index] : "none"
            },
            set: { newValue in
                var slots = settings.garminComplicationSlots
                while slots.count < 3 { slots.append("none") }
                slots[index] = newValue
                // De-dupe (first slot wins), drop "None", cap at 3.
                var out: [String] = []
                for f in slots where f != "none" && !out.contains(f) { out.append(f) }
                settings.garminComplicationSlots = Array(out.prefix(3))
            })
    }

    var body: some View {
        Form {
            Section {
                ForEach(0..<3, id: \.self) { i in
                    Picker("Slot \(i + 1)", selection: slotBinding(i)) {
                        Text("None").tag("none")
                        ForEach(fields, id: \.self) { f in
                            Text(AppSettings.garminComplicationFieldLabel(f)).tag(f)
                        }
                    }
                }
            } header: { Text("Watch face slots") } footer: {
                Text("Glucose always fills one complication. Connect IQ allows four total, so you can add up to three more pump-status readouts here. On the watch, add each \"faBolus Pump Status\" complication to your face — slot 1 shows your first pick, slot 2 your second, slot 3 your third. Picking the same field twice keeps only the first. Mirrored to the watch on its next update.")
            }
        }
        .navigationTitle("Garmin Complications")
    }
}
