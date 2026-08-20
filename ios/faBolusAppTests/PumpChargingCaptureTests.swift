import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Phase 09.27 Plan 01 (D-01/D-02/D-03) — the op-145 apply-site truthfulness guard. Mirrors
/// `CartridgeReadinessFailClosedTests`'s apply-site pattern: drive a real, CRC'd frame through
/// `TandemBackend.injectStatusFrameForTesting` (the REAL parse + `PumpResponseApplier.apply` path,
/// no CoreBluetooth) and assert `snapshot.batteryCharging`.
///
/// jwoglom's V2 javadoc notes the extra V2 bytes (incl. `chargingStatus`) "often read 0" — the wire
/// semantics of a genuine `chargingStatus == 1` are UNVERIFIED-GUESS (Phase-11 bench-gated). This
/// suite proves the app-side capture is at least truthful and fail-closed: only a positive `== 1`
/// ever reads as charging; every other/absent value reads as not-charging, never a false badge.
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

    /// byte-2 == 2 / 255 (any non-1 value) -> `batteryCharging == false` — fail-closed (D-03): the app
    /// never over-claims a state the pump did not positively report `== 1`.
    @Test func anyOtherChargingStatusValueFailsClosedToNotCharging() {
        for other in [2, 255] {
            let b = TandemBackend(testTransport: FakePumpTransport())
            b.injectStatusFrameForTesting(Self.currentBatteryV2Frame(batteryPercent: 50, chargingStatus: other))
            #expect(!b.snapshot.batteryCharging, "chargingStatus == \(other) must NOT read as charging")
        }
    }

    /// A snapshot that never saw an op-145 reply -> `batteryCharging == false` (default, D-03).
    @Test func aSnapshotThatNeverSawOp145DefaultsToNotCharging() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(!b.snapshot.batteryCharging)
    }
}
