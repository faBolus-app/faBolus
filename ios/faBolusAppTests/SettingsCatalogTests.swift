import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 Slice 1 drift guards. The catalog (`SettingsCatalog.descriptors`) is the single source of truth
/// for the 45 persisted `AppSettings` keys; these tests pin the four hand-maintained lists to it so they
/// can never drift silently — the mirror-plus-guard idiom used by `PumpControlBoundsMirrorTests` and
/// `WidgetGlucoseThresholdsMirrorTests`, applied to the settings surface instead of a wire/firmware bound.
struct SettingsCatalogTests {

    /// The four backup keys `backupSnapshot()` emits only when their value is present (two optionals — an
    /// int and the §2.3 remote-bolus ceiling double — and two JSON blobs). Everything else is unconditional.
    /// Declared here so the drift guard can tolerate their absence on a fresh `AppSettings` without weakening it.
    private let conditionalBackupKeys: Set<String> = ["glucoseHideDelayMinutes", "remoteBolusCeiling", "alertRules", "childAllowed"]

    // MARK: Coverage

    @Test func descriptorsCoverExactly48UniqueKeys() {
        // P16 §3.2: 48 → 46 (smartAssistEnabled R6 + hypoAlertsEnabled R5 removed). P16 F2: 46 → 44
        // (basalScheduleByHour + basalScheduleSource removed with the dead display-only basal cache).
        // Phase 01-03 (task #93, SG3a): 44 → 45 (stackingGuardFrictionEnabled added).
        // Phase 04-01 (mmol/L display-unit support, D-03): 45 → 46 (glucoseDisplayUnit added).
        // Phase 5 (05-04, D-15/D-17a): 46 → 48 (liveActivityEnabled + liveActivityFields added).
        // Phase 5 (05-03, D-13/D-14): 48 → 49 (glucoseBadgeEnabled added).
        #expect(SettingsCatalog.descriptors.count == 49)
        #expect(SettingsCatalog.byKey.count == 49)   // Dictionary(uniqueKeysWithValues:) also traps on dup
        let keys = SettingsCatalog.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count)       // no duplicate literal
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
        // Phase 5 (05-04): 42 → 44 (liveActivityEnabled + liveActivityFields, both unconditional).
        // Phase 5 (05-03): 44 → 45 (glucoseBadgeEnabled, unconditional).
        #expect(SettingsCatalog.backedUpKeys.count == 45)                      // 41 unconditional + 4 conditional
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

    /// P16 F2 backup-format tolerance. `basalScheduleByHour` / `basalScheduleSource` were removed with the
    /// dead display-only basal cache. A backup written by an OLDER build may still carry those keys; restore
    /// must (a) decode such a file (an unknown *key* with a valid `BackupValue` is not an unknown *type*, so
    /// it survives JSON) and (b) silently ignore them in `applyBackup` — never crash, never resurrect a
    /// removed setting. Start from the current snapshot so the assertion stays an idempotent no-op round-trip.
    @Test @MainActor func restoreToleratesLegacyBasalScheduleKeys() {
        let base = AppSettings.shared.backupSnapshot()
        var legacy = base
        legacy["basalScheduleByHour"] = .data(Data([0, 1, 2, 3]))   // stand-in for the old [Double] cache blob
        legacy["basalScheduleSource"] = .string("Nightscout")
        // Survive a full JSON encode→decode like a real on-disk backup, not just an in-memory dict.
        let backup = FaBolusBackup(meta: .init(createdAt: Date(), appVersion: "test",
                                               pumpModel: "unknown", deviceName: "test"),
                                   appSettings: legacy)
        let decoded = try? FaBolusBackup.decode(backup.encoded())
        #expect(decoded != nil, "a legacy backup carrying removed keys must still decode")
        #expect(decoded?.appSettings?["basalScheduleByHour"] != nil)   // the unknown key round-trips…
        AppSettings.shared.applyBackup(decoded?.appSettings ?? [:])    // …and applying it must not crash
        #expect(AppSettings.shared.backupSnapshot() == base)           // removed keys ignored; nothing changed
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
        #expect(!simple.isEmpty)                       // Simple is a real, usable subset
        #expect(simple.count < advanced.count)         // …and strictly fewer than Advanced sees
        #expect(Set(simple).isSubset(of: Set(advanced)))
    }

    // MARK: Tier axis (S1 state)

    @Test func allCurrentKeysAreUserTier() {
        // Every one of the 45 keys is an app/display/remote preference the user owns. The `.clinician` /
        // `.fixed` tiers exist in the vocabulary but are reserved for the pump-therapy descriptors S6–S8
        // add as *separate* rows; if one is ever added here it must update this assertion deliberately.
        #expect(SettingsCatalog.descriptors.allSatisfy { $0.tier == .user })
    }

    // MARK: Phase 01-03 (task #93, SG3a) — the escalating-friction disable toggle's registration

    /// The SG3a escalating-friction disable toggle must be a `.user`-tier row visible from Simple minimum
    /// mode (never `.clinician`/`.fixed`) — it only gates a UI friction-tier presentation choice, not a
    /// therapy parameter.
    @Test func stackingGuardFrictionEnabledIsRegisteredAtUserTierFromSimple() {
        let d = SettingsCatalog.byKey["stackingGuardFrictionEnabled"]
        #expect(d != nil, "stackingGuardFrictionEnabled missing from the catalog")
        #expect(d?.tier == .user)
        #expect(d?.isVisible(in: .simple) == true)
        #expect(d?.backsUp == true)
    }

    // MARK: Phase 04-01 (mmol/L display-unit support, D-03) — the glucoseDisplayUnit setting's registration

    /// D-03: `.display` category, `backsUp: true` with iCloud ON (a display unit is NOT command-adjacent).
    @Test func glucoseDisplayUnitIsRegisteredInDisplayWithICloudSyncOn() {
        let d = SettingsCatalog.byKey["glucoseDisplayUnit"]
        #expect(d != nil, "glucoseDisplayUnit missing from the catalog")
        #expect(d?.category == .display)
        #expect(d?.backsUp == true)
        #expect(d?.syncsToICloud == true)
        #expect(!SettingsCatalog.commandAdjacentFlags.contains("glucoseDisplayUnit"))
    }

    /// D-03: default = mg/dL (behavior-preserving for existing users) on a fresh install, and the setting
    /// round-trips across a re-init of `AppSettings` over the SAME backing store (persists, doesn't just
    /// live in memory).
    @Test @MainActor func glucoseDisplayUnitDefaultsToMgdlAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucoseDisplayUnit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucoseDisplayUnit == .mgdl)   // D-03: behavior-preserving default

        fresh.glucoseDisplayUnit = .mmol
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucoseDisplayUnit == .mmol)   // persisted across re-init
    }
}
