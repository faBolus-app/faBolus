import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Only chargingStatus == 1 applies as charging; every other or absent value fails closed. Wire
/// semantics of a genuine == 1 remain unverified.
@Suite(.serialized) @MainActor
struct PumpChargingCaptureTests {

    /// Builds a real, CRC'd op-145 `CurrentBatteryV2Response` frame. `props.size == 11`, so the
    /// cargo must be exactly 11 bytes (byte 0 = currentBatteryAbc, byte 1 = batteryPercent, byte 2 =
    /// chargingStatus, bytes 3...10 = the documented-unknown V2 tail) or `ResponseParser` rejects it
    /// with `cargoLengthMismatch`.
    private static func currentBatteryV2Frame(batteryPercent: Int, chargingStatus: Int) -> [UInt8] {
        var cargo = [UInt8](repeating: 0, count: 11)
        cargo[0] = 0
        cargo[1] = UInt8(truncatingIfNeeded: batteryPercent)
        cargo[2] = UInt8(truncatingIfNeeded: chargingStatus)
        return FakePumpTransport.frame(opCode: CurrentBatteryV2Response.props.opCode, cargo: cargo, signed: false)
    }

    /// byte-2 == 1 -> `batteryCharging == true` (the ONLY value that reads as charging).
    @Test func chargingStatusOneAppliesAsCharging() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(!b.snapshot.batteryCharging, "before any op-145 reply: fail-closed default false")

        b.injectStatusFrameForTesting(Self.currentBatteryV2Frame(batteryPercent: 78, chargingStatus: 1))
        #expect(b.snapshot.batteryCharging, "chargingStatus == 1 must apply as charging")
        #expect(b.snapshot.batteryPercent == 78, "batteryPercent still applies on the same frame")
    }

    /// byte-2 == 0 -> `batteryCharging == false`.
    @Test func chargingStatusZeroAppliesAsNotCharging() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.injectStatusFrameForTesting(Self.currentBatteryV2Frame(batteryPercent: 78, chargingStatus: 0))
        #expect(!b.snapshot.batteryCharging)
    }

    /// byte-2 == 2 / 255 (any non-1 value) -> `batteryCharging == false` — fail-closed: the app
    /// never over-claims a state the pump did not positively report `== 1`.
    @Test func anyOtherChargingStatusValueFailsClosedToNotCharging() {
        for other in [2, 255] {
            let b = TandemBackend(testTransport: FakePumpTransport())
            b.injectStatusFrameForTesting(Self.currentBatteryV2Frame(batteryPercent: 50, chargingStatus: other))
            #expect(!b.snapshot.batteryCharging, "chargingStatus == \(other) must NOT read as charging")
        }
    }

    /// A snapshot that never saw an op-145 reply -> `batteryCharging == false` (default).
    @Test func aSnapshotThatNeverSawOp145DefaultsToNotCharging() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(!b.snapshot.batteryCharging)
    }
}
