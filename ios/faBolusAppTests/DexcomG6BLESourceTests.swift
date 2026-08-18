import Testing
import Foundation
@testable import faBolus
import faBolusCore
import DexcomG6Kit

/// 09.20-01 Task 1 (the phase's tracer) — proves the sensor-time-anchored G6 decode path end to end:
/// a passively-observed `transmitterTimeRx` (opcode 0x25) anchors `activationDate`; a glucose frame's
/// sensor-relative timestamp then converts to a true wall date via that anchor (D-08a), NOT `Date()`
/// at receipt — and that anchored sample flows unmodified through `GlucoseArbiter.merge` (D-09/D-10).
/// Drives the decode path directly via the internal `ingest(controlFrame:)` seam — no CoreBluetooth,
/// no simulator BLE stack.
@MainActor
struct DexcomG6BLESourceTests {

    // MARK: - Synthetic frame builders (self-contained CRC-CCITT/XModem; DexcomG6Kit's own
    // `appendingCRC()`/`isCRCValid` are internal to that module and not visible here).

    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1 ^ 0x1021) : (crc << 1) }
        }
        return crc
    }

    private static func appendingCRC(_ body: Data) -> Data {
        var d = body
        let c = crc16(Array(body))
        d.append(UInt8(c & 0xff)); d.append(UInt8(c >> 8))
        return d
    }

    /// opcode 0x25 transmitterTimeRx frame: op(1) status(1) currentTime(4) sessionStartTime(4) pad(4) crc(2)
    private static func timeFrame(currentTime: UInt32, sessionStartTime: UInt32) -> Data {
        var body = Data()
        body.append(0x25)
        body.append(0x00)
        body.append(contentsOf: withUnsafeBytes(of: currentTime.littleEndian) { Array($0) })
        body.append(contentsOf: withUnsafeBytes(of: sessionStartTime.littleEndian) { Array($0) })
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return appendingCRC(body)
    }

    /// opcode 0x4f G6 glucose frame: op(1) status(1) sequence(4) | timestamp(4) glucose(2) state(1) trend(1) | crc(2)
    private static func glucoseFrame(sequence: UInt32 = 1, timestamp: UInt32, glucose: UInt16,
                                     state: UInt8 = 0x06, trend: Int8 = 0) -> Data {
        var body = Data()
        body.append(0x4f)
        body.append(0x00)
        body.append(contentsOf: withUnsafeBytes(of: sequence.littleEndian) { Array($0) })
        body.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })
        body.append(contentsOf: withUnsafeBytes(of: glucose.littleEndian) { Array($0) })
        body.append(state)
        body.append(UInt8(bitPattern: trend))
        return appendingCRC(body)
    }

    private static func stalePumpSnapshot(_ glucose: Int, ageSec: TimeInterval) -> PumpSnapshot {
        var s = PumpSnapshot()
        s.glucose = glucose
        s.glucoseDate = Date().addingTimeInterval(-ageSec)
        s.trend = GlucoseTrend.flat.rawValue
        return s
    }

    // MARK: - Task 1 behaviors

    /// A glucose frame delivered after a transmitterTimeRx anchor dates to the sensor-anchored wall
    /// time (activationDate + sensor timestamp), NOT Date() at receipt.
    @Test func anchoredGlucoseFrameDatesToSensorTimeNotReceiptTime() {
        let source = DexcomG6BLESource()
        let currentTime: UInt32 = 3600      // transmitter's current sensor-relative clock, seconds
        let glucoseTimestamp: UInt32 = 3000 // 600s (10 min) behind currentTime
        source.ingest(controlFrame: Self.timeFrame(currentTime: currentTime, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: glucoseTimestamp, glucose: 120))

        let sample = source.latest
        #expect(sample != nil)
        guard let sample else { return }
        #expect(sample.mgdl == 120)
        let age = Date().timeIntervalSince(sample.date)
        // Expected age ≈ currentTime - glucoseTimestamp == 600s — materially > 0, not "now".
        #expect(abs(age - 600) < 1.5, "expected age ≈600s (sensor-anchored), got \(age)s")
        #expect(age > 60, "an un-anchored receipt-Date() stamp would read age ≈0, not ≈600s")
    }

    /// A batch of glucose frames whose sensor timestamps advance by 300s, delivered back-to-back with
    /// no real elapsed time, compute distinct, correctly-ordered wall times — never all "now"
    /// (D-08a, Pitfall 3).
    @Test func batchedFramesWithAdvancingSensorTimestampsComputeDistinctIncreasingDates() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 10_000, sessionStartTime: 60))

        source.ingest(controlFrame: Self.glucoseFrame(sequence: 1, timestamp: 9_000, glucose: 100))
        let d1 = source.latest?.date
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 2, timestamp: 9_300, glucose: 105))
        let d2 = source.latest?.date
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 3, timestamp: 9_600, glucose: 110))
        let d3 = source.latest?.date

        #expect(d1 != nil && d2 != nil && d3 != nil)
        guard let d1, let d2, let d3 else { return }
        #expect(d1 < d2 && d2 < d3, "batched frames must compute distinct, increasing dates")
        #expect(abs(d2.timeIntervalSince(d1) - 300) < 1.5)
        #expect(abs(d3.timeIntervalSince(d2) - 300) < 1.5)
    }

    /// The anchored sample flows through `GlucoseArbiter.merge` unchanged (D-09) — a stale-pump
    /// snapshot fails over to the decoded mgdl with `.failover` provenance (D-10).
    @Test func anchoredSampleFailsOverThroughArbiterWhenPumpStale() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 142))
        #expect(source.latest?.mgdl == 142)

        let pump = Self.stalePumpSnapshot(100, ageSec: 10 * 60)
        let (snap, _, prov) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: source)
        #expect(snap.glucose == 142)
        #expect(prov == .failover(sourceID: "dexcom-g6-ble", reason: .pumpStale))
    }

    /// Fail-closed pre-anchor (D-08a/D-10): a glucose frame decoded BEFORE any transmitterTimeRx
    /// anchor has been observed is NOT published as the trusted `latest` calc input, and the arbiter
    /// does not fail over to this source (it has no usable value).
    @Test func unanchoredGlucoseFrameNeverBecomesTrustedLatestOrFailsOverInArbiter() {
        let source = DexcomG6BLESource()
        // No transmitterTimeRx observed yet.
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 100, glucose: 150))
        #expect(source.latest == nil, "an un-anchored frame must never become the trusted `latest`")

        let pump = Self.stalePumpSnapshot(100, ageSec: 10 * 60)
        let (snap, _, prov) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: source)
        #expect(prov == .pump, "arbiter must not fail over to a source reporting no usable value")
        #expect(snap.glucose == 100)
    }

    // MARK: - Task 3 (09.20-02, D-08a/D-08b) — rate-of-change, implausible-age, never-anchored bound.

    /// D-08b: an out-of-[40,400] frame (Task 2's decode-time gate) never becomes `latest` end-to-end
    /// through `ingest`, even after a real anchor is established.
    @Test func outOfRangeFrameNeverBecomesLatestThroughIngest() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 500))
        #expect(source.latest == nil, "an out-of-range frame must never become `latest`")
    }

    /// D-08b rate-of-change ceiling: a frame implying a per-minute rate ABOVE the ceiling (12 mg/dL/min
    /// default) vs the prior anchored `latest` is rejected — `latest` keeps the prior reading.
    @Test func implausibleRateOfChangeIsRejected() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 1, timestamp: 3300, glucose: 120))
        #expect(source.latest?.mgdl == 120)

        // 60s later (1 min), a 200 mg/dL jump == 200 mg/dL/min, far above the 12 mg/dL/min ceiling.
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 2, timestamp: 3360, glucose: 320))
        #expect(source.latest?.mgdl == 120, "implausible rate must be rejected; `latest` keeps the prior reading")
    }

    /// A genuine fast-but-plausible excursion (well under the ceiling) is accepted — the ceiling only
    /// catches decode corruption, not real physiology.
    @Test func plausibleFastExcursionIsAccepted() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 1, timestamp: 3300, glucose: 120))
        #expect(source.latest?.mgdl == 120)

        // 60s later, an 8 mg/dL jump == 8 mg/dL/min, under the 12 mg/dL/min ceiling.
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 2, timestamp: 3360, glucose: 128))
        #expect(source.latest?.mgdl == 128, "a plausible fast excursion must be accepted")
    }

    /// OWNER CORRECTNESS REQUIREMENT: the rate gate is per-MINUTE, not absolute delta. A large glucose
    /// change across a LARGE time gap (e.g. a BLE disconnect that missed several ~5-min cycles) must
    /// yield a SMALL per-minute rate and must NOT be rejected (and must not throw/crash).
    @Test func largeChangeAcrossLargeGapIsNotRejected() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 100, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 1, timestamp: 90, glucose: 90))
        #expect(source.latest?.mgdl == 90)

        // Missed several cycles: 30 min gap (1800s), a 150 mg/dL swing == 5 mg/dL/min, well under 12.
        source.ingest(controlFrame: Self.timeFrame(currentTime: 1_900, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 2, timestamp: 1_890, glucose: 240))
        #expect(source.latest?.mgdl == 240, "a large change across a large time gap implies a small per-minute rate and must be accepted")
    }

    /// OWNER CORRECTNESS REQUIREMENT: with NO valid predecessor (first reading after (re)connect —
    /// `latest` is nil), the rate check is SKIPPED entirely; a large absolute value alone is not a
    /// rejection reason (range + CRC + anchor-age checks still apply and pass here).
    @Test func firstReadingAfterConnectSkipsRateCheck() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        // First reading ever (`latest` is nil) — a big in-range value must not be rejected for "rate".
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 380))
        #expect(source.latest?.mgdl == 380, "no predecessor means the rate check must be skipped, not fail-rejected")
    }

    /// OWNER CORRECTNESS REQUIREMENT: Δt ≈ 0 (duplicate/near-duplicate timestamp) must not divide by
    /// zero and must not false-reject.
    @Test func nearZeroDeltaTDoesNotDivideByZeroOrFalseReject() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 1, timestamp: 3590, glucose: 120))
        #expect(source.latest?.mgdl == 120)

        // Same sensor timestamp again (Δt == 0), a different value — must not crash or be rejected.
        source.ingest(controlFrame: Self.glucoseFrame(sequence: 2, timestamp: 3590, glucose: 130))
        #expect(source.latest?.mgdl == 130, "Δt≈0 must skip the rate check, not divide-by-zero or false-reject")
    }

    /// D-08a implausible-age rejection: a frame anchored beyond `GlucoseFreshness.futureSkewTolerance`
    /// in the future is rejected (decode/anchor-arithmetic error), not stamped as fresh.
    @Test func futureDatedBeyondSkewToleranceIsRejected() {
        let source = DexcomG6BLESource()
        // currentTime=100 (anchor ≈ now-100s); glucose timestamp FAR ahead of currentTime implies a
        // wall date far in the future.
        source.ingest(controlFrame: Self.timeFrame(currentTime: 100, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 100 + UInt32(GlucoseFreshness.futureSkewTolerance) + 120, glucose: 120))
        #expect(source.latest == nil, "a frame anchored far in the future must be rejected, not trusted as fresh")
    }

    /// D-08a implausible-age rejection: an absurdly-old anchored date (decode/anchor arithmetic gone
    /// wrong, not genuine staleness) is rejected rather than published (even though genuine staleness
    /// is GlucoseFreshness's separate job downstream).
    @Test func absurdlyOldAnchoredDateIsRejected() {
        let source = DexcomG6BLESource()
        // A huge currentTime with a much smaller glucose timestamp anchors far in the past — well
        // beyond the 24h implausible-age bound.
        source.ingest(controlFrame: Self.timeFrame(currentTime: 200_000, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 1_000, glucose: 120))
        #expect(source.latest == nil, "an absurdly-old anchored date must be rejected")
    }

    /// Never-anchored fail-closed (Warning 1): a RUN of un-anchored frames never accumulates into a
    /// trusted reading — `latest` stays nil across repeated ingests, not just the first one.
    @Test func repeatedUnanchoredFramesNeverAccumulateIntoTrustedLatest() {
        let source = DexcomG6BLESource()
        for i in 0..<5 {
            source.ingest(controlFrame: Self.glucoseFrame(sequence: UInt32(i), timestamp: UInt32(100 + i * 10), glucose: 120))
        }
        #expect(source.latest == nil, "a run of un-anchored frames must never accumulate into a trusted `latest`")
    }

    /// No-anchor bound (Warning 1): once the source has been "connected" (per `setConnectedAtForTesting`)
    /// longer than `DexcomG6BLESource.noAnchorBound` WITHOUT ever observing a transmitterTimeRx anchor,
    /// it reports `.stale` rather than trusting any fallback-dated frame.
    @Test func reportsStaleAfterNoAnchorBoundWithoutEverAnchoring() {
        let source = DexcomG6BLESource()
        source.setConnectedAtForTesting(Date().addingTimeInterval(-(DexcomG6BLESource.noAnchorBound + 30)))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 100, glucose: 120))
        #expect(source.latest == nil)
        #expect(source.status == .stale, "beyond the no-anchor bound with no anchor ever observed, status must be .stale")
    }

    /// Regression guard for the happy path: once a FRESH anchor has been observed (within the bound),
    /// glucose anchors normally — the bound must not fire just because the source has been connected a
    /// while if an anchor did in fact arrive.
    @Test func anchorsNormallyWhenFreshAnchorObservedWithinBound() {
        let source = DexcomG6BLESource()
        source.setConnectedAtForTesting(Date().addingTimeInterval(-(DexcomG6BLESource.noAnchorBound + 30)))
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 120))
        #expect(source.latest?.mgdl == 120, "a fresh anchor must still work even if the source has been connected a long time")
        #expect(source.status == .connected)
    }
}
