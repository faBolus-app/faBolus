import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 Slice 1 drift guards. The catalog (`SettingsCatalog.descriptors`) is the single source of truth
/// for the 44 persisted `AppSettings` keys; these tests pin the four hand-maintained lists to it so they
/// can never drift silently — the mirror-plus-guard idiom used by `PumpControlBoundsMirrorTests` and
/// `WidgetGlucoseThresholdsMirrorTests`, applied to the settings surface instead of a wire/firmware bound.
struct SettingsCatalogTests {

    /// The three backup keys `backupSnapshot()` emits only when their value is present (an optional int and
    /// two JSON blobs). Everything else is unconditional. Declared here so the drift guard can tolerate
    /// their absence on a fresh `AppSettings` without weakening it.
    private let conditionalBackupKeys: Set<String> = ["glucoseHideDelayMinutes", "alertRules", "childAllowed"]

    // MARK: Coverage

    @Test func descriptorsCoverExactly44UniqueKeys() {
        #expect(SettingsCatalog.descriptors.count == 44)
        #expect(SettingsCatalog.byKey.count == 44)   // Dictionary(uniqueKeysWithValues:) also traps on dup
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
        #expect(SettingsCatalog.backedUpKeys.count == 36)                      // 33 unconditional + 3 conditional
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
        // Every one of the 44 keys is an app/display/remote preference the user owns. The `.clinician` /
        // `.fixed` tiers exist in the vocabulary but are reserved for the pump-therapy descriptors S6–S8
        // add as *separate* rows; if one is ever added here it must update this assertion deliberately.
        #expect(SettingsCatalog.descriptors.allSatisfy { $0.tier == .user })
    }
}
