import Foundation

/// Why the link to the pump went down.
public enum PumpDisconnectReason: Sendable, Hashable, Codable {
    /// The user or the app asked to disconnect.
    case requested
    /// Bluetooth is off, unauthorized or resetting.
    case bluetoothUnavailable
    /// The link dropped. `code` is CoreBluetooth's error code when it gave one.
    case linkLost(code: Int?)
    /// Authentication failed or was rejected.
    case authenticationFailed
    /// The pump dropped the link right after rejecting a request it doesn't support. Expected after a
    /// probe, so it isn't counted as instability.
    case afterUnsupportedRequest(opcode: Int)
}

/// The typed event stream `PumpSession` emits. Consumers react to events rather than diffing state:
/// each event says what happened, and `readingsChanged` names the readings that changed and carries the
/// new state for anyone who shows it.
public enum PumpEvent: Sendable, Hashable {
    /// The link changed.
    case linkChanged(PumpLinkState)
    /// The link went down, and why.
    case disconnected(PumpDisconnectReason)
    /// The link keeps dropping before it holds, and reconnecting has backed off.
    case connectionUnstable
    /// The link held after being unstable.
    case connectionRestored
    /// The pump identified itself.
    case identified(PumpModel)
    /// These readings were updated; the state is the whole state after the update.
    case readingsChanged(Set<PumpState.Reading>, PumpState)
    /// The pump's open notifications changed.
    case alertsChanged([PumpAlert])
    /// The result of dismissing one of the pump's notifications.
    case alertDismissed(PumpAlert, DismissOutcome)
    /// A bolus request's outcome moved. The ledger records it before this is emitted.
    case bolusOutcome(RemoteBolusLedger.Key, BolusOutcome)
}
