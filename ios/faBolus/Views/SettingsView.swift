import SwiftUI
import faBolusCore
import faBolusDesign

// MARK: - Shared helpers

/// 09.3-04 (SC1, D-04): the stats-card footer copy shared by the host's "Show statistics card" toggle.
/// Phase 3 (03-02, REMOTE-02): moved here (was `RemoteSettingsView.swift`, now deleted) — it originally
/// backed a footer shared by two mutually-exclusive screens (host `DisplaySettingsView` and the deleted
/// remote-mode `RemoteSettingsView`); now only the host screen remains.
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
    // P14 S3: injected by RootContainerView (same idiom as AppRouter). Drives Settings → Mode.
    @Environment(ModeStore.self) private var modeStore
    // 09.17-02 (D-04/D-06a): live read, never @State — this is what makes rotation and iPad Split
    // View/Slide Over resize re-trigger the correct layout automatically (UI-SPEC §1/§6).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // 09.17-02 (D-04, UI-SPEC §2, Rule 3 — deviation): the type is `SettingsCategory?` — NOT the
    // literally non-optional `SettingsCategory` RESEARCH.md sketched — because SwiftUI's
    // `List.init(selection: Binding<SelectionValue>, content:)` (the truly non-optional overload) is
    // "available on macOS 13.0 and later" ONLY [VERIFIED via Context7 `/websites/developer_apple_swiftui`
    // this session: `xcodebuild` failed with "'init(selection:content:)' is unavailable in iOS" against
    // the non-optional signature]; iOS's `List(selection:)` binds to `Binding<SelectionValue?>`. The
    // NON-OPTIONAL CONTRACT (default `.bolus`, detail pane never blank) is preserved behaviorally, not
    // via the type system: it defaults to `.bolus` here and every read in `body` falls back to `.bolus`
    // via `selectedItem ?? .category(.bolus)` (nothing in this file ever sets it to `nil`).
    //
    // 09.17-06 (CR-01 gap closure): widened from `SettingsCategory?` to `SettingsSidebarItem?` so the
    // SAME `List(selection:)` binding can also drive the five non-`SettingsCategory` groups (Mode,
    // Safety, Child mode, Data & history, Privacy & data) that were reachable on
    // iPhone (`settingsList`) but had no path at all — not even via search — from the iPad sidebar.
    // See `SettingsSidebarItem` below.
    @State private var selectedItem: SettingsSidebarItem? = .category(.bolus)

    var body: some View {
        if horizontalSizeClass == .regular {
            // 09.17-02 (Rule 2 — deviation): SettingsLockGate wraps the WHOLE split view (both panes),
            // not just the sidebar, so Child mode's PIN lock still applies at regular width — the
            // compact branch's lock gate covers 100% of Settings; omitting it here would silently
            // bypass Child mode on iPad. SettingsLockGate itself is untouched (D-06a/UI-SPEC §2).
            // 09.17-06: this gate now also covers the five newly-reachable extra rows below — they're
            // rendered/routed entirely INSIDE this same SettingsLockGate wrapper, so Child mode's PIN
            // lock (and, circularly, the Child mode toggle itself) stay behind the lock exactly as on
            // iPhone. Nothing new escapes the gate.
            SettingsLockGate(settings: settings) {
                NavigationSplitView {
                    sidebarList
                        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
                        .navigationTitle("Settings")
                } detail: {
                    sidebarDestination(selectedItem ?? .category(.bolus))
                }
            }
        } else {
            // TODAY'S body — byte-identical (D-06a). Do not modify.
            NavigationStack {
                SettingsLockGate(settings: settings) { settingsList }
                    .navigationTitle("Settings")
            }
        }
    }

    // 09.17-02 (D-04, UI-SPEC §2): the regular-width sidebar — the SAME 8 routable categories, same
    // order, same title/icon, same category loop as `settingsList`'s below, rendered as
    // `List(selection:)` rows instead of `NavigationLink`s. A search hit sets
    // `selectedItem` (routes to the detail pane) instead of pushing a new stack (RESEARCH Open
    // Questions #1). `destination(_:)` is the SAME @ViewBuilder switch used by both size classes.
    //
    // 09.17-06 (CR-01 gap closure): a second Section mirrors `settingsList`'s non-category rows —
    // Mode selector, Safety (Read-only mode), Child mode, Data & history, and Privacy &
    // data — so every iPhone-reachable setting is also reachable
    // here. This is deliberate content DUPLICATION (not a shared subview extracted from
    // `settingsList`), because extracting one would require editing `settingsList`'s own lines,
    // breaking its byte-identical guarantee (D-06a) — same precedent 09.17-03's `MainHUDView`
    // duplication established for the same reason.
    @ViewBuilder private var sidebarList: some View {
        List(selection: $selectedItem) {
            if query.isEmpty {
                Section {
                    ForEach(SettingsCategory.allCases) { cat in
                        Label(cat.title, systemImage: cat.icon).tag(SettingsSidebarItem.category(cat))
                            .hoverEffect(.automatic)
                    }
                }
                Section {
                    Label("Mode: \(modeStore.activeMode.title)", systemImage: "dial.medium")
                        .tag(SettingsSidebarItem.mode)
                        .hoverEffect(.automatic)
                    Label("Safety (read-only mode)", systemImage: "shield.lefthalf.filled")
                        .tag(SettingsSidebarItem.safety)
                        .hoverEffect(.automatic)
                    Label(settings.childModeEnabled ? "Child mode (on)" : "Child mode", systemImage: "lock.fill")
                        .tag(SettingsSidebarItem.childMode)
                        .hoverEffect(.automatic)
                    Label("Data & history", systemImage: "chart.bar.doc.horizontal")
                        .tag(SettingsSidebarItem.dataHistory)
                        .hoverEffect(.automatic)
                    Label("Privacy & data", systemImage: "hand.raised")
                        .tag(SettingsSidebarItem.privacyData)
                        .hoverEffect(.automatic)
                    // Not selection-based (no `.tag`) — same as `settingsList`'s Help row, this opens
                    // Safari directly rather than routing to a detail-pane screen.
                    Link(destination: faBolusHelpURL) {
                        Label("Help & documentation", systemImage: "questionmark.circle")
                    }
                    .hoverEffect(.automatic)
                }
            } else {
                // 09.17-06 (CR-01): search now covers BOTH the existing category index
                // (`SettingsIndex`, untouched — also used by `settingsList`'s own search) and the new
                // extra-row index (`SettingsExtraIndex`, sidebar-only) so typing "child", "pin",
                // "backup", "safe viewer", "read-only", or "mode" surfaces a hit here too.
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

    /// 09.17-06 (CR-01 gap closure): detail-pane router for `sidebarList`'s selection — a superset of
    /// `destination(_:)` (which stays completely untouched, per D-06a) that ALSO routes the six extra
    /// groups to their existing, unmodified screens. Every case reuses an existing View type; none of
    /// them are reimplemented here.
    @ViewBuilder private func sidebarDestination(_ item: SettingsSidebarItem) -> some View {
        switch item {
        case .category(let cat): destination(cat)
        case .mode: ModeSettingsView()
        case .safety: SafetySettingsView(settings: settings)
        case .childMode: ChildModeView(settings: settings)
        case .dataHistory: DataHistoryView(model: model)
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
                        }
                    }
                    // P14 S3: mode selector. Shows the current mode; opens the unlock/opt-out controls.
                    Section {
                        NavigationLink { ModeSettingsView() } label: {
                            Label("Mode: \(modeStore.activeMode.title)", systemImage: "dial.medium")
                        }
                        .hoverEffect(.automatic)
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
                        .hoverEffect(.automatic)
                        NavigationLink { DataHistoryView(model: model) } label: {
                            Label("Data & history", systemImage: "chart.bar.doc.horizontal")
                        }
                        .hoverEffect(.automatic)
                        NavigationLink { PrivacyDataView(model: model) } label: {
                            Label("Privacy & data", systemImage: "hand.raised")
                        }
                        .hoverEffect(.automatic)
                    } footer: {
                        Text("Child mode locks this device behind a PIN.")
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
        case .alerts:  AlertRulesView(settings: settings)
        case .notifications: NotificationSettingsView(model: model, settings: settings)
        case .pump:    PumpSettingsView(model: model, settings: settings)
        case .remotes: RemotesSettingsView(model: model, settings: settings)
        case .about:   AboutSettingsView(model: model)
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case bolus, display, cgm, alerts, notifications, pump, remotes, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bolus: return "Bolus & entry"
        case .display: return "Display & chart"
        case .cgm: return "CGM & failover"
        case .alerts: return "Alert rules"
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
        case .alerts: return "bell.badge.fill"
        // Distinct from `.alerts`'s icon (D-06) — this screen is the pump/app notification-delivery
        // controls, not the auto-snooze/dismiss rule editor.
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
        .init(title: "Watch & Garmin increments", keywords: "unit bolus carb step remote", category: .bolus),
        .init(title: "Extended bolus & reasoning", keywords: "combo square wave extended duration max safe reasoning iob", category: .bolus),
        .init(title: "Glucose unit", keywords: "mmol mg/dl mg dl unit display convert show unit labels caption", category: .display),
        .init(title: "Chart series (glucose / IOB / bolus)", keywords: "graph axis show hide", category: .display),
        .init(title: "Phone details rows", keywords: "reorder hide fields customize", category: .display),
        .init(title: "Dashboard pills", keywords: "reorder hide pills iob reservoir carb isf target", category: .display),
        .init(title: "Statistics card", keywords: "time in range tir gmi average cv stats a1c", category: .display),
        .init(title: "Watch details rows", keywords: "reorder hide fields customize watch garmin", category: .remotes),
        .init(title: "Watch chart ranges", keywords: "3 6 12 24 hours tap watch", category: .remotes),
        // Phase 3 (03-03, REMOTE-03): title/keywords trimmed to Garmin-only — the Apple Watch
        // bolus-enable toggle this row also advertised is removed (hidden-flag pattern); Garmin's
        // own toggle + read-only override stay live in the same section.
        .init(title: "Allow bolusing from Garmin", keywords: "allow enable remote bolus garmin deliver read only view only", category: .remotes),
        .init(title: "Remote bolus size limit", keywords: "ceiling cap max units remote bolus limit dose garmin", category: .remotes),
        .init(title: "Failover CGM source", keywords: "dexcom share", category: .cgm),
        .init(title: "CGM account credentials", keywords: "login share", category: .cgm),
        .init(title: "Glucose staleness", keywords: "stale hide minutes old reading", category: .cgm),
        .init(title: "Alert auto-rules", keywords: "auto snooze dismiss time of day overnight quiet hours condition", category: .alerts),
        .init(title: "Notification controls", keywords: "pump app critical breakthrough quiet hours per category mute silence", category: .notifications),
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

/// 09.17-06 (CR-01 gap closure): a sum type over the routable `SettingsCategory` rows PLUS the
/// additional non-category setting groups that are reachable on iPhone (`settingsList`) but were
/// missing from the regular-width sidebar (CR-01) — Mode, Safety (Read-only mode), Child mode,
/// Data & history, and Privacy & data. Lets a single
/// `List(selection:)` binding drive both kinds of rows into ONE detail pane, without touching
/// `destination(_:)`, `SettingsCategory`, or `settingsList` (D-06a — those stay byte-identical).
/// Phase 6 (06-02, D-06/D-08): `.backupRestore` is removed (the backup/restore surface is gone from
/// narrow `main`); `.privacyData` STAYS — it routes to the trimmed, erase-only `PrivacyDataView`.
enum SettingsSidebarItem: Hashable {
    case category(SettingsCategory)
    case mode
    case safety
    case childMode
    case dataHistory
    case privacyData

    /// The canonical set of non-category rows `sidebarList`'s second section renders — single source
    /// of truth cross-checked against `SettingsExtraIndex.entries` by `SettingsSidebarParityTests` so
    /// the two can never silently drift apart.
    static let allExtras: [SettingsSidebarItem] = [.mode, .safety, .childMode, .dataHistory, .privacyData]
}

/// 09.17-06 (CR-01 gap closure): search entries for the additional (non-`SettingsCategory`) rows only
/// reachable via the regular-width sidebar's second section. Kept SEPARATE from `SettingsIndex`
/// (rather than widening `SettingsIndex.Entry.category`'s type to a union) because that flat index
/// also drives `settingsList`'s (iPhone) OWN search-to-`destination(_:)` routing; widening it would
/// require touching `settingsList`, breaking its byte-identical guarantee (D-06a). Only consulted by
/// `sidebarList`'s search branch (regular width) — `settingsList`'s search is untouched.
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
        .init(title: "Mode: Simple / Standard / Advanced", keywords: "mode selector simple standard advanced unlock", item: .mode),
        .init(title: "Read-only mode", keywords: "safe viewer caregiver backup phone bolusing disabled pump control hidden clearing alerts", item: .safety),
        .init(title: "Child mode", keywords: "pin lock child mode security", item: .childMode),
        .init(title: "Data & history", keywords: "history data export logs time in range", item: .dataHistory),
        .init(title: "Privacy & data", keywords: "privacy data erase", item: .privacyData),
    ]
}

/// 09.17-06 (CR-01 gap closure): the iPad regular-width sidebar's detail destination for the "Safety"
/// row. Wraps the SAME `settings.phoneReadOnly` / `settings.readOnlyAllowAlertClear` bindings and the
/// SAME copy as `settingsList`'s inline "Safety" `Section` (compact/iPhone) — duplicated into its own
/// small `View` rather than extracted into a shared subview, because extracting would require editing
/// `settingsList`, breaking its byte-identical guarantee (D-06a). Every OTHER extra row
/// (Mode/Child mode/Backup/Data/Privacy) already has its own existing View type and is
/// reused as-is — this is the one group that was previously just an inline `Section`, not a screen.
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
                Text("Turns this phone into a **safe viewer**: bolusing and pump control are disabled and their screens hidden — good for a caregiver or backup phone that should only watch pump + CGM data. Clearing pump alerts is off too unless you allow it above. (The Apple Watch / Garmin have their own switch under Remotes & devices.)")
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
                Toggle("Show recommendation reasoning", isOn: $settings.showBolusReasoning)
                Toggle("Extended (combo) bolus", isOn: $settings.extendedBolusEnabled)
                // 09.3-04 (D-02): plain Toggle, NOT guardedToggle — this only writes the existing
                // stackingGuardFrictionEnabled key; BolusEntryView caps applied friction to .disclose when
                // off (never blocks, never changes the dose). Not a suppress-style safety-reducing toggle.
                Toggle("Extra confirmation on unusually large overrides", isOn: $settings.stackingGuardFrictionEnabled)
            } header: { Text("Bolus screen") } footer: {
                Text("**Reasoning**: a collapsible breakdown (IOB, carb + correction, an advisory max-safe estimate) under the recommended dose. **Extended bolus**: split a dose into now + over-a-duration. **Extra confirmation**: when an override looks unusually large, the bolus screen always shows a note about it; this switch controls whether an extra tap (or, for the largest overrides, re-typing the amount) is also required before delivering. Turning it off still shows the same note — it only skips the extra step. Both off/hidden keep the screen simple.")
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
                // Phase 09.13-01 (D-01/D-02/D-03): discrete preset pickers for the plot Y-axis
                // ceiling + floor, unit-aware via GlucosePlotScale.boundLabel — no free-numeric entry.
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
                Text("Choose which detail rows and pills appear on the phone dashboard. (Watch details + chart ranges are under Remotes & devices.)")
            }
            // WR-01 gap closure (05-06): the opt-in existed end-to-end (AppSettings.glucoseBadgeEnabled,
            // default OFF, SettingsCatalog descriptor) but had no reachable UI. Copy is the D-14
            // plain-language caveat verbatim (05-UI-SPEC.md), plus a short note on the mmol rounding
            // CR-01 introduced.
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
    var body: some View {
        Form {
            Section {
                // 09.3-03 (D-05/SC3): intentional, documented exception to the unified Bool guardedToggle
                // idiom — this picker is String/GlucoseSourceRegistry-backed, not an AppSettings Bool, so
                // guardedToggle cannot type-check it (09.3-RESEARCH.md Open Question 1, Pitfall 3).
                // Phase 1, Plan 02 (CGM-03/CGM-04): the experimental-warning confirm-and-rollback flow
                // (pendingExperimentalId/lastCommittedSource/isReverting/showExperimentalCgmWarning) was
                // removed with `dexcom-g6-ble` — it was the flow's ONLY trigger source.
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
                // D-12: the real, non-debug CGM-status surface (replaces the 7-tap hidden debug menu as
                // the place per-source live status/age/provenance exists — F-08/F-09).
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
            // Nightscout upload section removed from narrow `main` in Phase 5 (HEALTH-02) — see
            // dev/nightscout's REINTEGRATION.md.
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

    /// 09.24-01 (D-02): Section-2 subtitle — the current selection, or explicit guidance to step 1.
    private var configureAndTestSubtitle: String {
        guard let selected = GlucoseSourceRegistry.selected() else {
            return "Not selected — pick a source in step 1"
        }
        return "Selected: \(selected.name)"
    }

    /// 09.24-01 (D-02); WR-01/IN-02/IN-03 fix (09.24 review): Section-3 subtitle. Previously this
    /// guarded only on the raw, unvalidated `GlucoseSourceRegistry.selectedId()`, unlike Section 2's
    /// `configureAndTestSubtitle` above, which validates against `GlucoseSourceRegistry.selected()`.
    /// A stale/invalid persisted id (e.g. a source id left over from a build-flag toggle) made this
    /// section say "Selected — reopen the app to arm" while Section 2 correctly said "Not selected"
    /// for the exact same underlying state. Both subtitles now read from the SAME validated basis
    /// through one shared, pure, unit-tested helper (`CgmStatusView.selectionStatusSubtitle` — closes
    /// IN-02's duplicate-classification note and IN-03's missing test coverage), computed once per
    /// render here so `statusSubtitle`/`statusSubtitleColor` can never disagree with each other either.
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
    // P14 S12 (§2.2.3): the unpair flow. `repairAfter` re-opens pairing after unpair (the "Re-pair with
    // new code" path). One funnel for both unpair entry points. Phase 6 (06-02, D-06): the A4
    // (owner 2026-08-09) two-step "back up before unpair" gate is removed along with the rest of the
    // backup/restore surface — both entry points now go straight to the confirm step.
    @State private var unpairStep: UnpairStep?
    private enum UnpairStep: Identifiable {
        case confirm(repairAfter: Bool)   // S12 charging-base confirm
        var id: String { switch self { case .confirm(let r): return "confirm-\(r)" } }
        var repairAfter: Bool { switch self { case .confirm(let r): return r } }
    }
    var body: some View {
        Form {
            Section("Pump") {
                LabeledContent("Status", value: model.snapshot.connection.rawValue)
                connectionControls
                if model.hasStoredPairing && model.capabilities.supportsPairing {
                    // P14 S12 (§2.2.3): confirm before an unpair; a Mobi gets the unconditional
                    // charging-base warning (re-pairing needs the base).
                    Button("Forget pairing", role: .destructive) { unpairStep = .confirm(repairAfter: false) }
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
                // §13 / D-03: the "temp rate and profile activation aren't active yet" sentence below is
                // insulin-affecting DRAFT copy, §13-pending — it must pass §13 clinical review before any
                // experimental distribution (BRANCHES.md §13). It discloses the build-inert truth:
                // `TempRateAutomation.benchVerifiedDefault` and `ProfileAutomation.profileBenchVerifiedDefault`
                // ship `false`, so both intents refuse every headless run until the Phase-11 saline-bench flag
                // flips. Display copy only — no gate depends on this string.
                Text("**Two steps are required — the switch alone does nothing.** (1) Turn a switch on above: that only *permits* faBolus to change the mode. (2) Create the one-time Apple **Shortcuts automation** that actually triggers it (tap **Set up the Shortcuts automation**) — iOS won't let faBolus create it for you. Once both are in place, the pump switches to **Exercise** when a workout starts and **Sleep** when your iPhone enters Sleep Focus. **Mobi-only** (needs Advanced control); a t:slim can't be switched — turn on reminders to be nudged to do it yourself. **Temp rate and profile activation aren't active yet** — those two actions are pending saline-bench validation and will decline every run until a future faBolus update enables them. All off by default.")
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
        // P14 S12 (§2.2.3): the unpair confirm, carrying the model-appropriate warning
        // (Mobi ⇒ charging-base caveat). One funnel for both entry points. Presented as a
        // confirmationDialog (09.3-03, D-05/SC3). Phase 6 (06-02, D-06): this is now the ONLY step —
        // the A4 "back up first" step-1 gate is removed along with the backup/restore surface.
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
    // §2.3 (G5): the one-time warning shown the FIRST time Garmin bolusing is enabled. (The
    // matching Apple Watch warning state was removed in 03-03, REMOTE-03, along with the
    // now-hidden watchBolusEnabled toggle — see watchBolusBinding's removal note below.)
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
    ///
    /// Phase 3 (03-03, REMOTE-03): the matching `watchBolusBinding` (Apple Watch's equivalent) is
    /// removed — the Watch app it enabled is delete-on-main, and `watchBolusEnabled`'s
    /// `SettingsCatalog` row + backup/restore participation + this UI are all removed (hidden-flag
    /// pattern, same posture as `requireRemoteBolusApproval`, 03-02/F-1). The `AppSettings` accessor
    /// itself stays (frozen `AppModel.swift:360,533` + `AccessPolicy.swift:199` still read it).
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
    /// Phase 09.13-02 (D-05): the optional Watch/Garmin plot Y-axis override, treated as ONE unit — the
    /// on/off state IS the Picker's first-row selection ("Same as phone" vs "Custom"), not a separate
    /// `Toggle`. Turning it on snaps the pair via `GlucosePlotScale.resolve` (seeded from the phone's
    /// current bounds when no prior override exists); turning it off clears BOTH keys back to nil.
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

    var body: some View {
        Form {
            Section {
                Toggle("Allow bolusing from Garmin", isOn: garminBolusBinding)
                if settings.garminBolusEnabled {
                    Toggle("Limit remote bolus size", isOn: remoteCeilingOn)
                    if settings.remoteBolusCeiling != nil {
                        Picker("Max per remote bolus", selection: remoteCeilingValue) {
                            ForEach(AppSettings.remoteBolusCeilingOptions, id: \.self) { Text(fmtU($0)).tag($0) }
                        }
                    }
                }
                Toggle("Read-only (view only)", isOn: $settings.remotesReadOnly)
            } header: { Text("Garmin bolusing") } footer: {
                Text("**Bolusing from Garmin is off by default.** Turn on the switch above to let it deliver a bolus — you'll confirm a one-time warning the first time. **Limit remote bolus size** optionally caps how many units a single Garmin bolus can be, on top of your pump's max bolus; the iPhone is never affected. **Read-only** overrides everything: while on, Garmin shows pump + CGM data only and can't deliver, whatever the switch above says. The iPhone is always unaffected — this is separate from the phone's own read-only mode. (faBolus no longer includes an Apple Watch app — see the note below.)")
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
            // Phase 3 (03-03, REMOTE-03): WATCH_EMBEDDED is permanently retired — this fallback is
            // now the ONLY state (not a build-time toggle). The whole Apple Watch app + complication
            // is removed from narrow main (delete-on-main), preserved on dev/watch-remote.
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
                // Phase 09.13-02 (D-05): optional small-screen plot Y-axis override — one Picker whose
                // first row IS "Same as phone" (no separate boolean toggle); the two dependent Pickers
                // below only appear once "Custom" is selected, mirroring the remoteBolusCeiling reveal.
                Picker("Watch/Garmin plot range", selection: smallPlotOverrideOn) {
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
            } header: { Text("Watch display") } footer: {
                Text("Customize the watch/Garmin Details page and the history-chart tap ranges — separate from the phone. \"Watch/Garmin plot range\" lets the small screens use a different glucose-chart range than the phone; \"Same as phone\" (default) keeps them matched. Mirrored to the remotes on the next update.")
            }
            if let g = model.garminStatus {
                Section { Text(g).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(RemotesSettingsView.siriPhrases, id: \.self) { p in
                    Label("“\(p)”", systemImage: "mic.fill").font(.callout)
                }
            } header: { Text("Siri (read-only)") } footer: {
                Text("These work automatically — no setup needed. Say “Hey Siri” then a phrase, or add them in the Shortcuts app. Siri never delivers a bolus.")
            }
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
        // §2.3: one-time warning. Confirm arms the enable + records the ack; Cancel leaves it off. The
        // enable is explicit and off by default. (The matching Apple Watch confirmationDialog was
        // removed in 03-03, REMOTE-03, along with the watch bolus-enable toggle it warned for.)
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
/// `GarminScreensView`: drag to reorder, swipe to hide, tap to add back. At least one stays shown,
/// UNLESS `allowEmpty` is set (Phase 09.14, D-01/WR-04) — originally opted into by the since-removed
/// Live Activity fields list (Phase 7, 07-01, FEAT-01), whose 0-field state had a real, tested,
/// non-blank fallback render. No current call site passes `allowEmpty: true`; the parameter stays as
/// a general capability for a future reorder/hide list with the same "0 is a valid state" shape.
struct CustomizeListView: View {
    let title: String
    let allIds: [String]
    let label: (String) -> String
    @Binding var order: [String]
    let shownFooter: String
    var allowEmpty: Bool = false   // NEW (09.14 D-01) — default false, every existing call site unaffected

    private var hidden: [String] { allIds.filter { !order.contains($0) } }

    /// Pure guard: whether removing `removingCount` items from a list of `currentCount` is allowed.
    /// `allowEmpty` bypasses the "at least one stays shown" floor entirely. Extracted for unit testing
    /// (`CustomizeListViewGuardTests`) — the `.onDelete` closure below is the only caller.
    static func canDelete(currentCount: Int, removingCount: Int, allowEmpty: Bool) -> Bool {
        allowEmpty || currentCount - removingCount >= 1
    }

    var body: some View {
        Form {
            Section {
                if order.isEmpty {
                    // 09.14 D-01: only reachable when allowEmpty == true (Live Activity fields list).
                    // Non-interactive — no .onMove/.onDelete, no drag handle — matches the app's
                    // existing static empty-list rows (AlertRulesView, PumpWizardViews).
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
                // Suppress the "drag to reorder, swipe to hide" footer when there's nothing left to
                // drag/swipe — the empty-hint row above already carries the full message.
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
                Text("Tapping the watch history chart cycles through the enabled ranges. At least one must stay enabled.")
            }
        }
        .navigationTitle("Watch Chart Ranges")
    }
}
