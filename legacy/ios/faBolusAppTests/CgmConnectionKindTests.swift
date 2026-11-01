import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins the typed `connectionKind` classification on every registered
/// `GlucoseSource`. Consumers (Test-flow copy/timeout) branch on this typed property instead
/// of scattered `id == "dexcom-g6-ble" || id == "dexcom-g7-ble"` string literals, so a new source
/// cannot be silently forgotten — the protocol has no extension default, so a source that omits the
/// property cannot compile. Builds each source via `GlucoseSourceRegistry` and reads the LIVE
/// instance's classification (mirrors `CgmSourceValidationTests`' registry-construction style).
@MainActor
struct CgmConnectionKindTests {

    /// The expected classification for each registered failover source. HealthKit ("healthkit") is
    /// not in narrow `main` (see dev/healthkit's REINTEGRATION.md); neither is Nightscout
    /// ("nightscout") (see dev/nightscout's REINTEGRATION.md) — narrow main's table is Share-only.
    private static let expected: [String: GlucoseConnectionKind] = [
        "dexcom-share": .cloudPoll
            // "xdrip-appgroup" is not in `main`.
            // "dexcom-g6-ble" / "librelinkup" are not in `main`.
            // "dexcom-g7-ble" is not in `main` either, and without it
            // narrow main has NO `.localBLE` source at all (see the gated assertion below).
    ]

    /// Every registered source classifies itself correctly (BLE / cloud / on-device). Iterates the
    /// registry's enabled descriptors so the set is exactly what the app ships, not a hand-copied list.
    @Test func everyRegisteredSourceClassifiesItsConnectionKind() {
        let enabled = GlucoseSourceRegistry.enabled
        // Guard against silent registry drift: the classification table must cover every enabled id.
        #expect(
            Set(enabled.map(\.id)) == Set(Self.expected.keys),
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
            #expect(
                source.connectionKind == want,
                "\(descriptor.id) must classify as \(want), got \(source.connectionKind)")
        }
    }

    /// The cloud-poll category is always populated — proves the typed enum actually differentiates
    /// the physical connection classes (not everything collapsing into one case). `.localBLE` was
    /// Dexcom G7's category and G7 is not in narrow `main`, so
    /// narrow `main` has NO `.localBLE` source at all (zero direct-BLE CGM on any
    /// surface). `.localOnDevice` was xDrip App Group's category, also absent from narrow `main`,
    /// so `.localOnDevice` is only expected when the last remaining
    /// `.localOnDevice` source (HealthKit) is compiled in.
    @Test func allThreeConnectionKindsArePresentAcrossTheRegistry() {
        let kinds = GlucoseSourceRegistry.enabled.compactMap { GlucoseSourceRegistry.make(id: $0.id)?.connectionKind }
        #expect(!kinds.contains(.localBLE), "no direct-BLE CGM source remains on narrow main")
        #expect(kinds.contains(.cloudPoll))
    }
}
