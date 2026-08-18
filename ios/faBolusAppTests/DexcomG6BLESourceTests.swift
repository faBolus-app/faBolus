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

    // MARK: - Task 3 (09.20-02, D-08a/D-08b) — range, implausible-age, never-anchored bound.
    //
    // NOTE (owner review): a rate-of-change (Δmg/dL ÷ Δt) rejection gate + its dedicated tests
    // (implausible-rate-rejected, plausible-fast-excursion-accepted, large-gap/no-predecessor/Δt≈0
    // rate-specific cases) were implemented here and then REMOVED — ungrounded against every mirrored
    // reference (CGMBLEKit/Loop/xDrip4iOS), and it risked rejecting a genuine fast excursion. The range,
    // CRC, anchor, never-anchored, and freshness gates below remain the grounded fail-closed set.

    /// D-08b: an out-of-[40,400] frame (Task 2's decode-time gate) never becomes `latest` end-to-end
    /// through `ingest`, even after a real anchor is established.
    @Test func outOfRangeFrameNeverBecomesLatestThroughIngest() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 500))
        #expect(source.latest == nil, "an out-of-range frame must never become `latest`")
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

    // MARK: - 09.22-01 Task 3: stop() lifecycle reset (D-14 / W-02)

    /// W-02: `stop()` must clear the sensor-time anchor (`activationDate`) so a fresh connection
    /// re-anchors — no live CoreBluetooth (drives the anchor via the ingest seam).
    @Test func stopClearsSensorAnchorSoFreshConnectionReanchors() {
        let source = DexcomG6BLESource()
        source.ingest(controlFrame: Self.timeFrame(currentTime: 3600, sessionStartTime: 60))
        source.ingest(controlFrame: Self.glucoseFrame(timestamp: 3590, glucose: 120))
        #expect(source.latest?.mgdl == 120)
        #expect(source.activationDateForTesting != nil, "a transmitterTimeRx must set the anchor")
        source.stop()
        #expect(source.activationDateForTesting == nil,
                "stop() must clear the sensor-time anchor so a later connection re-anchors (W-02)")
    }

    /// W-02: after start() → stop() → start(), the second start() is NOT a permanent no-op — stop()
    /// resets the central so start() re-arms.
    @Test func stopResetsCentralSoLaterStartReArms() async {
        let source = DexcomG6BLESource()
        await source.start()
        #expect(source.isArmedForTesting, "start() must arm the central")
        source.stop()
        #expect(!source.isArmedForTesting, "stop() must reset the central (W-02)")
        await source.start()
        #expect(source.isArmedForTesting, "a second start() after stop() must re-arm, not be a permanent no-op")
    }

    // MARK: - H-02 (09.20-REVIEW.md) — RSSI tie-break selection
    //
    // `strongestCandidateIndex` is the pure, CoreBluetooth-free decision logic behind H-02's fix:
    // when no transmitter ID is configured, `didDiscover` collects candidate RSSI values over a short
    // window instead of connecting to the first Dexcom-advertising peripheral, then picks the
    // strongest signal via this function. It's tested directly here (not via a live/simulated
    // `CBCentralManager`, which can't be driven from XCTest/Swift Testing) because a real
    // `CBPeripheral` can't be constructed outside CoreBluetooth.

    /// CoreBluetooth RSSI is negative dBm; closer to 0 is stronger/nearer — the numerically-highest
    /// value must win, regardless of discovery order.
    @Test func strongestCandidateIndexPrefersHighestRSSIRegardlessOfOrder() {
        #expect(DexcomG6BLESource.strongestCandidateIndex([-70, -40, -85]) == 1,
                "the strongest (closest-to-zero) RSSI must win, not the first-discovered")
        #expect(DexcomG6BLESource.strongestCandidateIndex([-40, -70, -85]) == 0,
                "when the first-discovered candidate genuinely has the strongest signal, it still wins")
    }

    /// A tie keeps the first-seen candidate — a later reading must be STRICTLY stronger to displace
    /// the current best, so discovery order is a stable, deterministic tie-break.
    @Test func strongestCandidateIndexBreaksTiesByFirstSeen() {
        #expect(DexcomG6BLESource.strongestCandidateIndex([-50, -50, -90]) == 0,
                "equal RSSI values must keep the first-seen index, not the last")
    }

    /// No candidates observed yet (e.g. the collection window elapsed with nothing seen, or `stop()`
    /// already cleared the list) must return nil, never crash or fabricate an index.
    @Test func strongestCandidateIndexOnEmptyReturnsNil() {
        #expect(DexcomG6BLESource.strongestCandidateIndex([]) == nil)
    }

    /// A single candidate is trivially "strongest" — the common case (only one real Dexcom nearby)
    /// must not require a second reading to resolve.
    @Test func strongestCandidateIndexWithSingleCandidateReturnsIt() {
        #expect(DexcomG6BLESource.strongestCandidateIndex([-65]) == 0)
    }

    /// Source-scan wiring check: `strongestCandidateIndex` must actually be CALLED from `didDiscover`
    /// (not just declared and dead) — otherwise the four behavioral tests above would be proving the
    /// correctness of a function nothing in the delegate path ever invokes.
    @Test func strongestCandidateIndexIsWiredIntoDidDiscover() throws {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: URL?
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared")
            if fm.fileExists(atPath: candidate.path) { root = candidate.deletingLastPathComponent(); break }
            probe = probe.deletingLastPathComponent()
        }
        let sourcePath = "ios/faBolus/Data/Sources/DexcomG6BLESource.swift"
        let code = try #require(root.flatMap { try? String(contentsOf: $0.appendingPathComponent(sourcePath), encoding: .utf8) },
                                "could not resolve \(sourcePath) from #filePath=\(#filePath)")
        guard let start = code.range(of: "func centralManager(_ central: CBCentralManager, didDiscover"),
              let end = code.range(of: "func centralManager(_ central: CBCentralManager, didConnect",
                                    range: start.upperBound..<code.endIndex) else {
            Issue.record("could not isolate the didDiscover...didConnect span")
            return
        }
        let span = String(code[start.upperBound..<end.lowerBound])
        #expect(span.contains("strongestCandidateIndex("),
                "didDiscover (or its RSSI-selection helper, defined in the same span) must call strongestCandidateIndex — otherwise the RSSI tie-break logic is dead code (H-02)")
        #expect(span.contains("rssiCandidates"),
                "didDiscover must collect RSSI candidates when no transmitter ID is configured (H-02)")
    }
}
