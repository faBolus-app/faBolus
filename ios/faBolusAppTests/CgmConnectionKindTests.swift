import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// 09.22-01 Task 2 (D-06): pins the typed `connectionKind` classification on every registered
/// `GlucoseSource`. Later waves (Test-flow copy/timeout, D-09) branch on this typed property instead
/// of scattered `id == "dexcom-g6-ble" || id == "dexcom-g7-ble"` string literals, so a new source
/// cannot be silently forgotten — the protocol has no extension default, so a source that omits the
/// property cannot compile. Builds each source via `GlucoseSourceRegistry` and reads the LIVE
/// instance's classification (mirrors `CgmSourceValidationTests`' registry-construction style).
@MainActor
struct CgmConnectionKindTests {

    /// The expected classification for each registered failover source. "healthkit" only exists in
    /// `GlucoseSourceRegistry.enabled` when `FABOLUS_HEALTHKIT` is ON (D-13, Phase 09.23) — gated
    /// here too so the set-equality check below stays exact in both flag states, as an unavoidable
    /// direct consequence of that gating (not itself part of the 09.23-01 plan's declared scope).
    private static let expected: [String: GlucoseConnectionKind] = {
        var table: [String: GlucoseConnectionKind] = [
            "nightscout": .cloudPoll,
            "dexcom-share": .cloudPoll,
            // "xdrip-appgroup" removed from `main` in Phase 1, Plan 01 (CGM-05).
            // "dexcom-g6-ble" / "librelinkup" removed from `main` in Phase 1, Plan 02 (CGM-03/CGM-04).
            // "dexcom-g7-ble" removed from `main` in Phase 1, Plan 03 (CGM-01/CGM-02) — with it gone,
            // narrow main has NO remaining `.localBLE` source (see the gated assertion below).
        ]
        #if FABOLUS_HEALTHKIT
        table["healthkit"] = .localOnDevice
        #endif
        return table
    }()

    /// Every registered source classifies itself correctly (BLE / cloud / on-device). Iterates the
    /// registry's enabled descriptors so the set is exactly what the app ships, not a hand-copied list.
    @Test func everyRegisteredSourceClassifiesItsConnectionKind() {
        let enabled = GlucoseSourceRegistry.enabled
        // Guard against silent registry drift: the classification table must cover every enabled id.
        #expect(Set(enabled.map(\.id)) == Set(Self.expected.keys),
                "the registry's enabled ids must match the classification table exactly")

        for descriptor in enabled {
            guard let source = GlucoseSourceRegistry.make(id: descriptor.id) else {
                Issue.record("could not build source \(descriptor.id) via the registry")
                continue
            }
            guard let want = Self.expected[descriptor.id] else {
                Issue.record("no expected connectionKind for \(descriptor.id)")
                continue
            }
            #expect(source.connectionKind == want,
                    "\(descriptor.id) must classify as \(want), got \(source.connectionKind)")
        }
    }

    /// The connection kinds the registry's enabled sources classify as, built exactly as the app
    /// ships them (not a hand-copied list). Shared by the three assertions below, each named for the
    /// single kind it checks so the name and the assertion can never drift apart (they did once: the
    /// former `allThreeConnectionKindsArePresentAcrossTheRegistry` asserted `.localBLE` *absence*).
    private static func enabledConnectionKinds() -> [GlucoseConnectionKind] {
        GlucoseSourceRegistry.enabled.compactMap { GlucoseSourceRegistry.make(id: $0.id)?.connectionKind }
    }

    /// The cloud-poll category is populated — proves the typed enum actually differentiates the
    /// physical connection classes (not everything collapsing into one case). Nightscout + Dexcom
    /// Share are narrow `main`'s cloud-poll sources.
    @Test func cloudPollConnectionKindIsPresentInTheRegistry() {
        #expect(Self.enabledConnectionKinds().contains(.cloudPoll))
    }

    /// No direct-BLE CGM source remains on narrow `main` (asserts ABSENCE). `.localBLE` was Dexcom
    /// G6/G7's category; both were removed from `main` in Phase 1 (G6 + LibreLinkUp in Plan 02, G7 in
    /// Plan 03), so narrow `main` classifies ZERO sources as `.localBLE` (D-03: zero direct-BLE CGM on
    /// any surface).
    @Test func noDirectBleConnectionKindRemainsOnNarrowMain() {
        #expect(!Self.enabledConnectionKinds().contains(.localBLE),
                "no direct-BLE CGM source remains on narrow main (D-03)")
    }

    /// `.localOnDevice` was xDrip App Group's category (removed from `main` in Phase 1, Plan 01,
    /// CGM-05). The only remaining `.localOnDevice` source is HealthKit, which compiles in only under
    /// `FABOLUS_HEALTHKIT` (D-13) — so the kind is present in that flag state and absent otherwise.
    @Test func localOnDeviceConnectionKindMatchesHealthKitGate() {
        let kinds = Self.enabledConnectionKinds()
        #if FABOLUS_HEALTHKIT
        #expect(kinds.contains(.localOnDevice),
                "HealthKit is the only remaining .localOnDevice source and is compiled in")
        #else
        #expect(!kinds.contains(.localOnDevice),
                "no .localOnDevice source remains when HealthKit is not compiled in")
        #endif
    }
}
