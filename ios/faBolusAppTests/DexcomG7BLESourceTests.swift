import Testing
import Foundation
@testable import faBolus
import faBolusCore
import G7SensorKit

/// 09.22-01 Task 1 (the phase's tracer) — proves the STABLE per-connection G7 sensor-time anchor
/// end to end (D-02, closing the A2 self-defeat): a passively-read G7 glucose frame is dated against
/// an anchor that is bootstrapped ONCE from a near-real-time message and then held stable for the
/// life of the connection — never re-derived per message (that per-message reset IS the A2 bug). A
/// delayed/batched frame (sensor time far ahead of the stable anchor) computes a wall time in the
/// FUTURE and is rejected by the existing future-skew check, so it never becomes `latest`; a
/// normal-cadence reading still updates `latest` and fails over through `GlucoseArbiter.merge`.
/// Drives the decode path directly via the internal `ingest(glucoseFrame:)` seam — no CoreBluetooth,
/// no simulator BLE stack (mirrors `DexcomG6BLESourceTests`' technique of manipulating sensor-side
/// numbers, not wall time).
@MainActor
struct DexcomG7BLESourceTests {

    // MARK: - Synthetic G7 glucose frame builder (opcode 0x4e, no CRC — G7GlucoseMessage decodes on
    // length + opcode only). Byte layout per `G7GlucoseMessage.init(data:)`:
    //   [0]=0x4e op  [1]=0x00 status  [2..6]=messageTimestamp(LE u32)  [6..8]=sequence(LE u16)
    //   [10..12]=age(LE u16)  [12..14]=glucose(LE u16)  [14]=algorithmState  [15]=trend(i8)
    //   [16..18]=predicted(LE u16, 0xffff=nil)  [18]=display-only flag byte

    private static func glucoseFrame(messageTimestamp: UInt32, age: UInt16, glucose: UInt16,
                                     state: UInt8 = 0x06, sequence: UInt16 = 1, trend: Int8 = 0) -> Data {
        var d = [UInt8](repeating: 0, count: 19)
        d[0] = 0x4e
        d[1] = 0x00
        let mt = withUnsafeBytes(of: messageTimestamp.littleEndian) { Array($0) }
        d[2] = mt[0]; d[3] = mt[1]; d[4] = mt[2]; d[5] = mt[3]
        let sq = withUnsafeBytes(of: sequence.littleEndian) { Array($0) }
        d[6] = sq[0]; d[7] = sq[1]
        d[9] = 0x01
        let ag = withUnsafeBytes(of: age.littleEndian) { Array($0) }
        d[10] = ag[0]; d[11] = ag[1]
        let gl = withUnsafeBytes(of: glucose.littleEndian) { Array($0) }
        d[12] = gl[0]; d[13] = gl[1]
        d[14] = state
        d[15] = UInt8(bitPattern: trend)
        d[16] = 0xff; d[17] = 0xff
        d[18] = 0x00
        return Data(d)
    }

    private static func stalePumpSnapshot(_ glucose: Int, ageSec: TimeInterval) -> PumpSnapshot {
        var s = PumpSnapshot()
        s.glucose = glucose
        s.glucoseDate = Date().addingTimeInterval(-ageSec)
        s.trend = GlucoseTrend.flat.rawValue
        return s
    }

    // MARK: - Bootstrap + happy path

    /// A near-real-time frame (small `age`) bootstraps the anchor and becomes `latest`, dated
    /// materially close to the receipt instant — not artificially old.
    @Test func nearRealTimeFrameBootstrapsAnchorAndBecomesLatest() {
        let source = DexcomG7BLESource()
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 1000, age: 0, glucose: 120))
        #expect(source.latest?.mgdl == 120)
        guard let sample = source.latest else { return }
        let age = Date().timeIntervalSince(sample.date)
        #expect(abs(age) < 2, "a near-real-time bootstrap frame must date ≈ the receipt instant, got \(age)s")
    }

    // MARK: - A2 self-defeat closed

    /// After bootstrapping on msg1, a delayed/batched frame msg2 (1200 sensor-seconds advanced with
    /// ~zero real elapsed time) computes a wall time ≈20 min in the FUTURE against the STABLE anchor
    /// and is rejected by the future-skew check — `latest` must stay msg1's value. Under the old
    /// per-message reset, msg2 re-anchored from itself and read as fresh (the A2 bug).
    @Test func delayedBatchedFrameIsRejectedAnchorHeldStable() {
        let source = DexcomG7BLESource()
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 1000, age: 0, glucose: 120))
        #expect(source.latest?.mgdl == 120)
        // 1200 sensor-seconds ahead, age=0 (the sensor had no idea delivery would be delayed), same instant.
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 2200, age: 0, glucose: 200))
        #expect(source.latest?.mgdl == 120,
                "a batched/delayed frame must NOT silently become the fresh latest (A2 closed)")
    }

    // MARK: - No overcorrection

    /// The fix must not reject ordinary readings. After a stable bootstrap, a reading dating to a
    /// plausible recent wall time (300s off the stable anchor — dated to the recent past to stay
    /// clock-injection-free, mirroring `DexcomG6BLESourceTests`' own technique) is ACCEPTED and
    /// updates `latest`.
    @Test func ordinaryCadenceReadingIsAcceptedAndUpdatesLatest() {
        let source = DexcomG7BLESource()
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 1000, age: 0, glucose: 100))
        #expect(source.latest?.mgdl == 100)
        // A reading 300 sensor-seconds off the stable anchor, dating to the recent past → accepted.
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 700, age: 0, glucose: 110))
        #expect(source.latest?.mgdl == 110,
                "an ordinary-cadence reading at a plausible wall time must still be accepted")
        guard let sample = source.latest else { return }
        let age = Date().timeIntervalSince(sample.date)
        #expect(abs(age - 300) < 2, "the accepted reading must date ~300s off the stable anchor, got \(age)s")
    }

    // MARK: - Arbiter failover (unchanged)

    /// An anchored, in-range G7 sample flows through `GlucoseArbiter.merge` unchanged — a stale-pump
    /// snapshot fails over to the decoded mgdl with `.failover` provenance.
    @Test func anchoredSampleFailsOverThroughArbiterWhenPumpStale() {
        let source = DexcomG7BLESource()
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 1000, age: 0, glucose: 142))
        #expect(source.latest?.mgdl == 142)

        let pump = Self.stalePumpSnapshot(100, ageSec: 10 * 60)
        let (snap, _, prov) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: source)
        #expect(snap.glucose == 142)
        #expect(prov == .failover(sourceID: "dexcom-g7-ble", reason: .pumpStale))
    }

    // MARK: - Fail-closed pre-anchor

    /// A frame that is NOT bootstrap-eligible (self-reported `age` beyond `anchorBootstrapMaxAge`)
    /// arriving before any anchor exists does NOT become the trusted `latest`, and the arbiter does
    /// not fail over to this source — it has no usable value.
    @Test func ineligibleFrameBeforeAnchorNeverBecomesLatestOrFailsOver() {
        let source = DexcomG7BLESource()
        // age=200s > anchorBootstrapMaxAge (60s): a batched/old first frame must not bootstrap.
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 5000, age: 200, glucose: 150))
        #expect(source.latest == nil,
                "a frame ineligible to bootstrap the anchor must never become the trusted `latest`")

        let pump = Self.stalePumpSnapshot(100, ageSec: 10 * 60)
        let (snap, _, prov) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: source)
        #expect(prov == .pump, "arbiter must not fail over to a source reporting no usable value")
        #expect(snap.glucose == 100)
    }

    // MARK: - Task 3: stop() lifecycle reset (D-14 / W-02)

    /// W-02: `stop()` must clear the sensor-time anchor so a fresh connection re-bootstraps it (no
    /// live CoreBluetooth — drives the anchor via the ingest seam).
    @Test func stopClearsSensorAnchorSoFreshConnectionRebootstraps() {
        let source = DexcomG7BLESource()
        source.ingest(glucoseFrame: Self.glucoseFrame(messageTimestamp: 1000, age: 0, glucose: 120))
        #expect(source.latest?.mgdl == 120)
        #expect(source.anchorIsSetForTesting, "a bootstrapped frame must set the anchor")
        source.stop()
        #expect(!source.anchorIsSetForTesting,
                "stop() must clear the sensor-time anchor so a later connection re-bootstraps (W-02)")
    }

    /// W-02: after start() → stop() → start(), the second start() is NOT a permanent no-op — stop()
    /// resets the central so start() re-arms.
    @Test func stopResetsCentralSoLaterStartReArms() async {
        let source = DexcomG7BLESource()
        await source.start()
        #expect(source.isArmedForTesting, "start() must arm the central")
        source.stop()
        #expect(!source.isArmedForTesting, "stop() must reset the central (W-02)")
        await source.start()
        #expect(source.isArmedForTesting, "a second start() after stop() must re-arm, not be a permanent no-op")
    }
}
