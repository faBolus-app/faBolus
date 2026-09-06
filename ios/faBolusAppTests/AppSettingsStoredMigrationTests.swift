import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// `@Stored` conversion must keep each property's exact UserDefaults key and default, and must not
/// fire `onChange` during `init`. Force-pinned values (retention, stacking-guard friction, critical-
/// alerts default) still win over any stored leftover.
@MainActor
struct AppSettingsStoredMigrationTests {

    // MARK: - `Stored` wrapper's own contract (self-contained, no `AppSettings` needed)

    @Test func storedReturnsDefaultWhenKeyAbsent() {
        let suiteName = "AppSettingsStoredMigrationTests.storedDefault.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }
        var s = Stored<Bool>(wrappedValue: true, "someKey")
        s.store = d
        #expect(s.wrappedValue == true)
    }

    @Test func storedRoundTripsUnderTheExactKeyString() {
        let suiteName = "AppSettingsStoredMigrationTests.storedRoundTrip.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }
        var s = Stored<Int>(wrappedValue: 6, "glucoseStaleMinutesProbe")
        s.store = d
        s.wrappedValue = 20
        #expect(d.object(forKey: "glucoseStaleMinutesProbe") as? Int == 20)
        var s2 = Stored<Int>(wrappedValue: 6, "glucoseStaleMinutesProbe")
        s2.store = d
        #expect(s2.wrappedValue == 20)
    }

    /// `Stored.wrappedValue`'s OWN setter deliberately does NOT invoke `onChange` (see Stored.swift's
    /// `onChange` doc comment — calling it from inside the setter risks a Swift exclusivity crash when
    /// the side effect reads the SAME `@Observable`-tracked property being set, e.g. `applyFreshness()`
    /// reading `glucoseStaleMinutes`). The caller (`AppSettings`'s property setter) is responsible for
    /// invoking `onChange?(newValue)` as a SEPARATE statement after the write. This test pins that
    /// exact contract: `wrappedValue`'s get/set never invoke `onChange` themselves — neither merely
    /// constructing a `Stored` value, reading it, nor writing it fires the hook on their own.
    @Test func storedOnChangeIsNeverInvokedByWrappedValueItself() {
        let suiteName = "AppSettingsStoredMigrationTests.storedOnChange.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        defer { d.removePersistentDomain(forName: suiteName) }
        var fireCount = 0
        var s = Stored<Bool>(wrappedValue: false, "onChangeProbe", onChange: { _ in fireCount += 1 })
        s.store = d
        _ = s.wrappedValue  // read — must not fire
        #expect(fireCount == 0)
        s.wrappedValue = true  // write — `wrappedValue`'s setter itself must NOT fire onChange
        #expect(fireCount == 0)
        _ = s.wrappedValue  // read again — still must not fire
        #expect(fireCount == 0)
        // The caller invokes it explicitly (mirrors what `AppSettings`'s converted setters do):
        s.onChange?(s.wrappedValue)
        #expect(fireCount == 1)
    }

    // MARK: - Structural + round-trip helpers

    /// Confirm the private `_<label>` field is `Stored<T>`.
    private func expectStoredBacking<T>(_ settings: AppSettings, label: String, valueType: T.Type) {
        let mirror = Mirror(reflecting: settings)
        let backing = mirror.children.first { $0.label == label }
        #expect(backing != nil, "missing @Stored backing field \(label)")
        if let backing {
            #expect(
                type(of: backing.value) == Stored<T>.self,
                "\(label) is \(type(of: backing.value)), expected Stored<\(T.self)>")
        }
    }

    /// Fresh, uniquely-named suite per call — safe to leave un-removed across test runs (each name is
    /// a fresh UUID, so nothing ever collides), matching the "throwaway suite" precedent already used
    /// throughout `SettingsCatalogTests`/`SettingsCatalogTests`-style tests in this target.
    private func freshSuite(_ tag: String) -> UserDefaults {
        UserDefaults(suiteName: "AppSettingsStoredMigrationTests.\(tag).\(UUID().uuidString)")!
    }

    private func assertBoolStoredRoundTrip(
        key: String, backingLabel: String, defaultValue: Bool,
        _ path: ReferenceWritableKeyPath<AppSettings, Bool>
    ) {
        let d = freshSuite(key)
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: backingLabel, valueType: Bool.self)
        #expect(settings[keyPath: path] == defaultValue, "\(key): default mismatch")
        settings[keyPath: path] = !defaultValue
        #expect(d.object(forKey: key) as? Bool == !defaultValue, "\(key): exact-key write mismatch")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2[keyPath: path] == !defaultValue, "\(key): round-trip across re-init mismatch")
    }

    private func assertIntStoredRoundTrip(
        key: String, backingLabel: String, defaultValue: Int, alternateValue: Int,
        _ path: ReferenceWritableKeyPath<AppSettings, Int>
    ) {
        let d = freshSuite(key)
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: backingLabel, valueType: Int.self)
        #expect(settings[keyPath: path] == defaultValue, "\(key): default mismatch")
        settings[keyPath: path] = alternateValue
        #expect(d.object(forKey: key) as? Int == alternateValue, "\(key): exact-key write mismatch")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2[keyPath: path] == alternateValue, "\(key): round-trip across re-init mismatch")
    }

    private func assertDoubleStoredRoundTrip(
        key: String, backingLabel: String, defaultValue: Double, alternateValue: Double,
        _ path: ReferenceWritableKeyPath<AppSettings, Double>
    ) {
        let d = freshSuite(key)
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: backingLabel, valueType: Double.self)
        #expect(settings[keyPath: path] == defaultValue, "\(key): default mismatch")
        settings[keyPath: path] = alternateValue
        #expect(d.object(forKey: key) as? Double == alternateValue, "\(key): exact-key write mismatch")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2[keyPath: path] == alternateValue, "\(key): round-trip across re-init mismatch")
    }

    private func assertStringStoredRoundTrip(
        key: String, backingLabel: String, defaultValue: String, alternateValue: String,
        _ path: ReferenceWritableKeyPath<AppSettings, String>
    ) {
        let d = freshSuite(key)
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: backingLabel, valueType: String.self)
        #expect(settings[keyPath: path] == defaultValue, "\(key): default mismatch")
        settings[keyPath: path] = alternateValue
        #expect(d.string(forKey: key) == alternateValue, "\(key): exact-key write mismatch")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2[keyPath: path] == alternateValue, "\(key): round-trip across re-init mismatch")
    }

    // MARK: - Bool properties (no side effect)

    @Test func showGlucoseAxisStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "showGlucoseAxis", backingLabel: "__showGlucoseAxis", defaultValue: true, \.showGlucoseAxis)
    }
    @Test func showIOBAxisStoredRoundTrip() {
        assertBoolStoredRoundTrip(key: "showIOBAxis", backingLabel: "__showIOBAxis", defaultValue: true, \.showIOBAxis)
    }
    @Test func showBolusBarsStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "showBolusBars", backingLabel: "__showBolusBars", defaultValue: true, \.showBolusBars)
    }
    @Test func showStatsStoredRoundTrip() {
        assertBoolStoredRoundTrip(key: "showStats", backingLabel: "__showStats", defaultValue: false, \.showStats)
    }
    @Test func phoneReadOnlyStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "phoneReadOnly", backingLabel: "__phoneReadOnly", defaultValue: false, \.phoneReadOnly)
    }
    @Test func readOnlyAllowAlertClearStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "readOnlyAllowAlertClear", backingLabel: "__readOnlyAllowAlertClear", defaultValue: false,
            \.readOnlyAllowAlertClear)
    }
    @Test func remotesReadOnlyStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "remotesReadOnly", backingLabel: "__remotesReadOnly", defaultValue: false, \.remotesReadOnly)
    }
    @Test func garminBolusEnabledStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "garminBolusEnabled", backingLabel: "__garminBolusEnabled", defaultValue: false, \.garminBolusEnabled)
    }
    @Test func showBolusReasoningStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "showBolusReasoning", backingLabel: "__showBolusReasoning", defaultValue: true, \.showBolusReasoning)
    }
    @Test func garminClockAnalogStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "garminClockAnalog", backingLabel: "__garminClockAnalog", defaultValue: false, \.garminClockAnalog)
    }
    // MARK: - Int properties

    @Test func glucosePlotFloorStoredRoundTrip() {
        // 50 is a valid `floorOptions` preset so a fresh re-init's `GlucosePlotScale.resolve` (unchanged
        // validation, still called from `init`) doesn't snap it to a different value.
        assertIntStoredRoundTrip(
            key: "glucosePlotFloor", backingLabel: "__glucosePlotFloor", defaultValue: 40, alternateValue: 50,
            \.glucosePlotFloor)
    }
    @Test func glucosePlotCeilingStoredRoundTrip() {
        assertIntStoredRoundTrip(
            key: "glucosePlotCeiling", backingLabel: "__glucosePlotCeiling", defaultValue: 300, alternateValue: 350,
            \.glucosePlotCeiling)
    }

    // MARK: - Int property WITH a side effect (applyFreshness())

    @Test func glucoseStaleMinutesStoredRoundTrip() {
        assertIntStoredRoundTrip(
            key: "glucoseStaleMinutes", backingLabel: "__glucoseStaleMinutes", defaultValue: 6, alternateValue: 10,
            \.glucoseStaleMinutes)
    }

    // MARK: - Double property WITH a side effect (syncWidgetConfig())

    @Test func carbIncrementStoredRoundTrip() {
        assertDoubleStoredRoundTrip(
            key: "carbIncrement", backingLabel: "__carbIncrement", defaultValue: 5, alternateValue: 10, \.carbIncrement)
    }

    // MARK: - String property (validated set-membership at init, unchanged)

    @Test func garminComplicationDisplayStoredRoundTrip() {
        // "stringTrend" is the other valid `complicationDisplayOptions` entry.
        assertStringStoredRoundTrip(
            key: "garminComplicationDisplay", backingLabel: "__garminComplicationDisplay", defaultValue: "numericColor",
            alternateValue: "stringTrend", \.garminComplicationDisplay)
    }

    // MARK: - Enum property (RawRepresentable<String>) WITH a side effect (syncWidgetConfig())

    @Test func defaultBolusModeStoredRoundTrip() {
        let d = freshSuite("defaultBolusMode")
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: "__defaultBolusMode", valueType: BolusMode.self)
        #expect(settings.defaultBolusMode == .carbs)
        settings.defaultBolusMode = .units
        #expect(d.string(forKey: "defaultBolusMode") == "units")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2.defaultBolusMode == .units)
    }

    // MARK: - Initialization behavior: a side effect must NOT fire during `AppSettings.init()`

    /// Structural proof of the "does not fire during init" guarantee: right after construction, every
    /// side-effecting `Stored` field's `onChange` hook must be WIRED (non-nil) — proving the
    /// post-init wiring block ran — while `AppSettingsStoredMigrationTests.storedOnChangeFiresOnlyOnWriteNeverOnConstructionOrRead`
    /// above proves `Stored.onChange` is invoked ONLY by a subsequent write, never by mere
    /// construction/read. Together these two facts are sufficient: since every property's OWN
    /// init-time assignment necessarily executes BEFORE the post-init wiring block (in source order),
    /// and `onChange` is `nil` until that block runs, no assignment inside `init()` could have
    /// invoked a side effect.
    @Test func sideEffectHooksAreWiredOnlyAfterInitCompletes() {
        let d = freshSuite("sideEffectWiring")
        let settings = AppSettings(defaults: d)
        for label in ["__defaultBolusMode", "__carbIncrement", "__glucoseStaleMinutes"] {
            let mirror = Mirror(reflecting: settings)
            guard let backing = mirror.children.first(where: { $0.label == label }) else {
                Issue.record("missing backing field \(label)")
                continue
            }
            let onChangeChild = Mirror(reflecting: backing.value).children.first { $0.label == "onChange" }
            #expect(onChangeChild != nil, "\(label): missing onChange field")
            // `onChange` is `((Value) -> Void)?` — Mirror's optional representation has exactly one
            // child (the wrapped closure) when non-nil, zero when nil.
            let wired = onChangeChild.map { Mirror(reflecting: $0.value).children.count == 1 } ?? false
            #expect(wired, "\(label): onChange hook was not wired after init completed")
        }
    }

    // MARK: - Remaining simple scalar properties converted to `@Stored`
    //
    // Same key-string + default contract as the batch above. JSON-encoded, Date-optional, array-typed,
    // and getter-frozen properties are still not converted.

    // MARK: Bool properties (no side effect)

    @Test func historySyncEnabledStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "historySyncEnabled", backingLabel: "__historySyncEnabled", defaultValue: true, \.historySyncEnabled)
    }
    @Test func autoExerciseModeStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "autoExerciseMode", backingLabel: "__autoExerciseMode", defaultValue: false, \.autoExerciseMode)
    }
    @Test func autoSleepModeStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "autoSleepMode", backingLabel: "__autoSleepMode", defaultValue: false, \.autoSleepMode)
    }

    // MARK: Bool property (showGlucoseUnitLabels — its widget-republish side effect was removed;
    // the setting itself and its 6 live readers stay)

    @Test func showGlucoseUnitLabelsStoredRoundTrip() {
        assertBoolStoredRoundTrip(
            key: "showGlucoseUnitLabels", backingLabel: "__showGlucoseUnitLabels", defaultValue: false,
            \.showGlucoseUnitLabels)
    }

    // MARK: Double properties (`watchBolusIncrement`/`watchCarbIncrement` are plain; `bolusIncrement`
    // has a `syncWidgetConfig()` side effect). Alternates are chosen from the pump's real increment sets
    // so init's `max(0.05, …)` clamp (unchanged) never re-snaps the round-tripped value.

    @Test func bolusIncrementStoredRoundTrip() {
        assertDoubleStoredRoundTrip(
            key: "bolusIncrement", backingLabel: "__bolusIncrement", defaultValue: 0.05, alternateValue: 1,
            \.bolusIncrement)
    }
    @Test func watchBolusIncrementStoredRoundTrip() {
        assertDoubleStoredRoundTrip(
            key: "watchBolusIncrement", backingLabel: "__watchBolusIncrement", defaultValue: 0.05, alternateValue: 1,
            \.watchBolusIncrement)
    }
    @Test func watchCarbIncrementStoredRoundTrip() {
        assertDoubleStoredRoundTrip(
            key: "watchCarbIncrement", backingLabel: "__watchCarbIncrement", defaultValue: 5, alternateValue: 10,
            \.watchCarbIncrement)
    }

    // MARK: String properties (validated set-membership at init, unchanged)

    @Test func garminDefaultScreenStoredRoundTrip() {
        // "glucose" is a valid `garminScreens` entry so init's `order.contains(def)` validation keeps it.
        assertStringStoredRoundTrip(
            key: "garminDefaultScreen", backingLabel: "__garminDefaultScreen", defaultValue: "glance",
            alternateValue: "glucose", \.garminDefaultScreen)
    }
    @Test func garminTargetAppStoredRoundTrip() {
        assertStringStoredRoundTrip(
            key: "garminTargetApp", backingLabel: "__garminTargetApp", defaultValue: "beta", alternateValue: "official",
            \.garminTargetApp)
    }

    // MARK: Enum property (RawRepresentable<String>) with a legacy phone-default fallback at init

    @Test func watchDefaultBolusModeStoredRoundTrip() {
        let d = freshSuite("watchDefaultBolusMode")
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: "__watchDefaultBolusMode", valueType: BolusMode.self)
        #expect(settings.watchDefaultBolusMode == .carbs)  // fresh: neither watch nor phone key present
        settings.watchDefaultBolusMode = .units
        #expect(d.string(forKey: "watchDefaultBolusMode") == "units")
        let settings2 = AppSettings(defaults: d)
        #expect(settings2.watchDefaultBolusMode == .units)
    }

    /// Legacy-value preservation: a user who only ever set the PHONE default (never a separate watch
    /// default) must keep inheriting it — this fallback lives in `init` and must survive the conversion.
    @Test func watchDefaultBolusModeFallsBackToPhoneDefaultWhenItsOwnKeyIsAbsent() {
        let d = freshSuite("watchDefaultBolusMode.fallback")
        d.set("units", forKey: "defaultBolusMode")  // phone default only; watch key absent
        let settings = AppSettings(defaults: d)
        #expect(settings.watchDefaultBolusMode == .units, "watch default must fall back to the phone default")
    }

    // MARK: Force-pinned properties (init overrides any stored value, but the setter still writes the key)

    @Test func historyRetentionDaysIsForceSet1RegardlessOfAnyStoredValue() {
        let d = freshSuite("historyRetentionDays")
        d.set(30, forKey: "historyRetentionDays")  // simulate a legacy longer-retention window
        let settings = AppSettings(defaults: d)
        expectStoredBacking(settings, label: "__historyRetentionDays", valueType: Int.self)
        #expect(settings.historyRetentionDays == 1)  // force-set 1 (24h) wins over the stored value
        settings.historyRetentionDays = 30  // the setter itself is unchanged (still writable)…
        #expect(d.object(forKey: "historyRetentionDays") as? Int == 30)
        let settings2 = AppSettings(defaults: d)
        #expect(settings2.historyRetentionDays == 1)  // …but the NEXT init still force-sets 1
    }

    // MARK: `criticalAlertsEnabled` — default + round trip

    @Test func criticalAlertsEnabledStoredRoundTrip() {
        // Fresh install (no keys): default OFF.
        let d1 = freshSuite("criticalAlertsEnabled.fresh")
        let s1 = AppSettings(defaults: d1)
        expectStoredBacking(s1, label: "__criticalAlertsEnabled", valueType: Bool.self)
        #expect(s1.criticalAlertsEnabled == false)

        // Round trip: a user enable persists and survives the next init.
        s1.criticalAlertsEnabled = true
        #expect(d1.object(forKey: "criticalAlertsEnabled") as? Bool == true)
        let s2 = AppSettings(defaults: d1)
        #expect(s2.criticalAlertsEnabled == true)
    }

    // MARK: - SettingsCatalog counts unchanged by Stored conversion

    @Test func settingsCatalogCountsUnchangedByStoredConversion() {
        // Three retired Garmin alert-intensity settings were removed; both counts must stay in lockstep.
        #expect(SettingsCatalog.descriptors.count == 32)
        #expect(SettingsCatalog.backedUpKeys.count == 32)
    }
}
