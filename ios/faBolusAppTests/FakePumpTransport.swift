import Foundation
import PumpX2Messages
import PumpX2BLE
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

    @discardableResult
    func send(_ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
              allowInsulinDelivery: Bool) throws -> UInt8 {
        if let e = preWriteError[message.opCode] { throw e }
        sent.append((message.opCode, message.cargo, message.signed, allowInsulinDelivery))
        return 0
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
}
