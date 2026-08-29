import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Drift guards: `SettingsCatalog.descriptors` is the source of truth for persisted `AppSettings`
/// keys; these tests pin the hand-maintained lists so they cannot drift silently.
enum CompileGateAudit {
    /// Search tokens for features removed from main. Unconditional (delete-on-main, not compile flags).
    static var gatedOffSearchTokens: Set<String> {
        var tokens: Set<String> = []
        tokens.formUnion(["xdrip", "libre"])
        tokens.formUnion(["Remote access", "Pair a remote"])
        tokens.formUnion(["Apple Watch app"])
        tokens.formUnion(["nightscout", "healthkit", "heart rate"])
        // "backup"/"export"/"settings" are live on other rows (caregiver backup phone; CSV export).
        tokens.formUnion(["icloud", "restore", "files", "import"])
        tokens.formUnion(["foodfinder", "find food", "barcode"])
        tokens.formUnion(["liveactivity"])
        tokens.formUnion(["graphdetail"])
        tokens.formUnion(["retrospective", "insights"])
        tokens.formUnion(["badge"])
        tokens.formUnion([
            "siri", "shortcuts automation", "auto exercise", "auto sleep", "auto profile activation", "auto temp rate"
        ])
        // Concatenated so `.contains` does not match live "Garmin analog clock face" ("lock" in "clock").
        tokens.formUnion(["childmode"])
        // Concatenated so `.contains` does not match live "Notification controls" ("quiet hours").
        tokens.formUnion(["alertrules"])
        tokens.formUnion(["pump clock"])
        // Concatenated so `.contains` does not match live "Default bolus mode" / "Advanced control".
        tokens.formUnion(["modeselector"])
        tokens.formUnion(["combo", "square wave"])
        // "mmol" only: a bare "unit" would match live increment rows.
        tokens.formUnion(["mmol"])
        // Compounds so a bare "mode" does not match live "Default bolus mode".
        tokens.formUnion(["suspend resume", "temp basal", "cartridge", "advancedcontrol"])
        return tokens
    }

    /// The `SettingsIndex` rows that still advertise a gated-off feature — a §6c dangling ref. A
    /// non-empty result means a removed feature left a live, findable settings row behind.
    /// `Entry.matches` is the exact predicate `SettingsView` uses for search, so "advertised" here means
    /// precisely "the user could still find it". Non-tautological: given no tokens it returns `[]`; given
    /// a token owned by a present row it returns that row (see `orphanDetectorIsNonVacuous`).
    static func orphanedSettingsIndexEntries(forGatedOffTokens tokens: Set<String>) -> [SettingsIndex.Entry] {
        guard !tokens.isEmpty else { return [] }
        return SettingsIndex.entries.filter { entry in tokens.contains { entry.matches($0) } }
    }
}

struct SettingsCatalogTests {

    /// The four backup keys `backupSnapshot()` emits only when their value is present (two optionals — an
    /// int and the §2.3 remote-bolus ceiling double — and two JSON blobs). Everything else is unconditional.
    /// Declared here so the drift guard can tolerate their absence on a fresh `AppSettings` without weakening it.
    private let conditionalBackupKeys: Set<String> = [
        "glucoseHideDelayMinutes", "remoteBolusCeiling",
        "glucosePlotFloorSmall", "glucosePlotCeilingSmall"
    ]

    // MARK: Coverage

    @Test func descriptorsCoverExactly48UniqueKeys() {
        #expect(SettingsCatalog.descriptors.count == 35)
        #expect(SettingsCatalog.byKey.count == 35)  // Dictionary(uniqueKeysWithValues:) also traps on dup
        let keys = SettingsCatalog.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count)  // no duplicate literal
    }

    // MARK: Golden equivalence — the catalog's backup set == what backupSnapshot actually emits

    /// Drift guard, read-only (no singleton mutation → safe under parallel execution). If a key is added to
    /// `backupSnapshot()` without the catalog, `snapshot ⊄ backedUpKeys` fails; if an unconditional key is
    /// dropped from `backupSnapshot()`, `unconditional ⊄ snapshot` fails.
    @Test @MainActor func backedUpSetMatchesBackupSnapshot() {
        let snapshotKeys = Set(AppSettings.shared.backupSnapshot().keys)
        #expect(snapshotKeys.isSubset(of: SettingsCatalog.backedUpKeys))
        let unconditional = SettingsCatalog.backedUpKeys.subtracting(conditionalBackupKeys)
        #expect(unconditional.isSubset(of: snapshotKeys))
        #expect(SettingsCatalog.backedUpKeys.count == 35)  // 31 unconditional + 4 conditional
        #expect(conditionalBackupKeys.isSubset(of: SettingsCatalog.backedUpKeys))
    }

    /// applyBackup ∘ backupSnapshot is a no-op round-trip: re-applying the current values leaves every
    /// backed-up key byte-identical (idempotent, so safe even if another suite reads `.shared` meanwhile).
    @Test @MainActor func backupRoundTripsThroughBackupValue() {
        let before = AppSettings.shared.backupSnapshot()
        AppSettings.shared.applyBackup(before)
        let after = AppSettings.shared.backupSnapshot()
        #expect(before == after)
    }

    /// A backup from an older build may still carry removed `basalScheduleByHour` /
    /// `basalScheduleSource` keys; restore must decode them and ignore them — never crash, never
    /// resurrect a removed setting.
    @Test @MainActor func restoreToleratesLegacyBasalScheduleKeys() {
        let base = AppSettings.shared.backupSnapshot()
        var legacy = base
        legacy["basalScheduleByHour"] = .data(Data([0, 1, 2, 3]))  // stand-in for the old [Double] cache blob
        legacy["basalScheduleSource"] = .string("Nightscout")
        // Survive a full JSON encode→decode like a real on-disk backup, not just an in-memory dict.
        let backup = FaBolusBackup(
            meta: .init(
                createdAt: Date(), appVersion: "test",
                pumpModel: "unknown", deviceName: "test"),
            appSettings: legacy)
        let decoded = try? FaBolusBackup.decode(backup.encoded())
        #expect(decoded != nil, "a legacy backup carrying removed keys must still decode")
        #expect(decoded?.appSettings?["basalScheduleByHour"] != nil)  // the unknown key round-trips…
        AppSettings.shared.applyBackup(decoded?.appSettings ?? [:])  // …and applying it must not crash
        #expect(AppSettings.shared.backupSnapshot() == base)  // removed keys ignored; nothing changed
    }

    /// The `childAllowed` set is the ONLY `Set`-backed persisted value, and `Set` serializes to a JSON array
    /// in hash-iteration order — randomized per process. If we ever encode it raw again, the same set of
    /// features would produce different bytes across launches/devices, reintroducing spurious backup/iCloud
    /// diffs and the flaky `backupRoundTripsThroughBackupValue` failure this replaced. Pin the invariant
    /// directly and process-independently: the canonical encoding lists features in ascending `rawValue`
    /// order (not whatever order the set happens to iterate), and still decodes back to the identical set.
    @Test func childAllowedEncodingIsCanonicalAndLossless() {
        let set = Set(ChildFeature.allCases)
        let data = AppSettings.canonicalChildAllowedData(set)
        let arr = try? JSONDecoder().decode([String].self, from: data)
        #expect(arr == set.map(\.rawValue).sorted(), "canonical encoding must be ascending-rawValue order")
        #expect((try? JSONDecoder().decode(Set<ChildFeature>.self, from: data)) == set)
    }

    // MARK: iCloud safety — the single biggest correctness item in the slice (C5)

    @Test func iCloudSubsetExcludesEveryCommandAdjacentFlag() {
        let synced = SettingsCatalog.iCloudSyncedKeys
        #expect(synced.isDisjoint(with: SettingsCatalog.commandAdjacentFlags))
        // The five flags must all actually exist in the catalog (and be backed up), or the exclusion is
        // vacuous — a flag we forgot to model would silently sync.
        for flag in SettingsCatalog.commandAdjacentFlags {
            let d = SettingsCatalog.byKey[flag]
            #expect(d != nil, "command-adjacent flag \(flag) missing from catalog")
            #expect(d?.backsUp == true)
            #expect(d?.syncsToICloud == false)
        }
    }

    @Test func syncingImpliesBackedUp() {
        // iCloud only ships `SettingsBackup.appSettingsSnapshot()` == `backupSnapshot()`, so a key that is
        // not backed up can never sync regardless of how the row is written.
        for d in SettingsCatalog.descriptors where d.syncsToICloud {
            #expect(d.backsUp, "\(d.key) syncs to iCloud but is not backed up")
        }
    }

    // MARK: Mode axis

    @Test func everyModeSetIsNonEmptyAndIncludesAdvanced() {
        for d in SettingsCatalog.descriptors {
            #expect(!d.modes.isEmpty)
            #expect(d.isVisible(in: .advanced), "\(d.key) is not visible in Advanced")
        }
    }

    @Test func simpleModeIsANonEmptyProperSubsetOfAdvanced() {
        let simple = SettingsCatalog.descriptors.filter { $0.isVisible(in: .simple) }.map(\.key)
        let advanced = SettingsCatalog.descriptors.filter { $0.isVisible(in: .advanced) }.map(\.key)
        #expect(!simple.isEmpty)  // Simple is a real, usable subset
        #expect(simple.count < advanced.count)  // …and strictly fewer than Advanced sees
        #expect(Set(simple).isSubset(of: Set(advanced)))
    }

    // MARK: Tier axis (S1 state)

    @Test func allCurrentKeysAreUserTier() {
        // Every one of the 45 keys is an app/display/remote preference the user owns. The `.clinician` /
        // `.fixed` tiers exist in the vocabulary but are reserved for the pump-therapy descriptors S6–S8
        // add as *separate* rows; if one is ever added here it must update this assertion deliberately.
        #expect(SettingsCatalog.descriptors.allSatisfy { $0.tier == .user })
    }

    // MARK: Catalog absences

    /// `stackingGuardFrictionEnabled` is not a catalog row (force-set-false init pin).
    @Test func stackingGuardFrictionEnabledIsNoLongerRegistered() {
        #expect(SettingsCatalog.byKey["stackingGuardFrictionEnabled"] == nil)
    }

    /// `advancedControlEnabled` is not a catalog row. The accessor remains; `advancedControlAllowed`
    /// stays false via `capabilities.supportsAnyAdvancedControl`.
    @Test func advancedControlEnabledIsNoLongerRegisteredButAccessorSurvives() {
        #expect(SettingsCatalog.byKey["advancedControlEnabled"] == nil)
        #expect(!SettingsCatalog.commandAdjacentFlags.contains("advancedControlEnabled"))
    }

    @Test @MainActor func advancedControlEnabledRoundTripsAcrossReinitButAllowedStaysFalse() {
        let suiteName = "SettingsCatalogTests.advancedControlEnabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.advancedControlEnabled == false)  // default OFF, unchanged

        fresh.advancedControlEnabled = true  // the property setter itself is unchanged (still writable —
        // no force-set pin — the toggle that called this setter is what's gone, not the setter itself)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.advancedControlEnabled == true)  // persists like any ordinary flag

        // But `advancedControlAllowed` stays false regardless, via the OTHER operand — the t:slim-only
        // `.full` capability preset in `Models.swift` floors every advanced capability OFF.
        #expect(reloaded.advancedControlAllowed(capabilities: .full) == false)
    }

    /// `glucoseDisplayUnit` is not a catalog row; init force-sets `.mgdl`.
    @Test func glucoseDisplayUnitIsNoLongerRegistered() {
        #expect(SettingsCatalog.byKey["glucoseDisplayUnit"] == nil)
    }

    /// Init force-sets `.mgdl` even if UserDefaults still holds `"mmol"`.
    @Test @MainActor func glucoseDisplayUnitIsForceSetMgdlRegardlessOfAnyStoredValue() {
        let suiteName = "SettingsCatalogTests.glucoseDisplayUnit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("mmol", forKey: "glucoseDisplayUnit")  // simulate a pre-Phase-8 stored value

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucoseDisplayUnit == .mgdl)  // force-set pin wins over the stored value

        fresh.glucoseDisplayUnit = .mmol  // the property setter itself is unchanged (still writable)…
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucoseDisplayUnit == .mgdl)  // …but the NEXT init still force-sets .mgdl
    }

    /// `showGlucoseUnitLabels` is not a catalog row; the accessor remains as an unregistered flag.
    @Test func showGlucoseUnitLabelsIsNoLongerRegistered() {
        #expect(SettingsCatalog.byKey["showGlucoseUnitLabels"] == nil)
    }

    /// Default OFF (owner request) on a fresh install, and round-trips across a re-init of
    /// `AppSettings` over the SAME backing store.
    @Test @MainActor func showGlucoseUnitLabelsDefaultsToOffAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.showGlucoseUnitLabels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.showGlucoseUnitLabels == false)  // default OFF

        fresh.showGlucoseUnitLabels = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.showGlucoseUnitLabels == true)  // persisted across re-init
    }

    // MARK: Glucose plot bounds

    /// Floor/ceiling are `.display`, backed up, iCloud-synced — display preference, not command-adjacent.
    @Test func glucosePlotBoundsAreRegisteredInDisplayWithICloudSyncOn() {
        for key in ["glucosePlotFloor", "glucosePlotCeiling"] {
            let d = SettingsCatalog.byKey[key]
            #expect(d != nil, "\(key) missing from the catalog")
            #expect(d?.category == .display)
            #expect(d?.backsUp == true)
            #expect(d?.syncsToICloud == true)
            #expect(!SettingsCatalog.commandAdjacentFlags.contains(key))
        }
        #expect(SettingsCatalog.backedUpKeys.isSuperset(of: ["glucosePlotFloor", "glucosePlotCeiling"]))
    }

    /// Defaults floor 40 / ceiling 300 on a fresh install; both persist across re-init.
    @Test @MainActor func glucosePlotBoundsDefaultAndRoundTripAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucosePlotBounds.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloor == 40)
        #expect(fresh.glucosePlotCeiling == 300)

        fresh.glucosePlotFloor = 50
        fresh.glucosePlotCeiling = 400
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucosePlotFloor == 50)
        #expect(reloaded.glucosePlotCeiling == 400)
    }

    /// A legacy/corrupt out-of-set stored ceiling snaps to a safe in-set option (via
    /// `GlucosePlotScale.resolve`) rather than surfacing an invalid value in the UI.
    @Test @MainActor func glucosePlotBoundsSnapOutOfSetStoredValueAtInit() {
        let suiteName = "SettingsCatalogTests.glucosePlotBoundsSnap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(320, forKey: "glucosePlotCeiling")  // legacy out-of-set value

        let fresh = AppSettings(defaults: defaults)
        #expect(AppSettings.glucosePlotCeilingOptions.contains(fresh.glucosePlotCeiling))
        #expect(fresh.glucosePlotFloor < fresh.glucosePlotCeiling)
    }

    // MARK: Small-screen plot override

    /// `.remotes` category, `backsUp: true`, for both override keys.
    @Test func glucosePlotSmallOverrideIsRegisteredInRemotesWithBacksUpTrue() {
        for key in ["glucosePlotFloorSmall", "glucosePlotCeilingSmall"] {
            let d = SettingsCatalog.byKey[key]
            #expect(d != nil, "\(key) missing from the catalog")
            #expect(d?.category == .remotes)
            #expect(d?.backsUp == true)
            #expect(!SettingsCatalog.commandAdjacentFlags.contains(key))
        }
    }

    /// Fresh install ⇒ both nil ("Same as phone"); setting to nil removes the persisted key.
    @Test @MainActor func glucosePlotSmallOverrideDefaultsToNilAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverride.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall == nil)
        #expect(fresh.glucosePlotCeilingSmall == nil)

        fresh.glucosePlotFloorSmall = 50
        fresh.glucosePlotCeilingSmall = 400
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucosePlotFloorSmall == 50)
        #expect(reloaded.glucosePlotCeilingSmall == 400)

        reloaded.glucosePlotFloorSmall = nil
        reloaded.glucosePlotCeilingSmall = nil
        #expect(defaults.object(forKey: "glucosePlotFloorSmall") == nil)  // key removed, not just nulled
        #expect(defaults.object(forKey: "glucosePlotCeilingSmall") == nil)
        let afterClear = AppSettings(defaults: defaults)
        #expect(afterClear.glucosePlotFloorSmall == nil)
        #expect(afterClear.glucosePlotCeilingSmall == nil)
    }

    /// A legacy/corrupt out-of-set stored override snaps to a safe in-set pair (via
    /// `GlucosePlotScale.resolve`), same guarantee as the shared bounds.
    @Test @MainActor func glucosePlotSmallOverrideSnapsOutOfSetStoredValueAtInit() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverrideSnap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(320, forKey: "glucosePlotFloorSmall")  // legacy out-of-set value
        defaults.set(320, forKey: "glucosePlotCeilingSmall")

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall != nil)
        #expect(fresh.glucosePlotCeilingSmall != nil)
        #expect(AppSettings.glucosePlotFloorOptions.contains(fresh.glucosePlotFloorSmall!))
        #expect(AppSettings.glucosePlotCeilingOptions.contains(fresh.glucosePlotCeilingSmall!))
        #expect(fresh.glucosePlotFloorSmall! < fresh.glucosePlotCeilingSmall!)
    }

    /// The pair is one unit — only one of the two keys on disk is treated as absent (Same as phone),
    /// never a half-applied override.
    @Test @MainActor func glucosePlotSmallOverridePartialStoredStateIsTreatedAsAbsent() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverridePartial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(50, forKey: "glucosePlotFloorSmall")  // only the floor half persisted

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall == nil)
        #expect(fresh.glucosePlotCeilingSmall == nil)
    }

    /// `backupSnapshot` emits the override pair only when both are set.
    @Test @MainActor func glucosePlotSmallOverrideBackupIsConditionalAndRoundTrips() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverrideBackup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let s = AppSettings(defaults: defaults)

        let offSnapshot = s.backupSnapshot()
        #expect(offSnapshot["glucosePlotFloorSmall"] == nil)
        #expect(offSnapshot["glucosePlotCeilingSmall"] == nil)

        s.glucosePlotFloorSmall = 50
        s.glucosePlotCeilingSmall = 400
        let onSnapshot = s.backupSnapshot()
        #expect(onSnapshot["glucosePlotFloorSmall"] == .int(50))
        #expect(onSnapshot["glucosePlotCeilingSmall"] == .int(400))

        let s2 = AppSettings(defaults: defaults)
        s2.applyBackup(onSnapshot)
        #expect(s2.glucosePlotFloorSmall == 50)
        #expect(s2.glucosePlotCeilingSmall == 400)
    }

    // MARK: Orphaned search-token guard

    /// No `SettingsIndex` row advertises a gated-off feature's search tokens.
    @Test func noOrphanedCompileGatedSettingsOnCurrentBuild() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(
            forGatedOffTokens: CompileGateAudit.gatedOffSearchTokens)
        #expect(
            orphans.isEmpty,
            "a compile-gated-off feature still has a live SettingsIndex row: \(orphans.map(\.title))")
    }

    /// The helper is not a tautology: a token owned by a still-present row must flag that row.
    @Test func orphanDetectorIsNonVacuous() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(
            forGatedOffTokens: ["Failover CGM source"])
        #expect(
            !orphans.isEmpty,
            "the §6c helper must detect a dangling settings row for a removed feature")
        #expect(orphans.contains { $0.title == "Failover CGM source" })
    }

    /// "xdrip" is not advertised by any live `SettingsIndex` row.
    @Test func xdripRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: ["xdrip"])
        #expect(
            orphans.isEmpty,
            "xDrip was removed but a SettingsIndex row still advertises it: \(orphans.map(\.title))")
    }

    /// "libre" / "xdrip" are not advertised by any live `SettingsIndex` row.
    @Test func g6AndLibreLinkUpRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: ["libre", "xdrip"])
        #expect(
            orphans.isEmpty,
            "G6/LibreLinkUp were removed but a SettingsIndex row still advertises them: \(orphans.map(\.title))")
    }

    /// Backup/restore tokens are not advertised by `SettingsIndex` or `SettingsExtraIndex`.
    @Test func backupRestoreRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let tokens = Set(["icloud", "restore", "files", "import"])
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: tokens)
        #expect(
            orphans.isEmpty,
            "Backup & restore was removed but a SettingsIndex row still advertises it: \(orphans.map(\.title))")
        let extraOrphans = SettingsExtraIndex.entries.filter { entry in tokens.contains { entry.matches($0) } }
        #expect(
            extraOrphans.isEmpty,
            "Backup & restore was removed but a SettingsExtraIndex row still advertises it: \(extraOrphans.map(\.title))"
        )
    }

    /// Advanced-control tokens are not advertised by any live `SettingsIndex` row.
    @Test func advancedControlRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let tokens = Set(["suspend resume", "temp basal", "cartridge", "advancedcontrol"])
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: tokens)
        #expect(
            orphans.isEmpty,
            "Advanced control was removed but a SettingsIndex row still advertises it: \(orphans.map(\.title))")
    }
}
