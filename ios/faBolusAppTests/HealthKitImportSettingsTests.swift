import Testing
import Foundation
import faBolusCore
import HistoryStore
@testable import faBolus

/// Phase 09.23-02 (D-11/D-14): AppSettings per-type Apple Health import toggles default to OFF
/// (behavior 1), and `AppModel`'s manual import entry point routes exactly the enabled types'
/// results ONLY into `GlucoseHistoryStore.ingest*` — never `GlucoseArbiter`/`BolusMath` (D-05,
/// behavior 2). Behavior 1 runs under every build (the settings MODEL is unconditional, D-13);
/// behavior 2 is `#if FABOLUS_HEALTHKIT`-gated (the AppModel import hook itself is gated) —
/// mirrors `AppModelBehaviorTests.inverseControlIQPreconditionOverturnedUnderExperimentalFlag`'s
/// precedent for a flag-gated `@Test` that compiles out of the default/CI build.
@MainActor
struct HealthKitImportSettingsTests {

    // MARK: - Behavior 1: every new toggle defaults to false (D-11b auto default OFF, D-14 per-type)

    @Test func healthKitImportTogglesDefaultToFalse() {
        let suiteName = "HealthKitImportSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        #expect(settings.healthKitImportCarbsEnabled == false)
        #expect(settings.healthKitImportInsulinEnabled == false)
        #expect(settings.healthKitImportHeartRateEnabled == false)
        #expect(settings.healthKitImportGlucoseEnabled == false)
        #expect(settings.healthKitAutoImportEnabled == false, "D-11b: automatic import defaults OFF")
    }

    @Test func healthKitImportTogglesRoundTripThroughBackup() {
        let suiteName = "HealthKitImportSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.healthKitImportCarbsEnabled = true
        settings.healthKitImportInsulinEnabled = true
        settings.healthKitImportHeartRateEnabled = true
        settings.healthKitImportGlucoseEnabled = true
        settings.healthKitAutoImportEnabled = true
        let snapshot = settings.backupSnapshot()

        let restoreSuite = "HealthKitImportSettingsTests.restore.\(UUID().uuidString)"
        let restoreDefaults = UserDefaults(suiteName: restoreSuite)!
        defer { restoreDefaults.removePersistentDomain(forName: restoreSuite) }
        let restored = AppSettings(defaults: restoreDefaults)
        restored.applyBackup(snapshot)

        #expect(restored.healthKitImportCarbsEnabled == true)
        #expect(restored.healthKitImportInsulinEnabled == true)
        #expect(restored.healthKitImportHeartRateEnabled == true)
        #expect(restored.healthKitImportGlucoseEnabled == true)
        #expect(restored.healthKitAutoImportEnabled == true)
    }

    // MARK: - Behavior 2 (FABOLUS_HEALTHKIT only): manual import routes enabled types to history ONLY

    #if FABOLUS_HEALTHKIT
    private func makeModel() -> (AppModel, MockBackend) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return (AppModel(source: backend, ledgerStoreURL: url), backend)
    }

    /// A fake `HealthKitImportSource` — never touches real `HKHealthStore`, so this test needs no
    /// entitlement and runs deterministically. Records exactly which types were requested for
    /// authorization, proving the enabled-only subset reaches the seam (D-14).
    private final class FakeHealthKitImportSource: HealthKitImportSource {
        private(set) var requestedTypes: Set<HealthKitHistoryImporter.HealthKitImportType> = []
        var carbs: [(date: Date, grams: Double)] = []
        var insulin: [(date: Date, units: Double)] = []
        var heartRate: [(date: Date, bpm: Double)] = []
        var glucose: [GlucoseReading] = []

        func requestAuthorizationIfNeeded(enabledTypes: Set<HealthKitHistoryImporter.HealthKitImportType>) async {
            requestedTypes = enabledTypes
        }
        func importCarbHistory(since: Date) async -> [(date: Date, grams: Double)] { carbs }
        func importInsulinHistory(since: Date) async -> [(date: Date, units: Double)] { insulin }
        func importHeartRateHistory(since: Date) async -> [(date: Date, bpm: Double)] { heartRate }
        func importGlucoseGapFill(since: Date, existingSlots: Set<Int>, sourceID: String) async -> [GlucoseReading] { glucose }
    }

    @Test func manualImportRoutesOnlyEnabledTypesIntoHistoryIngest() async throws {
        let (model, _) = makeModel()
        let store = try GlucoseHistoryStore(inMemory: true)
        model.setHistoryStoreForTesting(store)

        AppSettings.shared.healthKitImportCarbsEnabled = true
        AppSettings.shared.healthKitImportInsulinEnabled = false
        AppSettings.shared.healthKitImportHeartRateEnabled = true
        AppSettings.shared.healthKitImportGlucoseEnabled = false
        defer {
            AppSettings.shared.healthKitImportCarbsEnabled = false
            AppSettings.shared.healthKitImportHeartRateEnabled = false
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let fake = FakeHealthKitImportSource()
        fake.carbs = [(date: t0, grams: 30)]
        fake.insulin = [(date: t0, units: 99)]   // must NOT be ingested — insulin import is disabled
        fake.heartRate = [(date: t0, bpm: 72)]
        model.setHealthKitImportSourceForTesting(fake)

        await model.importFromAppleHealth()

        #expect(fake.requestedTypes == [.carbs, .heartRate], "only the enabled types are authorized/requested")

        let window = t0.addingTimeInterval(-60)...t0.addingTimeInterval(60)
        #expect(store.carbs(in: window).map(\.grams) == [30])
        #expect(store.heartRate(in: window).map(\.bpm) == [72])
        #expect(store.boluses(in: window).isEmpty, "insulin import was disabled — no bolus reaches history")
    }
    #endif
}
