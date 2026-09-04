import Foundation
import faBolusCore

/// Source of truth for every persisted `AppSettings` key: category, editability, backup, iCloud sync.
/// Catalog is authoritative; the typed lists are pinned to it by `SettingsCatalogTests`. A generic
/// UserDefaults-driven backup would skip `init` observers (e.g. bolusIncrement clamp) and change
/// backup behavior — unacceptable on a safety-adjacent path.
struct SettingDescriptor: Identifiable {
    /// The exact UserDefaults key literal. Frozen — renaming breaks on-disk backups and the iCloud blob's
    /// inner keys.
    let key: String
    /// Which Settings screen category owns the control (reuses `SettingsCategory`).
    let category: SettingsCategory
    /// Editability tier. Current keys are `.user` app preferences; `.clinician`/`.fixed` are reserved.
    let tier: SettingTier
    /// The modes in which this setting is shown. `.advanced` sees everything, so it is always a member.
    let modes: Set<AppMode>
    /// True iff the key is considered part of the durable settings surface (vs. a cache/derived value).
    let backsUp: Bool
    /// True iff the key rides iCloud KV settings sync. Invariant: implies `backsUp`, and is forced
    /// **false** for command-adjacent flags so settings sync can never carry a safety/command
    /// decision to another device.
    let syncsToICloud: Bool
    /// Optional search metadata. `nil` here — `SettingsIndex` rows are category-grouped, not 1:1 with keys.
    let searchTitle: String?
    let searchKeywords: String?

    var id: String { key }

    init(
        _ key: String, _ category: SettingsCategory, tier: SettingTier = .user,
        from minMode: AppMode, backsUp: Bool, syncsToICloud: Bool? = nil,
        searchTitle: String? = nil, searchKeywords: String? = nil
    ) {
        self.key = key
        self.category = category
        self.tier = tier
        self.modes = Set(AppMode.allCases.filter { $0 >= minMode })
        self.backsUp = backsUp
        // Default: a backed-up key syncs. Command-adjacent flags pass `false` explicitly.
        self.syncsToICloud = (syncsToICloud ?? backsUp) && backsUp
        self.searchTitle = searchTitle
        self.searchKeywords = searchKeywords
    }

    /// Whether this setting is shown in the given mode.
    func isVisible(in mode: AppMode) -> Bool { modes.contains(mode) }
}

enum SettingsCatalog {
    /// Command-adjacent flags that must never ride iCloud settings sync — a synced value could
    /// otherwise flip a safety/command decision on another device.
    static let commandAdjacentFlags: Set<String> = [
        "phoneReadOnly",
        "remotesReadOnly",
        // Per-surface bolus-auth enables — a synced "bolusing on" must never arm a remote on another device.
        "garminBolusEnabled",
        // Remote-only dose ceiling — a synced value must never silently relax the cap on another device.
        "remoteBolusCeiling"
    ]

    /// Persisted `AppSettings` keys. See `SettingsCatalogTests` for the current count.
    /// Order mirrors `AppSettings.swift`. `notificationTelemetryEnabled` is App-Group-backed (not in
    /// `d`) and is intentionally absent.
    static let descriptors: [SettingDescriptor] = [
        // MARK: Bolus & entry
        .init("defaultBolusMode", .bolus, from: .simple, backsUp: true),
        .init("bolusIncrement", .bolus, from: .simple, backsUp: true),
        .init("carbIncrement", .bolus, from: .simple, backsUp: true),
        .init("showBolusReasoning", .bolus, from: .standard, backsUp: true),
        // MARK: Watch / Garmin entry (remotes)
        .init("watchDefaultBolusMode", .remotes, from: .standard, backsUp: true),
        .init("watchBolusIncrement", .remotes, from: .standard, backsUp: true),
        .init("watchCarbIncrement", .remotes, from: .standard, backsUp: true),
        // MARK: Display & chart
        .init("showGlucoseAxis", .display, from: .standard, backsUp: true),
        .init("showIOBAxis", .display, from: .standard, backsUp: true),
        .init("showBolusBars", .display, from: .standard, backsUp: true),
        // Glucose plot Y-axis presets — display preference, not command-adjacent; iCloud sync ON.
        .init("glucosePlotFloor", .display, from: .standard, backsUp: true),
        .init("glucosePlotCeiling", .display, from: .standard, backsUp: true),
        .init("showStats", .display, from: .standard, backsUp: true),
        .init("detailsOrder", .display, from: .standard, backsUp: true),
        .init("pillsOrder", .display, from: .standard, backsUp: true),
        // MARK: Watch/Garmin display (remotes)
        .init("watchDetailsOrder", .remotes, from: .standard, backsUp: true),
        .init("watchChartRanges", .remotes, from: .standard, backsUp: true),
        // Optional Watch/Garmin plot Y-axis override — display preference, default iCloud sync ON.
        .init("glucosePlotFloorSmall", .remotes, from: .standard, backsUp: true),
        .init("glucosePlotCeilingSmall", .remotes, from: .standard, backsUp: true),
        // MARK: CGM & freshness
        .init("glucoseStaleMinutes", .cgm, from: .standard, backsUp: true),
        .init("glucoseHideDelayMinutes", .cgm, from: .standard, backsUp: true),
        // MARK: Pump & control
        .init("phoneReadOnly", .pump, from: .standard, backsUp: true, syncsToICloud: false),
        .init("readOnlyAllowAlertClear", .pump, from: .advanced, backsUp: true),
        // MARK: Remotes & devices
        .init("remotesReadOnly", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("garminBolusEnabled", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        // Optional remote-only per-bolus ceiling. Command-adjacent (never iCloud-synced); backs up.
        .init("remoteBolusCeiling", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("garminScreenOrder", .remotes, from: .standard, backsUp: true),
        .init("garminDefaultScreen", .remotes, from: .standard, backsUp: true),
        .init("garminComplicationDisplay", .remotes, from: .standard, backsUp: true),
        .init("garminClockAnalog", .remotes, from: .standard, backsUp: true),
        .init("garminTargetApp", .remotes, from: .advanced, backsUp: true),
        .init("garminAlertIntensityMode", .remotes, from: .standard, backsUp: true),
        .init("garminAlertAudibleMinSeverity", .remotes, from: .standard, backsUp: true),
        .init("garminAlertCriticalOverridesDnd", .remotes, from: .standard, backsUp: true),
        .init("garminComplicationSlots", .remotes, from: .standard, backsUp: true)

        // MARK: — Not backed up (caches + advisory/experimental toggles). syncsToICloud false by rule.
        // `historyCoverage` is deliberately NOT registered — no UI surface (pure sync bookkeeping).
        // Adding it would fail `SettingsReachabilityGuardTests` (every non-exempt catalog key needs
        // a literal UI reference).
    ]

    /// Lookup by key.
    static let byKey: [String: SettingDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })

    /// Keys that ride iCloud settings sync (the S5 filter's input).
    static var iCloudSyncedKeys: Set<String> {
        Set(descriptors.filter { $0.syncsToICloud }.map { $0.key })
    }

    /// Keys included in the portable settings backup.
    static var backedUpKeys: Set<String> {
        Set(descriptors.filter { $0.backsUp }.map { $0.key })
    }
}
