import Testing
import Foundation
import TandemMessages
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
    private let controlIQPro: UInt64 = 8388608    // bit 23
    private let blePumpControl: UInt64 = 268435456 // bit 28

    @Test func featureBitsMapEachAccessor() {
        let r = PumpFeaturesV1Response(cargo: cargo(controlIQ | blePumpControl))  // basalLimit + Pro NOT set
        let bits = TandemBackend.featureBits(from: r)
        #expect(bits.controlIQSupported)
        #expect(bits.blePumpControlSupported)
        #expect(!bits.basalLimitSupported)
        #expect(!bits.controlIQProSupported)
        #expect(bits.controllerVariant == .controlIQ)   // CIQ present, Pro absent ⇒ classic
    }

    @Test func controlIQProBitDiscriminatesTheControllerVariant() {
        // A Mobi-class pump advertising Control-IQ+ (bit 23) ⇒ .controlIQPro (the O7 discriminator).
        let pro = PumpFeaturesV1Response(cargo: cargo(controlIQ | controlIQPro | blePumpControl))
        let bits = TandemBackend.featureBits(from: pro)
        #expect(bits.controlIQProSupported)
        #expect(bits.controllerVariant == .controlIQPro)
        // No CIQ bit at all ⇒ no controller, regardless of other bits.
        #expect(TandemBackend.featureBits(from: PumpFeaturesV1Response(cargo: cargo(blePumpControl)))
                .controllerVariant == .none)
    }

    @Test func emptyCargoIsAllFalse() {
        let bits = TandemBackend.featureBits(from: PumpFeaturesV1Response(cargo: []))
        #expect(!bits.controlIQSupported && !bits.basalLimitSupported && !bits.blePumpControlSupported)
        #expect(!bits.controlIQProSupported && bits.controllerVariant == .none)
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
