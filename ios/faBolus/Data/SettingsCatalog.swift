import Foundation
import faBolusCore

/// P14 Slice 1 — the single source of truth for every persisted `AppSettings` key.
///
/// Today the 48 keys are enumerated across four hand-maintained lists (`AppSettings.init` defaults,
/// `backupSnapshot()`, `applyBackup()`, and `SettingsView.SettingsIndex.entries`) that drift
/// independently, and the mode system would have added a fifth (per-mode membership). This catalog folds
/// the metadata for all of them into one table: which keys exist, their editability `tier`, the `modes`
/// they appear in, whether they `backsUp`, and whether they `syncsToICloud`.
///
/// **Slice-1 scope is deliberately data + binding, not a mechanical rewrite of the four lists.** A faithful
/// read of `AppSettings.init` shows property observers do *not* fire during `init`, so `UserDefaults` and
/// the live property legitimately diverge for the logic-bearing keys (the `bolusIncrement` 0.05 legacy
/// clamp `AppSettings.swift:294`, the `watchDefaultBolusMode` fallback `:289`). A generic
/// `UserDefaults`-driven derivation of `backupSnapshot()` would therefore NOT be byte-equivalent and would
/// silently change backup behavior in those edge cases — unacceptable on a safety-adjacent path. So the
/// catalog is made *authoritative* and the existing typed lists are **pinned to it by drift-guard tests**
/// (`SettingsCatalogTests`), the same mirror-plus-guard idiom used for `PumpControlBounds` and
/// `WidgetGlucoseThresholds`. No runtime value changes in this slice; enforcement (mode gating) lands in S2.
///
/// The `tier` / `modes` fields are the exact data the P8 evaluator's `ModeGateContext` consumes in S2.
struct SettingDescriptor: Identifiable {
    /// The exact UserDefaults key literal. Frozen — renaming breaks on-disk backups and the iCloud blob's
    /// inner keys.
    let key: String
    /// Which Settings screen category owns the control (reuses `SettingsCategory`).
    let category: SettingsCategory
    /// Editability tier. All 48 current keys are `.user` app preferences; `.clinician`/`.fixed` are
    /// reserved for the pump-therapy descriptors S6–S8 add.
    let tier: SettingTier
    /// The modes in which this setting is shown. `.advanced` sees everything, so it is always a member.
    let modes: Set<AppMode>
    /// True iff the key participates in the portable settings backup (`backupSnapshot`/`applyBackup`).
    let backsUp: Bool
    /// True iff the key rides the iCloud KV settings sync (S5). Invariant: implies `backsUp` (iCloud only
    /// syncs `SettingsBackup.appSettingsSnapshot()`), and is forced **false** for the command-adjacent
    /// flags so settings sync can never carry a safety/command decision to another device (C5).
    let syncsToICloud: Bool
    /// Optional search metadata. Populated `nil` in S1 — the `SettingsIndex` fold is deferred to a later
    /// slice because its rows are category-grouped, not 1:1 with keys, and need a curated overlay (C4).
    let searchTitle: String?
    let searchKeywords: String?

    var id: String { key }

    init(_ key: String, _ category: SettingsCategory, tier: SettingTier = .user,
         from minMode: AppMode, backsUp: Bool, syncsToICloud: Bool? = nil,
         searchTitle: String? = nil, searchKeywords: String? = nil) {
        self.key = key
        self.category = category
        self.tier = tier
        self.modes = Set(AppMode.allCases.filter { $0 >= minMode })
        self.backsUp = backsUp
        // Default: a backed-up key syncs. The five command-adjacent flags pass `false` explicitly.
        self.syncsToICloud = (syncsToICloud ?? backsUp) && backsUp
        self.searchTitle = searchTitle
        self.searchKeywords = searchKeywords
    }

    /// Whether this setting is shown in the given mode.
    func isVisible(in mode: AppMode) -> Bool { modes.contains(mode) }
}

enum SettingsCatalog {
    /// The five command-adjacent flags that must never ride iCloud settings sync — a synced value could
    /// otherwise flip a safety/command decision on another device (C5 / iPhone-only-writes). Named here so
    /// the invariant is greppable and test-anchored, not implicit in the table below.
    static let commandAdjacentFlags: Set<String> = [
        "advancedControlEnabled",
        "phoneReadOnly",
        "remotesReadOnly",
        "requireRemoteBolusApproval",
        "childModeEnabled",
        // §2.3 per-surface bolus-auth enables — a synced "bolusing on" must never arm a remote on another
        // device.
        "garminBolusEnabled",
        "watchBolusEnabled",
        // §2.3 remote-only dose ceiling — a synced value must never silently RELAX the cap on another device
        // (the same C5 hazard as the enables; not a boolean, but the same never-iCloud-sync rule applies).
        "remoteBolusCeiling",
    ]

    /// All 45 persisted `AppSettings` keys. Order mirrors `AppSettings.swift` for reviewability.
    /// `notificationTelemetryEnabled` is intentionally absent — it is App-Group-backed (not in `d`) and
    /// not part of this settings surface (`AppSettings.swift:148`).
    static let descriptors: [SettingDescriptor] = [
        // MARK: Bolus & entry
        .init("defaultBolusMode", .bolus, from: .simple, backsUp: true),
        .init("bolusIncrement", .bolus, from: .simple, backsUp: true),
        .init("carbIncrement", .bolus, from: .simple, backsUp: true),
        .init("extendedBolusEnabled", .bolus, from: .advanced, backsUp: true),
        .init("showBolusReasoning", .bolus, from: .standard, backsUp: true),
        // Insulin Stacking Guard SG3a escalating-friction disable (task #93). .user tier, Simple minimum
        // mode — a Simple bolus toggle exactly like the other rows in this section.
        .init("stackingGuardFrictionEnabled", .bolus, from: .simple, backsUp: true),
        // MARK: Watch / Garmin entry (remotes)
        .init("watchDefaultBolusMode", .remotes, from: .standard, backsUp: true),
        .init("watchBolusIncrement", .remotes, from: .standard, backsUp: true),
        .init("watchCarbIncrement", .remotes, from: .standard, backsUp: true),
        // MARK: Display & chart
        .init("showGlucoseAxis", .display, from: .standard, backsUp: true),
        .init("showIOBAxis", .display, from: .standard, backsUp: true),
        .init("showBolusBars", .display, from: .standard, backsUp: true),
        .init("showStats", .display, from: .standard, backsUp: true),
        .init("detailsOrder", .display, from: .standard, backsUp: true),
        .init("pillsOrder", .display, from: .standard, backsUp: true),
        // MARK: Watch/Garmin display (remotes)
        .init("watchDetailsOrder", .remotes, from: .standard, backsUp: true),
        .init("watchChartRanges", .remotes, from: .standard, backsUp: true),
        // MARK: CGM & freshness
        .init("glucoseStaleMinutes", .cgm, from: .standard, backsUp: true),
        .init("glucoseHideDelayMinutes", .cgm, from: .standard, backsUp: true),
        // MARK: Pump & control
        .init("advancedControlEnabled", .pump, from: .advanced, backsUp: true, syncsToICloud: false),
        .init("autoSyncPumpTime", .pump, from: .advanced, backsUp: true),
        // §8 L3 = Standard. Auto exercise/sleep + reminders are a SHIPPED Standard feature; leaving them at
        // .advanced would silently drop them out of Standard once Simple-default (P14 S3) lands (E6 G1).
        .init("autoExerciseMode", .pump, from: .standard, backsUp: true),
        .init("autoSleepMode", .pump, from: .standard, backsUp: true),
        .init("modeReminders", .pump, from: .standard, backsUp: true),
        .init("phoneReadOnly", .pump, from: .standard, backsUp: true, syncsToICloud: false),
        .init("readOnlyAllowAlertClear", .pump, from: .advanced, backsUp: true),
        // MARK: Remotes & devices
        .init("remotesReadOnly", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("garminBolusEnabled", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("watchBolusEnabled", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        // §2.3 optional remote-only per-bolus ceiling. Command-adjacent (never iCloud-synced); backs up.
        .init("remoteBolusCeiling", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        // §8 N7 = Standard. Caregiver remote over BT + reverse-approval are a SHIPPED Standard feature;
        // leaving them at .advanced would silently drop them out of Standard once Simple-default lands (E6 G2).
        .init("remoteBluetoothEnabled", .remotes, from: .standard, backsUp: true),
        .init("requireRemoteBolusApproval", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("childModeEnabled", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("childAllowed", .remotes, from: .standard, backsUp: true),
        .init("garminScreenOrder", .remotes, from: .standard, backsUp: true),
        .init("garminDefaultScreen", .remotes, from: .standard, backsUp: true),
        .init("garminComplicationDisplay", .remotes, from: .standard, backsUp: true),
        .init("garminClockAnalog", .remotes, from: .standard, backsUp: true),
        .init("garminTargetApp", .remotes, from: .advanced, backsUp: true),
        // MARK: Alerts
        .init("alertRules", .alerts, from: .advanced, backsUp: true),
        // MARK: CGM upload (off-device, opt-in)
        .init("nightscoutUploadEnabled", .cgm, from: .advanced, backsUp: true),

        // MARK: — Not backed up (caches + advisory/experimental toggles). syncsToICloud false by rule.
        .init("historyRetentionDays", .about, from: .advanced, backsUp: false),
        .init("eatingNudgesEnabled", .bolus, from: .advanced, backsUp: false),
        .init("eatingTriggerConfig", .bolus, from: .advanced, backsUp: false),
        .init("eatingLearnFromFeedback", .bolus, from: .advanced, backsUp: false),
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
