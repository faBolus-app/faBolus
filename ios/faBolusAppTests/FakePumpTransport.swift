import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Round-3 §6.1 deterministic fake transport for driving the REAL `TandemBackend.perform` flow with no
/// CoreBluetooth. Scripts a reply per awaited response opcode (a valid response frame, a dropped/lost
/// response, or a transport error) and records what was written so tests can assert the exact request
/// cargo and the exact number of initiate writes.
@MainActor
final class FakePumpTransport: PumpTransport {

    var writePolicy: PumpBLEClient.WritePolicy = .readOnly

    /// What to do when a given response opcode is awaited.
    enum Reply {
        case frame([UInt8])                              // a valid response frame → parses to the typed response
        case garbage                                     // an unparseable frame (post-write parse failure)
        case tx(PumpTransactionCoordinator.TxError)      // timeout / connectionLost (write went out, reply lost)
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

    func script(_ responseOpCode: UInt8, _ replies: Reply...) { scripts[responseOpCode, default: []].append(contentsOf: replies) }

    // MARK: PumpTransport

    @discardableResult
    func withWritePolicy<T>(_ policy: PumpBLEClient.WritePolicy,
                            _ body: @MainActor () async throws -> T) async rethrows -> T {
        writePolicy = policy
        defer { writePolicy = .readOnly }
        return try await body()
    }

    /// Incrementing wire txId, mirroring the real `PumpBLEClient`'s `txIds.nextThenIncrement()`. Lets a
    /// test exercise the op77 txId-echo correlation (debug pump-pairing-loop-api25, mechanism B): a read's
    /// returned txId is what the pump echoes back in an inbound frame's frame[1].
    private var nextTxId: UInt8 = 0

    @discardableResult
    func send(_ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
              allowInsulinDelivery: Bool) throws -> UInt8 {
        if let e = preWriteError[message.opCode] { throw e }
        sent.append((message.opCode, message.cargo, message.signed, allowInsulinDelivery))
        let txId = nextTxId
        nextTxId = nextTxId &+ 1
        return txId
    }

    func sendAwaitingResponse(_ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
                              allowInsulinDelivery: Bool, responseOpCode: UInt8?,
                              deadline: TimeInterval, serialized: Bool = false) async throws -> [UInt8] {
        // A pre-write failure throws before the write is recorded (clean pre-write failure).
        if let e = preWriteError[message.opCode] { throw e }
        // The write goes out first (matches the real client), THEN we await the reply.
        sent.append((message.opCode, message.cargo, message.signed, allowInsulinDelivery))
        guard let op = responseOpCode ?? message.props.responseOpCode else { throw PumpBLEClient.ClientError.notReady }
        awaited.append(op)
        willAwait?(op)
        let reply: Reply = {
            if var q = scripts[op], !q.isEmpty { let r = q.removeFirst(); scripts[op] = q; return r }
            return .tx(.timedOut(characteristic: message.characteristic, opCode: op))   // default: dropped
        }()
        switch reply {
        case .frame(let f): return f
        case .garbage: return [op, 0, 2, 0xDE, 0xAD, 0x00, 0x00]   // wrong length/crc → parse fails
        case .tx(let e): throw e
        }
    }

    // MARK: - Response frame builders (valid, CRC'd; parser strips the 24-byte HMAC on signed responses)

    static func frame(opCode: UInt8, cargo: [UInt8], signed: Bool) -> [UInt8] {
        var body = cargo
        if signed { body += [UInt8](repeating: 0, count: 24) }   // fake HMAC (parser strips, doesn't verify)
        var f: [UInt8] = [opCode, 0, UInt8(body.count)] + body
        f += Bytes.calculateCRC16(f)
        return f
    }
    private static func le2(_ v: Int) -> [UInt8] { Bytes.firstTwoBytesLittleEndian(v) }

    static func timeResponse(currentTime: UInt32 = 1000) -> [UInt8] {
        frame(opCode: TimeSinceResetResponse.props.opCode, cargo: Bytes.toUint32(currentTime) + Bytes.toUint32(0), signed: false)
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
        frame(opCode: InitiateBolusResponse.props.opCode, cargo: [1] + le2(bolusId) + [0, 0, UInt8(statusType)], signed: true)
    }
    /// statusId 0 = not active (bolus finished); 1/2 = active.
    static func currentBolusStatus(statusId: Int, bolusId: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 15)
        c[0] = UInt8(statusId); c[1] = le2(bolusId)[0]; c[2] = le2(bolusId)[1]
        return frame(opCode: CurrentBolusStatusResponse.props.opCode, cargo: c, signed: false)
    }
    static func lastBolus(bolusId: Int, deliveredMilliunits: UInt32, status: Int = 3) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 24)
        c[0] = UInt8(status); c[1] = le2(bolusId)[0]; c[2] = le2(bolusId)[1]
        let ts = Bytes.toUint32(1000); for i in 0..<4 { c[5 + i] = ts[i] }
        let dv = Bytes.toUint32(deliveredMilliunits); for i in 0..<4 { c[9 + i] = dv[i] }
        return frame(opCode: LastBolusStatusV2Response.props.opCode, cargo: c, signed: false)
    }

    /// op-109 `ControlIQIOBResponse` (size 17). Only `swan6hrIOB` (offset 12) drives `iobUnits`, the value
    /// `TandemBackend` reads; the other IOB fields are left zero. Delivered via `didReceiveFrame`, not the
    /// coordinator (these reads are fire-and-forget), so a test seeds it with `injectStatusFrameForTesting`.
    static func controlIQIOB(iobMilliunits: UInt32) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 17)
        let v = Bytes.toUint32(iobMilliunits); for i in 0..<4 { c[12 + i] = v[i] }   // swan6hrIOB
        return frame(opCode: ControlIQIOBResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-57 `HomeScreenMirrorResponse` (9 bytes). Byte 0 is `cgmTrendIconId` (0 = the pump's explicit
    /// **no arrow**; 2 = up, etc. — matching `CGMTrendIcon`). The pump's icon is authoritative, so a test
    /// can pin that a later client-side derivation never overwrites it (E8). Byte 8 = `cgmDisplayData`.
    static func homeScreenMirror(trendIconId: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 9)
        c[0] = UInt8(trendIconId)
        c[8] = 1   // cgmDisplayData: the mirror carries live CGM display state
        return frame(opCode: HomeScreenMirrorResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-193 `CurrentEgvGuiDataV2Response` (8 bytes): a VALID reading (`egvStatusId` 1, mg/dL at offset 4)
    /// plus a signed `trendRate` at offset 7 that the client-side derivation turns into an arrow. Used to
    /// prove the derived arrow is only a cold-start bridge and never overwrites the pump's authoritative
    /// HomeScreenMirror trend (E8). `trendRate` is 0.1 mg/dL/min units (30 ⇒ +3.0 ⇒ a rising arrow).
    static func currentEgvV2(mgdl: Int, trendRate: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let bg = le2(mgdl); c[4] = bg[0]; c[5] = bg[1]              // cgmReading (LE short)
        c[6] = 1                                                    // egvStatusId = 1 → hasValidReading
        c[7] = UInt8(bitPattern: Int8(truncatingIfNeeded: trendRate))   // signed trend rate
        return frame(opCode: CurrentEgvGuiDataV2Response.props.opCode, cargo: c, signed: false)
    }

    /// op-35 `CurrentEGVGuiDataResponse`, the V1 twin of `currentEgvV2` above (identical 8-byte layout).
    /// `TandemBackend.fastRead()`/`refreshGlucoseNow()`/`runPredictiveBurst()` send this request (op34)
    /// exclusively — never the V2 request (op192), which an older t:slim X2 firmware rejects with
    /// `ErrorResponse`/BAD_OPCODE and then drops the BLE link — see `.planning/debug/pump-pairing-loop.md`
    /// (on-device capture #6).
    static func currentEgvV1(mgdl: Int, trendRate: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let bg = le2(mgdl); c[4] = bg[0]; c[5] = bg[1]              // cgmReading (LE short)
        c[6] = 1                                                    // egvStatusId = 1 → hasValidReading
        c[7] = UInt8(bitPattern: Int8(truncatingIfNeeded: trendRate))   // signed trend rate
        return frame(opCode: CurrentEGVGuiDataResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-21 `LoadStatusResponse` (3 bytes: isLoadingActive@0, loadStateId@1, primeStatusId@2 — see the
    /// kit's `ResponseDirectTests`). Reply to the op20 `LoadStatusRequest` poll; feeds
    /// `PumpSnapshot.cartridgeLoadState` → the 09.9 `cartridgeReadyForBolus` pre-guard. loadStateId 0/1/2
    /// (CHANGE_CARTRIDGE/LOAD_CARTRIDGE/PRIME_TUBING) ⇒ not ready; the idle/unknown default 6 ⇒ ready.
    static func loadStatus(isLoadingActive: Bool, loadStateId: Int) -> [UInt8] {
        frame(opCode: LoadStatusResponse.props.opCode,
              cargo: [isLoadingActive ? 1 : 0, UInt8(truncatingIfNeeded: loadStateId), 0], signed: false)
    }

    /// op-77 `ErrorResponse` (2 bytes: the rejected request's opcode, then the error code).
    /// errorCodeId 6 = BAD_OPCODE — what an older pump answers op192 with, right before tearing the
    /// link down.
    static func errorResponse(requestOpCode: UInt8, errorCode: UInt8 = 6) -> [UInt8] {
        frame(opCode: ErrorResponse.props.opCode, cargo: [requestOpCode, errorCode], signed: false)
    }

    /// op-115 `BolusCalcDataSnapshotResponse` (size 46): the pump's calculator inputs (CR/ISF/target/max/iob)
    /// resolved for the active profile+segment. `carbRatioMilliGramsPerUnit` = grams-per-unit × 1000 (so 10000
    /// ⇒ 10 g/U); `iobMilliunits` should match the op-109 value or the host's cross-check trips `iobStale`.
    static func calcDataSnapshot(iobMilliunits: UInt32, targetBg: Int, isf: Int,
                                 carbRatioMilliGramsPerUnit: UInt32, maxBolusMilliunits: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 46)
        let iobB = Bytes.toUint32(iobMilliunits); for i in 0..<4 { c[3 + i] = iobB[i] }      // iob
        let tb = le2(targetBg); c[9] = tb[0]; c[10] = tb[1]                                   // targetBg
        let isfB = le2(isf); c[11] = isfB[0]; c[12] = isfB[1]                                 // isf
        let cr = Bytes.toUint32(carbRatioMilliGramsPerUnit); for i in 0..<4 { c[14 + i] = cr[i] }  // carbRatio
        let mb = le2(maxBolusMilliunits); c[18] = mb[0]; c[19] = mb[1]                        // maxBolusAmount
        return frame(opCode: BolusCalcDataSnapshotResponse.props.opCode, cargo: c, signed: false)
    }

    // MARK: - History-log frame builders (Phase 09.7-01 — gap-aware sync)

    /// op-59 `HistoryLogStatusResponse` (12 bytes: numEntries/firstSequenceNum/lastSequenceNum, all
    /// little-endian `UInt32`, per `TandemKit`'s `HistoryLog.swift`).
    static func historyLogStatus(numEntries: UInt32, firstSequenceNum: UInt32, lastSequenceNum: UInt32) -> [UInt8] {
        frame(opCode: HistoryLogStatusResponse.props.opCode,
              cargo: Bytes.toUint32(numEntries) + Bytes.toUint32(firstSequenceNum) + Bytes.toUint32(lastSequenceNum),
              signed: false)
    }

    /// One 26-byte history-log CGM (EGV) record, matching `HistoryLog.parseCgmRecord`'s layout exactly:
    /// typeId = short@0 (masked 0x0FFF; default 256 = Dexcom G6, one of `HistoryLog.cgmTypeIds`),
    /// pumpTimeSec = uint32@2, sequenceNum = uint32@6, glucoseMgdl = short@16.
    static func cgmHistoryRecord(sequenceNum: UInt32, pumpTimeSec: UInt32, mgdl: Int, typeId: Int = 256) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 26)
        let t = le2(typeId); r[0] = t[0]; r[1] = t[1]
        let ts = Bytes.toUint32(pumpTimeSec); for i in 0..<4 { r[2 + i] = ts[i] }
        let seq = Bytes.toUint32(sequenceNum); for i in 0..<4 { r[6 + i] = seq[i] }
        let g = le2(mgdl); r[16] = g[0]; r[17] = g[1]
        return r
    }

    /// One 26-byte history-log completed-bolus record, matching `HistoryLog.parseBolusRecord`'s layout
    /// exactly: typeId = short@0 (`HistoryLog.bolusCompletedTypeId` = 20), pumpTimeSec = uint32@2,
    /// sequenceNum = uint32@6, iob = float@14, deliveredUnits = float@18.
    static func bolusHistoryRecord(sequenceNum: UInt32, pumpTimeSec: UInt32,
                                   deliveredUnits: Double, iobUnits: Double) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 26)
        let t = le2(20); r[0] = t[0]; r[1] = t[1]
        let ts = Bytes.toUint32(pumpTimeSec); for i in 0..<4 { r[2 + i] = ts[i] }
        let seq = Bytes.toUint32(sequenceNum); for i in 0..<4 { r[6 + i] = seq[i] }
        let iobB = Bytes.toFloat(Float(iobUnits)); for i in 0..<4 { r[14 + i] = iobB[i] }
        let dv = Bytes.toFloat(Float(deliveredUnits)); for i in 0..<4 { r[18 + i] = dv[i] }
        return r
    }

    /// op-129 `HistoryLogStreamResponse` (variable size, streamed): cargo is
    /// `[numberOfHistoryLogs, streamId, record0(26)…recordN(26)]`. Builds one frame carrying every CGM +
    /// bolus record supplied (`events` accepts pre-built raw 26-byte records for any other record type a
    /// test needs — e.g. an unrecognized/`UnknownHistoryLog` typeId — and defaults to none).
    static func historyLogStream(cgmReadings: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)] = [],
                                 bolusRecords: [(seq: UInt32, pumpTimeSec: UInt32, delivered: Double, iob: Double)] = [],
                                 events: [[UInt8]] = [], streamId: Int = 0) -> [UInt8] {
        var records: [[UInt8]] = cgmReadings.map { cgmHistoryRecord(sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, mgdl: $0.mgdl) }
        records += bolusRecords.map { bolusHistoryRecord(sequenceNum: $0.seq, pumpTimeSec: $0.pumpTimeSec, deliveredUnits: $0.delivered, iobUnits: $0.iob) }
        records += events
        let cargo: [UInt8] = [UInt8(records.count), UInt8(streamId)] + records.flatMap { $0 }
        return frame(opCode: HistoryLogStreamResponse.props.opCode, cargo: cargo, signed: false)
    }
}
