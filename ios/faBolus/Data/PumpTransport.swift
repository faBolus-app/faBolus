import Foundation
import PumpX2Messages
import PumpX2BLE

/// The subset of `PumpBLEClient` that TandemBackend's **signed / delivery** flow depends on, factored out
/// as a seam so that flow can be exercised behind a deterministic fake with no CoreBluetooth hardware
/// (round-3 audit §6.1 / §4 / §10). Production uses the real `PumpBLEClient`; tests inject a
/// `FakePumpTransport` that scripts responses, drops, and disconnects.
///
/// Connection, scanning, pairing, and delegate wiring stay on the concrete `PumpBLEClient` — only the
/// request/response surface the delivery state machine needs is abstracted here.
@MainActor
public protocol PumpTransport: AnyObject {
    var writePolicy: PumpBLEClient.WritePolicy { get set }

    /// Run `body` with the policy elevated for exactly this op, always restoring `.readOnly` (PX-03/04).
    @discardableResult
    func withWritePolicy<T>(_ policy: PumpBLEClient.WritePolicy,
                            _ body: @MainActor () async throws -> T) async rethrows -> T

    /// Fire a (possibly signed) message. Returns the wire txId; throws synchronously on a pre-write
    /// authorization/not-ready failure (a clean pre-write failure — nothing went out).
    @discardableResult
    func send(_ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
              allowInsulinDelivery: Bool) throws -> UInt8

    /// Send and await the correlated response frame (PX-08). A synchronous throw = pre-write failure; a
    /// `PumpTransactionCoordinator.TxError` = the write went out and the response was lost/late.
    func sendAwaitingResponse(_ message: Message, authenticationKey: [UInt8], pumpTimeSinceReset: UInt32,
                              allowInsulinDelivery: Bool, responseOpCode: UInt8?,
                              deadline: TimeInterval) async throws -> [UInt8]
}

/// `PumpBLEClient` already implements every member — retroactive conformance, no added code.
extension PumpBLEClient: PumpTransport {}
