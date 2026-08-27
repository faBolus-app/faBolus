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
    // Phase 8 (08-01, LOCK-01): the `ModeStore` environment read is removed — this file's only two
    // uses (the "Mode: …" sidebar/list rows + the `ModeSettingsView` destinations) are both deleted;
    // `RootContainerView` still injects `ModeStore` into the environment for other consumers.
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
            // Phase 7 (07-04, FEAT-04, D-05, SAFETY): the `SettingsLockGate` wrapper that used to sit
            // here is removed — Child mode's `childModeEnabled` is now a permanently-frozen `false`
            // (belt-and-suspenders, `AppSettings.swift`), so `SettingsLockGate.locked` could never
            // evaluate `true` again; unlocked, it rendered `content()` with zero wrapping chrome, so
            // this is a pixel-identical no-op removal (confirmed via `SettingsSnapshotTests`), not a
            // behavior change. `SettingsLockGate`/`ChildModeView.swift` (its only definition site) are
            // deleted; preserved on `dev/child-mode`.
            NavigationSplitView {
                sidebarList
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
                    .navigationTitle("Settings")
            } detail: {
                sidebarDestination(selectedItem ?? .category(.bolus))
            }
        } else {
            // Phase 7 (07-04, FEAT-04, D-05, SAFETY): same `SettingsLockGate` removal as the
            // regular-width branch above — pixel-identical no-op (see that comment). This branch was
            // previously marked "byte-identical (D-06a), do not modify" for a DIFFERENT reason (keeping
            // it pinned while the regular-width sidebar+detail branch was being added, 09.17-02) — that
            // constraint was about the compact/regular split staying visually decoupled, not about this
            // specific dead wrapper surviving forever.
            NavigationStack {
                settingsList
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
                        // Privacy & data sits among the category rows now — between "Remotes & devices"
                        // and "About & help" — instead of in the Safety group below.
                        if cat == .remotes {
                            Label("Privacy & data", systemImage: "hand.raised")
                                .tag(SettingsSidebarItem.privacyData)
                                .hoverEffect(.automatic)
                        }
                    }
                }
                Section {
                    // Phase 8 (08-01, LOCK-01): the "Mode: …" sidebar row is removed —
                    // `ModeSettingsView`/`ModeOnboardingView` are deleted; `appMode` is force-set
                    // `.advanced` in both `ModeStore.init` and `AppSettings.init`.
                    Label("Safety (read-only mode)", systemImage: "shield.lefthalf.filled")
                        .tag(SettingsSidebarItem.safety)
                        .hoverEffect(.automatic)
                    // Phase 7 (07-04, FEAT-04, D-05, SAFETY): the "Child mode" sidebar row is removed —
                    // ChildModeView.swift is deleted; childModeEnabled is permanently frozen false.
                    // Phase 8 (08-01, LOCK-03): the "Data & history" sidebar row is removed —
                    // DataHistoryView.swift is deleted; historyRetentionDays is force-set to the 24h
                    // pin and actually applied via the new App.swift launch call site.
                    // Privacy & data moved UP into the category section above (between Remotes & devices
                    // and About & help); it is no longer in this Safety group.
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
                            // Privacy & data lives among the category rows now — between "Remotes &
                            // devices" and "About & help" — instead of in its own section below the
                            // Safety (read-only) toggle.
                            if cat == .remotes {
                                NavigationLink { PrivacyDataView(model: model) } label: {
                                    Label("Privacy & data", systemImage: "hand.raised")
                                }
                                .hoverEffect(.automatic)
                            }
                        }
                    }
                    // Phase 8 (08-01, LOCK-01): the mode-selector Section (NavigationLink to
                    // `ModeSettingsView`) is removed — `ModeSettingsView`/`ModeOnboardingView` are
                    // deleted; `appMode` is force-set `.advanced` in both `ModeStore.init` and
                    // `AppSettings.init`.
                    Section {
                        Toggle("Read-only mode", isOn: $settings.phoneReadOnly)
                        if settings.phoneReadOnly {
                            Toggle("Still allow clearing alerts", isOn: $settings.readOnlyAllowAlertClear)
                        }
                    } header: { Text("Safety") } footer: {
                        Text("Turns this phone into a **safe viewer**: bolusing and pump control are disabled and their screens hidden — good for a caregiver or backup phone that should only watch pump + CGM data. Clearing pump alerts is off too unless you allow it above. (Garmin has its own switch under Remotes & devices — the Apple Watch remote is removed, so it has no separate switch anymore.)")
                    }
                    // Privacy & data moved UP into the category section above (between Remotes & devices
                    // and About & help); its former standalone section here is gone. (History: that
                    // section had also hosted the now-removed "Child mode" (Phase 7, 07-04) and
                    // "Data & history" (Phase 8, 08-01, LOCK-03) rows before they were deleted.)
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
        // Phase 7 (07-05, FEAT-08): the custom alert-rules editor (`.alerts`, "bell.badge.fill") that
        // this icon used to be distinguished FROM is removed — this screen is still the pump/app
        // notification-delivery controls, not an auto-snooze/dismiss rule editor (no such editor
        // remains on narrow main; see dev/alert-rules).
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
        // Phase 8 (08-01, LOCK-04): trimmed from "Extended bolus & reasoning" — the extended-bolus
        // keywords (combo/square wave/extended/duration) are dropped; "max safe"/"iob" stay (they
        // describe the surviving Reasoning breakdown's own footer copy, not the removed toggle).
        .init(title: "Recommendation reasoning", keywords: "reasoning iob max safe estimate breakdown", category: .bolus),
        // Phase 8 (08-01, LOCK-02): the "Glucose unit" row is removed — the unit Picker + "Show unit
        // labels" toggle Section it advertised is deleted; `glucoseDisplayUnit` is a force-set `.mgdl`
        // init pin with no UI to change it.
        .init(title: "Chart series (glucose / IOB / bolus)", keywords: "graph axis show hide", category: .display),
        .init(title: "Phone details rows", keywords: "reorder hide fields customize", category: .display),
        .init(title: "Dashboard pills", keywords: "reorder hide pills iob reservoir carb isf target", category: .display),
        .init(title: "Statistics card", keywords: "time in range tir gmi average cv stats a1c", category: .display),
        .init(title: "Garmin details rows", keywords: "reorder hide fields customize watch garmin", category: .remotes),
        .init(title: "Garmin chart ranges", keywords: "3 6 12 24 hours tap watch", category: .remotes),
        // Phase 3 (03-03, REMOTE-03): title/keywords trimmed to Garmin-only — the Apple Watch
        // bolus-enable toggle this row also advertised is removed (hidden-flag pattern); Garmin's
        // own toggle + read-only override stay live in the same section.
        .init(title: "Allow bolusing from Garmin", keywords: "allow enable remote bolus garmin deliver read only view only", category: .remotes),
        .init(title: "Remote bolus size limit", keywords: "ceiling cap max units remote bolus limit dose garmin", category: .remotes),
        .init(title: "Failover CGM source", keywords: "dexcom share", category: .cgm),
        .init(title: "CGM account credentials", keywords: "login share", category: .cgm),
        .init(title: "Glucose staleness", keywords: "stale hide minutes old reading", category: .cgm),
        .init(title: "Notification controls", keywords: "pump app critical breakthrough quiet hours per category mute silence", category: .notifications),
        .init(title: "Pump connection", keywords: "connect disconnect pair pairing", category: .pump),
        // Phase 9 (09-02, MOBI-02): the "Advanced control" row is removed — the Settings Section it
        // advertised (below), and the PumpControlView.swift screen it linked to, are both deleted.
        .init(title: "Pump backend", keywords: "tandem mock", category: .pump),
        .init(title: "Garmin screen order", keywords: "swipe screens remote", category: .remotes),
        .init(title: "Garmin complication display", keywords: "watch face color trend arrow", category: .remotes),
        .init(title: "Garmin analog clock face", keywords: "analog digital clock face hands watch", category: .remotes),
        .init(title: "Set up Garmin remote", keywords: "connect iq install", category: .remotes),
        .init(title: "Help & documentation", keywords: "docs website fabolus.org support", category: .about),
        .init(title: "Debug diagnostics", keywords: "logs developer", category: .about),
    ]
}

/// 09.17-06 (CR-01 gap closure): a sum type over the routable `SettingsCategory` rows PLUS the
/// additional non-category setting groups that are reachable on iPhone (`settingsList`) but were
/// missing from the regular-width sidebar (CR-01) — Safety (Read-only mode) and Privacy & data. Lets a
/// single `List(selection:)` binding drive both kinds of rows into ONE detail pane, without touching
/// `destination(_:)`, `SettingsCategory`, or `settingsList` (D-06a — those stay byte-identical).
/// Phase 6 (06-02, D-06/D-08): `.backupRestore` is removed (the backup/restore surface is gone from
/// narrow `main`); `.privacyData` STAYS — it routes to the trimmed, erase-only `PrivacyDataView`.
/// Phase 7 (07-04, FEAT-04, D-05, SAFETY): `.childMode` is removed — `ChildModeView.swift` is deleted.
/// Phase 8 (08-01, LOCK-01): `.mode` is removed — `ModeSettingsView`/`ModeOnboardingView` are deleted;
/// `appMode` is force-set `.advanced`.
/// Phase 8 (08-01, LOCK-03): `.dataHistory` is removed — `DataHistoryView.swift` is deleted;
/// `historyRetentionDays` is force-set to the 24h pin and actually applied via `App.swift`.
enum SettingsSidebarItem: Hashable {
    case category(SettingsCategory)
    case safety
    case privacyData

    /// The canonical set of non-category rows `sidebarList`'s second section renders — single source
    /// of truth cross-checked against `SettingsExtraIndex.entries` by `SettingsSidebarParityTests` so
    /// the two can never silently drift apart.
    static let allExtras: [SettingsSidebarItem] = [.safety, .privacyData]
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
        // Phase 8 (08-01, LOCK-01): the "Mode: Simple / Standard / Advanced" entry is removed —
        // `ModeSettingsView`/`ModeOnboardingView` are deleted; `appMode` is force-set `.advanced`.
        .init(title: "Read-only mode", keywords: "safe viewer caregiver backup phone bolusing disabled pump control hidden clearing alerts", item: .safety),
        // Phase 8 (08-01, LOCK-03): the "Data & history" entry is removed — `DataHistoryView.swift` is
        // deleted; `historyRetentionDays` is force-set to the 24h pin and actually applied at launch.
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
            // Phase 8 (08-01, LOCK-04/LOCK-06 friction half): the "Extended (combo) bolus" toggle and
            // the "Extra confirmation on unusually large overrides" toggle are both removed from this
            // Section (they shared one footer) — `extendedBolusEnabled`/`stackingGuardFrictionEnabled`
            // are now force-set-false init pins. The Section stays — it still hosts the reasoning
            // toggle — and the footer is trimmed to describe only Reasoning.
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
            // Phase 8 (08-01, LOCK-02): the whole "Glucose unit" Section (the mg/dL·mmol/L Picker + the
            // "Show unit labels" toggle — its only two rows) is removed — `glucoseDisplayUnit` is now a
            // force-set `.mgdl` init pin with no UI to change it; `showGlucoseUnitLabels` survives as an
            // ordinary hidden/unregistered flag. The `Chart` Section below still READS
            // `settings.glucoseDisplayUnit` (for `GlucosePlotScale.boundLabel`) — that read is
            // unaffected, it always resolves to `.mgdl` now.
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
            // Phase 8 (08-01, LOCK-05): the pump-clock Section (toggle + "Sync pump time now" button) is
            // removed — `autoSyncPumpTime` is force-set OFF in `AppSettings.init` and no UI can turn it
            // back on. `TandemBackend.syncTimeToNow()` / `GatedPumpWrite.syncTimeToNow` stay
            // byte-identical (D-07); see `ClockSyncHiddenBoundaryTests` for the headless proof.
            // Phase 9 (09-02, MOBI-02): the "Advanced control" Section (the opt-in toggle + its
            // `NavigationLink { PumpControlView(model: model) }` destination) is removed — narrow
            // `main` is bolus + status + alerts only. Both operands of the old entry gate
            // (`model.capabilities.supportsAnyAdvancedControl || settings.advancedControlEnabled`)
            // are always false on the t:slim-only capability model (`.full` floors every advanced
            // capability OFF, Models.swift:762-785), so this Section could never actually be reached
            // with a live "Pump Control" destination on this build anyway — removing it deletes dead
            // reachability, not a live feature. Removing the Toggle removes `advancedControlEnabled`'s
            // ONLY UI writer (the LOCK-01 "pin at the sole writer" pattern, Phase 8 precedent): the
            // persisted value can never be flipped back to true from this build again. The accessor
            // itself stays in `AppSettings.swift` (unedited, D-08) — `AppModel.swift` (DOSE_PATHS,
            // protected) still reads it at `advancedControlOptIn`/`advancedControlAllowed`, and
            // `advancedControlAllowed` is ALREADY always-false via its OTHER operand
            // (`capabilities.supportsAnyAdvancedControl`), so no force-reset migration is needed
            // (RESEARCH Anti-Patterns) — this mirrors `showGlucoseUnitLabels`'s "ordinary hidden/
            // unregistered flag" posture, not `autoSyncPumpTime`'s force-set-false pin.
            // `PumpControlView.swift` (its sole destination) is deleted wholesale (Task 1) — every
            // section inside it was ALSO gated by a `caps.supportsX` capability that is always false
            // on this model, so nothing in that file was reachable regardless of this Section.
            // Phase 7 (07-03, FEAT-05, D-08): the mode-automation Settings Section (5 toggles + a
            // link to the now-deleted help View) is removed — its whole reason to exist was configuring
            // the Siri/Shortcuts automations this phase deletes. autoTempRate/autoProfileActivation
            // (only readers were the deleted TempRateAutomation/ProfileAutomation engines) are fully
            // deleted from AppSettings.swift below. autoExerciseMode/autoSleepMode/modeReminders are
            // FROZEN at their existing default `false` — the kept ModeAutomation.swift still reads
            // them (AppModel.swift:1821,2115, DOSE_PATHS).
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
        // Phase 9 Plan 01 (MOBI-01/MOBI-03, D-03): reject-at-pairing observer — same shared helper as
        // MainHUDView's trigger (`ios/faBolus/Data/AppModel+MobiReject.swift`), anchored at
        // PumpSettingsView's root so it OUTLIVES the transient `PairingSheet` presented above.
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
    // §2.3 (G5): the one-time warning shown the FIRST time Garmin bolusing is enabled. (The
    // matching Apple-Watch warning state was removed in 03-03, REMOTE-03, and the Apple-Watch
    // bolus-enable accessor itself is retired entirely in Phase 17.5, D1-01 — see the note below.)
    @State private var showGarminBolusWarning = false
    // C2 §2.3: the OPTIONAL Garmin bolus passcode set-UI. `passcodeSet` mirrors the Keychain-backed
    // `BolusPasscodeStore.isRequired` (refreshed on appear + after every set/clear) so the section shows
    // the right state without making the store observable.
    @State private var showSetPasscode = false
    @State private var passcodeSet = false
    // Phase 7 (07-03, FEAT-05, D-08): the `siriPhrases` list + the Section that rendered it below are
    // removed — they described the read-only voice queries that the now-deleted Intents surface
    // registered; with that registration gone, the phrases no longer do anything (a Rule 1/2 dangling
    // reference to removed functionality, not in RESEARCH's file list — found via a systematic grep
    // for "Siri"/"Shortcuts"/"automation" across ios/faBolus).

    /// §2.3: turning an enable ON routes through the one-time warning on first use (Confirm arms it +
    /// records the ack; Cancel leaves it off — the binding's `get` reads the real, still-false flag so the
    /// switch snaps back). A subsequent turn-on (already acknowledged, or after turning it off) arms
    /// directly. Turning OFF is always immediate. Routed through the shared `guardedToggle` factory
    /// (09.3-01, D-05/SC3) — the one idiom every confirm-gated settings toggle uses.
    ///
    /// Phase 3 (03-03, REMOTE-03) removed the matching Apple-Watch equivalent binding and its
    /// `SettingsCatalog` row + backup/restore participation + UI (hidden-flag pattern, same posture as
    /// `requireRemoteBolusApproval`, 03-02/F-1). Phase 17.5 (D1-01) then retired the underlying
    /// AppSettings accessor and the gate that read it entirely — there is no Apple-Watch equivalent
    /// left to bind at all now.
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

    /// D1-10: one plain-language line summarizing the NET effect of the toggles below, purely computed
    /// from their current values — no new persisted state, no change to what any toggle means or does.
    /// Exists only to reduce the "which of these several switches decides whether Garmin can bolus?"
    /// mental-model load the audit flagged; every toggle below is still shown, explicit, and independently
    /// changeable exactly as before.
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
            // D1-10 consolidation: the three "is Garmin allowed to bolus?" controls (read-only override,
            // the enable, the optional per-dose ceiling) plus the optional passcode were previously split
            // across TWO sections with the override listed LAST — reading order didn't match the actual
            // precedence. Folded into ONE section, override listed FIRST (it wins over everything below
            // it), with a plain-language status line up top. Every persisted key below (`remotesReadOnly`,
            // `garminBolusEnabled`, `remoteBolusCeiling`, the Keychain-backed passcode) keeps its exact
            // existing meaning, default, and binding — this is presentation/grouping/labeling only; the
            // evaluator (`AccessPolicy.swift`) is untouched. See 17-09-SUMMARY.md's control map.
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
                    // C2 §2.3: the OPTIONAL Garmin bolus passcode, folded into this ONE section (D1-10)
                    // instead of a second overlapping section — same visibility gate
                    // (`garminBolusEnabled`), same bindings, same Keychain-backed store; only the section
                    // grouping changed.
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
                // Phase 09.13-02 (D-05): optional small-screen plot Y-axis override — one Picker whose
                // first row IS "Same as phone" (no separate boolean toggle); the two dependent Pickers
                // below only appear once "Custom" is selected, mirroring the remoteBolusCeiling reveal.
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
            } header: { Text("Garmin display") } footer: {
                Text("Customize the Garmin Details page and the history-chart tap ranges — separate from the phone. \"Garmin plot range\" lets the small screens use a different glucose-chart range than the phone; \"Same as phone\" (default) keeps them matched. Mirrored to the remotes on the next update.")
            }
            if let g = model.garminStatus {
                Section { Text(g).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Remotes & devices")
        // C2 §2.3: keep the passcode section's state in sync with the Keychain-backed store.
        .onAppear { passcodeSet = BolusPasscodeStore.isRequired }
        .sheet(isPresented: $showSetPasscode) {
            // CX-F-10: honor setPasscode's Bool return — a Keychain upsert failure must surface as a
            // failure (BolusPasscodeEntryView keeps the sheet open with an error), NOT be reported as a
            // successful change. `passcodeSet` is only refreshed when the store confirms it actually wrote.
            BolusPasscodeEntryView { code in
                let ok = BolusPasscodeStore.setPasscode(code)
                if ok { passcodeSet = BolusPasscodeStore.isRequired }
                return ok
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
/// A double-entry-to-confirm flow like the now-removed `PinEntryView`'s `.set` mode (Phase 7, 07-04,
/// FEAT-04, D-05; preserved on `dev/child-mode`) but fixed at exactly 4 digits
/// (`BolusPasscodeStore.isValidFormat`), with its own independent store.
struct BolusPasscodeEntryView: View {
    /// The validated 4-digit code to store. Returns whether it was actually stored — CX-F-10: a Keychain
    /// upsert failure must be surfaced here rather than assumed to have succeeded, so `submit()` can keep
    /// the sheet open with an error instead of dismissing as if the passcode had changed.
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
        // CX-F-10: honor the store's Bool return — a failed save keeps the sheet open with an error
        // instead of dismissing as if the passcode had changed.
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
                    // existing static empty-list rows (PumpWizardViews; the custom alert-rules editor
                    // this comment used to cite as a second precedent is removed, Phase 7, 07-05, FEAT-08).
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
                Text("Tapping the Garmin history chart cycles through the enabled ranges. At least one must stay enabled.")
            }
        }
        .navigationTitle("Garmin Chart Ranges")
    }
}
