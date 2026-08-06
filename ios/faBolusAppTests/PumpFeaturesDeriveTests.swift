import Testing
import Foundation
import PumpX2Messages
import faBolusCore
@testable import faBolus

/// P13-1: the driver decode boundary. `TandemBackend.featureBits(from:)` projects the pump's own
/// `PumpFeaturesV1Response` (op 79, a little-endian uint64 bitmask) onto the neutral `PumpFeatureBits`
/// that faBolusCore's `PumpCapabilities.derive` consumes — so a real pump's advertised capabilities,
/// not one `isMobi` boolean, decide what's offered. These pin the bit→flag mapping and its end-to-end
/// effect on the derived capability set.
@MainActor
struct PumpFeaturesDeriveTests {
    /// The 8-byte little-endian cargo for a raw feature bitmask (mirrors `Bytes.readUint64(raw, 0)`).
    private func cargo(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (UInt64($0) * 8)) & 0xFF) } }

    // Named bits from PumpFeaturesV1Response.
    private let controlIQ: UInt64 = 1024          // bit 10
    private let basalLimit: UInt64 = 262144       // bit 18
    private let blePumpControl: UInt64 = 268435456 // bit 28

    @Test func featureBitsMapEachAccessor() {
        let r = PumpFeaturesV1Response(cargo: cargo(controlIQ | blePumpControl))  // basalLimit NOT set
        let bits = TandemBackend.featureBits(from: r)
        #expect(bits.controlIQSupported)
        #expect(bits.blePumpControlSupported)
        #expect(!bits.basalLimitSupported)
    }

    @Test func emptyCargoIsAllFalse() {
        let bits = TandemBackend.featureBits(from: PumpFeaturesV1Response(cargo: []))
        #expect(!bits.controlIQSupported && !bits.basalLimitSupported && !bits.blePumpControlSupported)
    }

    @Test func decodedBitsFlowIntoTheDerivedCapabilities() {
        // A Mobi advertising CIQ + BLE control but NOT a basal limit: CIQ settings stay on, limits off.
        let r = PumpFeaturesV1Response(cargo: cargo(controlIQ | blePumpControl))
        let caps = PumpCapabilities.derive(isMobi: true, features: TandemBackend.featureBits(from: r))
        #expect(caps.supportsControlIQSettings)
        #expect(!caps.supportsLimits)
        #expect(caps.supportsModes)   // preset floor preserved

        // Same pump reporting no BLE pump control → all advanced control collapses.
        let noControl = PumpFeaturesV1Response(cargo: cargo(controlIQ | basalLimit)) // bit 28 clear
        let capsNoControl = PumpCapabilities.derive(
            isMobi: true, features: TandemBackend.featureBits(from: noControl))
        #expect(!capsNoControl.supportsAnyAdvancedControl)
    }
}
