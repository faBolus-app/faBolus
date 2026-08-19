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
            "dexcom-g7-ble": .localBLE,
            "dexcom-g6-ble": .localBLE,
            "librelinkup": .cloudPoll,
            "nightscout": .cloudPoll,
            "dexcom-share": .cloudPoll,
            "xdrip-appgroup": .localOnDevice,
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

    /// The three categories are each populated — proves the typed enum actually differentiates the
    /// three physical connection classes (not everything collapsing into one case).
    @Test func allThreeConnectionKindsArePresentAcrossTheRegistry() {
        let kinds = GlucoseSourceRegistry.enabled.compactMap { GlucoseSourceRegistry.make(id: $0.id)?.connectionKind }
        #expect(kinds.contains(.localBLE))
        #expect(kinds.contains(.cloudPoll))
        #expect(kinds.contains(.localOnDevice))
    }
}
