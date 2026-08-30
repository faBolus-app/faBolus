import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Deterministic fake transport for driving the REAL `TandemBackend.perform` flow with no
/// CoreBluetooth. Scripts a reply per awaited response opcode (a valid response frame, a dropped/lost
/// response, or a transport error) and records what was written so tests can assert the exact request
/// cargo and the exact number of initiate writes.
@MainActor
final class FakePumpTransport: PumpTransport {

    var writePolicy: PumpBLEClient.WritePolicy = .readOnly

    /// What to do when a given response opcode is awaited.
    enum Reply {
        case frame([UInt8])  // a valid response frame → parses to the typed response
        case garbage  // an unparseable frame (post-write parse failure)
        case tx(PumpTransactionCoordinator.TxError)  // timeout / connectionLost (write went out, reply lost)
    }

    /// Queues of replies keyed by RESPONSE opcode; each awaited request pops the next. An empty/absent
    /// queue defaults to a dropped response (`.timedOut`).
    private var scripts: [UInt8: [Reply]] = [:]
    /// A synchronous pre-write failure for the next `send`/`sendAwaitingResponse` (opcode-scoped).
    var preWriteError: [UInt8: Error] = [:]

    /// Every message actually written (opcode, cargo, signed, allowInsulinDelivery), in order.
    private(set) var sent: [(opCode: UInt8, cargo: [UInt8], signed: Bool, allowDelivery: Bool)] = []
    /// Response opcodes awaited, in order.
    private(set) var awaited: [UInt8] = []
    /// Called at the moment a response opcode is awaited (before the reply), so a test can mutate backend
    /// state mid-flow — e.g. flip the connection to simulate a mid-delivery disconnect.
    var willAwait: ((UInt8) -> Void)?

    var initiateWriteCount: Int { sent.filter { $0.opCode == InitiateBolusRequest.props.opCode }.count }
    func lastSent(_ opCode: UInt8) -> (opCode: UInt8, cargo: [UInt8], signed: Bool, allowDelivery: Bool)? {
        sent.last { $0.opCode == opCode }
    }

    func script(_ responseOpCode: UInt8, _ replies: Reply...) {
        scripts[responseOpCode, default: []].append(contentsOf: replies)
    }

    // MARK: PumpTransport

    @discardableResult
    func withWritePolicy<T>(
        _ policy: PumpBLEClient.WritePolicy,
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        writePolicy = policy
        defer { writePolicy = .readOnly }
        return try await body()
    }

    /// Incrementing wire txId, mirroring the real `PumpBLEClient`'s `txIds.nextThenIncrement()`. Lets a
    /// test exercise the op77 txId-echo correlation (debug pump-pairing-loop-api25, mechanism B): a read's
    /// returned txId is what the pump echoes back in an inbound frame's frame[1].
    private var nextTxId: UInt8 = 0

    @discardableResult
    func send(
        _ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
        allowInsulinDelivery: Bool
    ) throws -> UInt8 {
        if let e = preWriteError[message.opCode] { throw e }
        sent.append((message.opCode, message.cargo, message.signed, allowInsulinDelivery))
        let txId = nextTxId
        nextTxId = nextTxId &+ 1
        return txId
    }

    func sendAwaitingResponse(
        _ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
        allowInsulinDelivery: Bool, responseOpCode: UInt8?,
        deadline: TimeInterval, serialized: Bool = false
    ) async throws -> [UInt8] {
        // A pre-write failure throws before the write is recorded (clean pre-write failure).
        if let e = preWriteError[message.opCode] { throw e }
        // The write goes out first (matches the real client), THEN we await the reply.
        sent.append((message.opCode, message.cargo, message.signed, allowInsulinDelivery))
        guard let op = responseOpCode ?? message.props.responseOpCode else { throw PumpBLEClient.ClientError.notReady }
        awaited.append(op)
        willAwait?(op)
        let reply: Reply = {
            if var q = scripts[op], !q.isEmpty {
                let r = q.removeFirst()
                scripts[op] = q
                return r
            }
            return .tx(.timedOut(characteristic: message.characteristic, opCode: op))  // default: dropped
        }()
        switch reply {
        case .frame(let f): return f
        case .garbage: return [op, 0, 2, 0xDE, 0xAD, 0x00, 0x00]  // wrong length/crc → parse fails
        case .tx(let e): throw e
        }
    }

    // MARK: - Response frame builders (valid, CRC'd; parser strips the 24-byte HMAC on signed responses)

    /// `txId` sets frame[1] — the wire transaction id the pump echoes. Defaults to 0 (the historical
    /// behavior). The op77 correlation backstop (debug pump-pairing-loop-api25) keys on this echoed txId, so
    /// a NON-vacuous correlation test must be able to set it to a SPECIFIC outstanding read's txId (distinct
    /// from the FIFO-oldest) under a real multi-read burst.
    /// The session HMAC key the test backend holds by default (mirrors `TandemBackend.init(testTransport:)`'s
    /// `authKey` default of `[0x01]`). Signed response frames are signed with THIS so the parser-side
    /// HMAC verification passes on the delivery path — keep in sync with that init default.
    static let signedResponseTestKey: [UInt8] = [0x01]

    static func frame(opCode: UInt8, cargo: [UInt8], signed: Bool, txId: UInt8 = 0) -> [UInt8] {
        var body = cargo
        if signed {
            // The parser VERIFIES the 24-byte signed trailer (4-byte pumpTimeSinceReset +
            // 20-byte HMAC-SHA1), so build a VALID one under the test key rather than 24 zero bytes — this
            // lets the delivery-path tests exercise the real verify. The HMAC covers messageData
            // (`[opCode, txId, length] + cargo + pumpTime`) minus its last 20 bytes, i.e. everything before
            // the HMAC itself (byte-exact with ResponseParser / the oracle's PacketArrayList.validate).
            let pumpTime = [UInt8](repeating: 0, count: 4)
            let length = UInt8(cargo.count + 24)
            let signedOver: [UInt8] = [opCode, txId, length] + cargo + pumpTime
            let hmac = Packetize.doHmacSha1(signedOver, key: signedResponseTestKey)
            body = cargo + pumpTime + hmac
        }
        var f: [UInt8] = [opCode, txId, UInt8(body.count)] + body
        f += Bytes.calculateCRC16(f)
        return f
    }
    private static func le2(_ v: Int) -> [UInt8] { Bytes.firstTwoBytesLittleEndian(v) }

    static func timeResponse(currentTime: UInt32 = 1000) -> [UInt8] {
        frame(
            opCode: TimeSinceResetResponse.props.opCode, cargo: Bytes.toUint32(currentTime) + Bytes.toUint32(0),
            signed: false)
    }
    static func permissionGranted(bolusId: Int) -> [UInt8] {
        frame(opCode: BolusPermissionResponse.props.opCode, cargo: [0] + le2(bolusId) + [0, 0, 0], signed: true)
    }
    static func permissionDenied(nack: Int = 7) -> [UInt8] {
        frame(opCode: BolusPermissionResponse.props.opCode, cargo: [1, 0, 0, 0, 0, UInt8(nack)], signed: true)
    }
    static func initiateAccepted(bolusId: Int) -> [UInt8] {
        frame(opCode: InitiateBolusResponse.props.opCode, cargo: [0] + le2(bolusId) + [0, 0, 0], signed: true)
    }
    static func initiateNack(bolusId: Int, statusType: Int = 3) -> [UInt8] {
        frame(
            opCode: InitiateBolusResponse.props.opCode, cargo: [1] + le2(bolusId) + [0, 0, UInt8(statusType)],
            signed: true)
    }
    /// statusId 0 = not active (bolus finished); 1/2 = active.
    static func currentBolusStatus(statusId: Int, bolusId: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 15)
        c[0] = UInt8(statusId)
        c[1] = le2(bolusId)[0]
        c[2] = le2(bolusId)[1]
        return frame(opCode: CurrentBolusStatusResponse.props.opCode, cargo: c, signed: false)
    }
    static func lastBolus(bolusId: Int, deliveredMilliunits: UInt32, status: Int = 3) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 24)
        c[0] = UInt8(status)
        c[1] = le2(bolusId)[0]
        c[2] = le2(bolusId)[1]
        let ts = Bytes.toUint32(1000)
        for i in 0..<4 { c[5 + i] = ts[i] }
        let dv = Bytes.toUint32(deliveredMilliunits)
        for i in 0..<4 { c[9 + i] = dv[i] }
        return frame(opCode: LastBolusStatusV2Response.props.opCode, cargo: c, signed: false)
    }

    /// op-109 `ControlIQIOBResponse` (size 17). Only `swan6hrIOB` (offset 12) drives `iobUnits`, the value
    /// `TandemBackend` reads; the other IOB fields are left zero. Delivered via `didReceiveFrame`, not the
    /// coordinator (these reads are fire-and-forget), so a test seeds it with `injectStatusFrameForTesting`.
    static func controlIQIOB(iobMilliunits: UInt32) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 17)
        let v = Bytes.toUint32(iobMilliunits)
        for i in 0..<4 { c[12 + i] = v[i] }  // swan6hrIOB
        return frame(opCode: ControlIQIOBResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-41 `CurrentBasalStatusResponse` (9 bytes: profileBasalRate@0-3, currentBasalRate@4-7, both
    /// little-endian milliunits/hr, then `basalModifiedBitmask`@8). Feeds
    /// `PumpSnapshot.basalRateUnitsPerHour` AND stamps `basalRateKnown`.
    /// `currentMilliunitsPerHour: 0` builds a GENUINE 0 U/hr reply — a suspend, or a 0 U/hr temp rate —
    /// which is the case that must stay distinguishable from "this read was never answered".
    ///
    /// NOTE the opcode is 41, not 77. `PumpSnapshot.basalRateKnown`'s doc comment said "op-77
    /// CurrentBasalStatusResponse"; op-77 is `ErrorResponse` (see `errorResponse` below). The comment
    /// was corrected alongside this builder.
    static func currentBasalStatus(currentMilliunitsPerHour: UInt32, profileMilliunitsPerHour: UInt32? = nil)
        -> [UInt8]
    {
        var c = [UInt8](repeating: 0, count: 9)
        let profile = Bytes.toUint32(profileMilliunitsPerHour ?? currentMilliunitsPerHour)
        let current = Bytes.toUint32(currentMilliunitsPerHour)
        for i in 0..<4 { c[i] = profile[i] }
        for i in 0..<4 { c[4 + i] = current[i] }
        return frame(opCode: CurrentBasalStatusResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-57 `HomeScreenMirrorResponse` (9 bytes). Byte 0 is `cgmTrendIconId` (0 = the pump's explicit
    /// **no arrow**; 2 = up, etc. — matching `CGMTrendIcon`). The pump's icon is authoritative, so a test
    /// can pin that a later client-side derivation never overwrites it. Byte 8 = `cgmDisplayData`.
    static func homeScreenMirror(trendIconId: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 9)
        c[0] = UInt8(trendIconId)
        c[8] = 1  // cgmDisplayData: the mirror carries live CGM display state
        return frame(opCode: HomeScreenMirrorResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-193 `CurrentEgvGuiDataV2Response` (8 bytes): a VALID reading (`egvStatusId` 1, mg/dL at offset 4)
    /// plus a signed `trendRate` at offset 7 that the client-side derivation turns into an arrow. Used to
    /// prove the derived arrow is only a cold-start bridge and never overwrites the pump's authoritative
    /// HomeScreenMirror trend. `trendRate` is 0.1 mg/dL/min units (30 ⇒ +3.0 ⇒ a rising arrow).
    static func currentEgvV2(mgdl: Int, trendRate: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let bg = le2(mgdl)
        c[4] = bg[0]
        c[5] = bg[1]  // cgmReading (LE short)
        c[6] = 1  // egvStatusId = 1 → hasValidReading
        c[7] = UInt8(bitPattern: Int8(truncatingIfNeeded: trendRate))  // signed trend rate
        return frame(opCode: CurrentEgvGuiDataV2Response.props.opCode, cargo: c, signed: false)
    }

    /// op-35 `CurrentEGVGuiDataResponse`, the V1 twin of `currentEgvV2` above (identical 8-byte layout).
    /// `TandemBackend.fastRead()`/`refreshGlucoseNow()`/`runPredictiveBurst()` send this request (op34)
    /// exclusively — never the V2 request (op192), which an older t:slim X2 firmware rejects with
    /// `ErrorResponse`/BAD_OPCODE and then drops the BLE link — see `.planning/debug/pump-pairing-loop.md`
    /// (on-device capture #6).
    static func currentEgvV1(mgdl: Int, trendRate: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let bg = le2(mgdl)
        c[4] = bg[0]
        c[5] = bg[1]  // cgmReading (LE short)
        c[6] = 1  // egvStatusId = 1 → hasValidReading
        c[7] = UInt8(bitPattern: Int8(truncatingIfNeeded: trendRate))  // signed trend rate
        return frame(opCode: CurrentEGVGuiDataResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-21 `LoadStatusResponse` (3 bytes: isLoadingActive@0, loadStateId@1, primeStatusId@2 — see the
    /// kit's `ResponseDirectTests`). Reply to the op20 `LoadStatusRequest` poll; feeds
    /// `PumpSnapshot.cartridgeLoadState` → the `cartridgeReadyForBolus` pre-guard. loadStateId 0/1/2
    /// (CHANGE_CARTRIDGE/LOAD_CARTRIDGE/PRIME_TUBING) ⇒ not ready; the idle/unknown default 6 ⇒ ready.
    static func loadStatus(isLoadingActive: Bool, loadStateId: Int) -> [UInt8] {
        frame(
            opCode: LoadStatusResponse.props.opCode,
            cargo: [isLoadingActive ? 1 : 0, UInt8(truncatingIfNeeded: loadStateId), 0], signed: false)
    }

    /// op-37 `InsulinStatusResponse` (4 bytes: currentInsulinAmount@0-1 little-endian, isEstimate@2,
    /// insulinLowAmount@3). Reply to the op-36 `InsulinStatusRequest` poll; feeds
    /// `PumpSnapshot.reservoirUnits`. `unitsRemaining: 0` builds a GENUINE empty-cartridge reply — the
    /// case that must stay distinguishable from "this read was never answered".
    static func insulinStatus(unitsRemaining: Int, isEstimate: Bool = false, lowAmount: Int = 0) -> [UInt8] {
        let u = le2(unitsRemaining)
        return frame(
            opCode: InsulinStatusResponse.props.opCode,
            cargo: [u[0], u[1], isEstimate ? 1 : 0, UInt8(truncatingIfNeeded: lowAmount)], signed: false)
    }

    /// op-145 `CurrentBatteryV2Response` (11 bytes: currentBatteryAbc@0, currentBatteryIbc@1 = the
    /// percent, chargingStatus@2, remainder unused by the app). Reply to the op-144
    /// `CurrentBatteryV2Request` poll. `percent: 0` builds a GENUINE dead-battery reply — the case that
    /// must stay distinguishable from "this read was never answered".
    static func currentBatteryV2(percent: Int, charging: Bool = false) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 11)
        c[0] = UInt8(truncatingIfNeeded: percent)
        c[1] = UInt8(truncatingIfNeeded: percent)
        c[2] = charging ? 1 : 0
        return frame(opCode: CurrentBatteryV2Response.props.opCode, cargo: c, signed: false)
    }

    /// op-77 `ErrorResponse` (2 bytes: the rejected request's opcode, then the error code).
    /// errorCodeId 6 = BAD_OPCODE — what an older pump answers op192 with, right before tearing the
    /// link down. `requestOpCode: 0` + `errorCode: 0` is the opcode-less `[0,0]` currentStatus variant the
    /// API-2.5 t:slim X2 sends (mechanism B correlates it back by txId). `txId` (frame[1]) echoes the
    /// failing request's wire txId — set it to a specific outstanding read's txId to prove the
    /// correlation picks THAT read, not the FIFO-oldest.
    static func errorResponse(requestOpCode: UInt8, errorCode: UInt8 = 6, txId: UInt8 = 0) -> [UInt8] {
        frame(opCode: ErrorResponse.props.opCode, cargo: [requestOpCode, errorCode], signed: false, txId: txId)
    }

    /// op-115 `BolusCalcDataSnapshotResponse` (size 46): the pump's calculator inputs (CR/ISF/target/max/iob)
    /// resolved for the active profile+segment. `carbRatioMilliGramsPerUnit` = grams-per-unit × 1000 (so 10000
    /// ⇒ 10 g/U); `iobMilliunits` should match the op-109 value or the host's cross-check trips `iobStale`.
    static func calcDataSnapshot(
        iobMilliunits: UInt32, targetBg: Int, isf: Int,
        carbRatioMilliGramsPerUnit: UInt32, maxBolusMilliunits: Int
    ) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 46)
        let iobB = Bytes.toUint32(iobMilliunits)
        for i in 0..<4 { c[3 + i] = iobB[i] }  // iob
        let tb = le2(targetBg)
        c[9] = tb[0]
        c[10] = tb[1]  // targetBg
        let isfB = le2(isf)
        c[11] = isfB[0]
        c[12] = isfB[1]  // isf
        let cr = Bytes.toUint32(carbRatioMilliGramsPerUnit)
        for i in 0..<4 { c[14 + i] = cr[i] }  // carbRatio
        let mb = le2(maxBolusMilliunits)
        c[18] = mb[0]
        c[19] = mb[1]  // maxBolusAmount
        return frame(opCode: BolusCalcDataSnapshotResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-33 `ApiVersionResponse` (4 bytes: majorVersion short@0, minorVersion short@2 — see the kit's
    /// `Responses.swift`). The bootstrap version read that IDENTIFIES the pump: `softwareVersion` becomes
    /// "major.minor" and `isMobi` is derived (`major>3 || (major==3 && minor>=5)`). Used by the STATIC
    /// known-unsupported-reads registry (debug pump-pairing-loop-api25 static-registry hardening): the
    /// evidenced bad combo is (isMobi=false, sw "2.5") ⇒ `apiVersion(major: 2, minor: 5)`.
    static func apiVersion(major: Int, minor: Int) -> [UInt8] {
        frame(opCode: ApiVersionResponse.props.opCode, cargo: le2(major) + le2(minor), signed: false)
    }

    /// op-85 `PumpVersionResponse` (48 bytes: armSwVer u32@0, mspSwVer u32@4, serialNum u32@16, partNum
    /// u32@20, pumpRev string@24..31, modelNum u32@44 — see the kit's `Responses.swift`). The second
    /// bootstrap version read; its `modelNum` is recorded for diagnostics / future registry refinement (the
    /// current evidenced key needs only op33's fields).
    static func pumpVersion(modelNum: UInt32 = 0, armSwVer: UInt32 = 0) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 48)
        let arm = Bytes.toUint32(armSwVer)
        for i in 0..<4 { c[0 + i] = arm[i] }
        let mn = Bytes.toUint32(modelNum)
        for i in 0..<4 { c[44 + i] = mn[i] }
        return frame(opCode: PumpVersionResponse.props.opCode, cargo: c, signed: false)
    }

    // MARK: - History-log frame builders (gap-aware sync)

    /// op-59 `HistoryLogStatusResponse` (12 bytes: numEntries/firstSequenceNum/lastSequenceNum, all
    /// little-endian `UInt32`, per `TandemKit`'s `HistoryLog.swift`).
    static func historyLogStatus(numEntries: UInt32, firstSequenceNum: UInt32, lastSequenceNum: UInt32) -> [UInt8] {
        frame(
            opCode: HistoryLogStatusResponse.props.opCode,
            cargo: Bytes.toUint32(numEntries) + Bytes.toUint32(firstSequenceNum) + Bytes.toUint32(lastSequenceNum),
            signed: false)
    }

    /// One 26-byte history-log CGM (EGV) record, matching `HistoryLog.parseCgmRecord`'s layout exactly:
    /// typeId = short@0 (masked 0x0FFF; default 256 = Dexcom G6, one of `HistoryLog.cgmTypeIds`),
    /// pumpTimeSec = uint32@2, sequenceNum = uint32@6, glucoseMgdl = short@16.
    static func cgmHistoryRecord(sequenceNum: UInt32, pumpTimeSec: UInt32, mgdl: Int, typeId: Int = 256) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 26)
        let t = le2(typeId)
        r[0] = t[0]
        r[1] = t[1]
        let ts = Bytes.toUint32(pumpTimeSec)
        for i in 0..<4 { r[2 + i] = ts[i] }
        let seq = Bytes.toUint32(sequenceNum)
        for i in 0..<4 { r[6 + i] = seq[i] }
        let g = le2(mgdl)
        r[16] = g[0]
        r[17] = g[1]
        return r
    }

    /// One 26-byte history-log completed-bolus record, matching `HistoryLog.parseBolusRecord`'s layout
    /// exactly: typeId = short@0 (`HistoryLog.bolusCompletedTypeId` = 20), pumpTimeSec = uint32@2,
    /// sequenceNum = uint32@6, completionStatusId = short@10, bolusId = short@12, iob = float@14,
    /// deliveredUnits = float@18. `bolusId`/`completionStatusId` default to 0 (unused by most existing
    /// callers, which predate the restored `BolusHistoryRecord.bolusId`).
    static func bolusHistoryRecord(
        sequenceNum: UInt32, pumpTimeSec: UInt32,
        deliveredUnits: Double, iobUnits: Double,
        bolusId: Int = 0, completionStatusId: Int = 0
    ) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 26)
        let t = le2(20)
        r[0] = t[0]
        r[1] = t[1]
        let ts = Bytes.toUint32(pumpTimeSec)
        for i in 0..<4 { r[2 + i] = ts[i] }
        let seq = Bytes.toUint32(sequenceNum)
        for i in 0..<4 { r[6 + i] = seq[i] }
        let cs = le2(completionStatusId)
        r[10] = cs[0]
        r[11] = cs[1]
        let bid = le2(bolusId)
        r[12] = bid[0]
        r[13] = bid[1]
        let iobB = Bytes.toFloat(Float(iobUnits))
        for i in 0..<4 { r[14 + i] = iobB[i] }
        let dv = Bytes.toFloat(Float(deliveredUnits))
        for i in 0..<4 { r[18 + i] = dv[i] }
        return r
    }

    /// op-129 `HistoryLogStreamResponse` (variable size, streamed): cargo is
    /// `[numberOfHistoryLogs, streamId, record0(26)…recordN(26)]`. Builds one frame carrying every CGM +
    /// bolus record supplied (`events` accepts pre-built raw 26-byte records for any other record type a
    /// test needs — e.g. an unrecognized/`UnknownHistoryLog` typeId — and defaults to none).
    /// `bolusRecordsById` is a separate param from `bolusRecords` — additive, so no existing call site
    /// needs to change — for a test that needs the restored `bolusId` field.
    static func historyLogStream(
        cgmReadings: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)] = [],
        bolusRecords: [(seq: UInt32, pumpTimeSec: UInt32, delivered: Double, iob: Double)] = [],
        bolusRecordsById: [(
            seq: UInt32, pumpTimeSec: UInt32, bolusId: Int, delivered: Double,
            iob: Double, completionStatusId: Int
        )] = [],
        events: [[UInt8]] = [], streamId: Int = 0
    ) -> [UInt8] {
        var records: [[UInt8]] = cgmReadings.map {
            cgmHistoryRecord(sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, mgdl: $0.mgdl)
        }
        records += bolusRecords.map {
            bolusHistoryRecord(
                sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, deliveredUnits: $0.delivered, iobUnits: $0.iob)
        }
        records += bolusRecordsById.map {
            bolusHistoryRecord(
                sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, deliveredUnits: $0.delivered,
                iobUnits: $0.iob, bolusId: $0.bolusId, completionStatusId: $0.completionStatusId)
        }
        records += events
        let cargo: [UInt8] = [UInt8(records.count), UInt8(streamId)] + records.flatMap { $0 }
        return frame(opCode: HistoryLogStreamResponse.props.opCode, cargo: cargo, signed: false)
    }

    /// One 26-byte history-log carb-entered record (`CarbEnteredHistoryLog`, typeId 48), matching its
    /// layout exactly: typeId = short@0, pumpTimeSec = uint32@2, sequenceNum = uint32@6, carbs = float@10.
    /// A generic non-CGM/non-bolus event record for the logbook-events future-reject test —
    /// `historyLogStream`'s `events:` param accepts pre-built raw records like this.
    static func carbEnteredHistoryRecord(sequenceNum: UInt32, pumpTimeSec: UInt32, carbs: Float) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 26)
        let t = le2(48)
        r[0] = t[0]
        r[1] = t[1]
        let ts = Bytes.toUint32(pumpTimeSec)
        for i in 0..<4 { r[2 + i] = ts[i] }
        let seq = Bytes.toUint32(sequenceNum)
        for i in 0..<4 { r[6 + i] = seq[i] }
        let c = Bytes.toFloat(carbs)
        for i in 0..<4 { r[10 + i] = c[i] }
        return r
    }

    /// op-129 `HistoryLogStreamResponse` with an EXPLICIT, possibly-WRONG `numberOfHistoryLogs` header
    /// byte (records.count derived from `cgmReadings` — the pinned TandemKit commit's
    /// `HistoryLogStreamResponse.init(cargo:)` parses `records` purely from however many 26-byte chunks
    /// fit in the cargo, NOT gated by this header byte, so a mismatch here is a genuine app-observable
    /// advertised-count-vs-actual disagreement). Drives the app-side guard test.
    static func historyLogStreamWithDeclaredCount(
        declaredCount: Int,
        cgmReadings: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)],
        streamId: Int = 0
    ) -> [UInt8] {
        let records: [[UInt8]] = cgmReadings.map {
            cgmHistoryRecord(sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, mgdl: $0.mgdl)
        }
        let cargo: [UInt8] = [UInt8(declaredCount), UInt8(streamId)] + records.flatMap { $0 }
        return frame(opCode: HistoryLogStreamResponse.props.opCode, cargo: cargo, signed: false)
    }

    // MARK: - Remote-dismiss ack fixtures

    /// op-69 `AlertStatusResponse` (8-byte little-endian uint64 bitmap; bit N set = notification id N
    /// active). Used to put a real, dismissable alert into `activeNotifications` for a remote-dismiss
    /// ack test, without depending on any other tier's response.
    static func alertStatusBitmap(_ bitmap: UInt64) -> [UInt8] {
        frame(opCode: AlertStatusResponse.props.opCode, cargo: Bytes.toUint64(bitmap), signed: false)
    }

    /// op-185 `DismissNotificationResponse` ack (1 byte: status@0 — 0 = accepted, non-zero = rejected).
    /// Signed (the real response is a signed CONTROL ack — see that type's own doc comment), so this
    /// builds a VALID HMAC trailer under `signedResponseTestKey`, matching `permissionGranted`/
    /// `initiateAccepted`'s own signed-response convention.
    static func dismissNotificationAck(status: Int) -> [UInt8] {
        frame(
            opCode: DismissNotificationResponse.props.opCode, cargo: [UInt8(truncatingIfNeeded: status)], signed: true)
    }
}
