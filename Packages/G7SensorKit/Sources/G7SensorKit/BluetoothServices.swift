//  BluetoothServices.swift — vendored from LoopKit/G7SensorKit (originally xDripG5, MIT).
//  G7 GATT service + characteristic UUIDs. (LoopKit's peripheral-manager config extension dropped;
//  the faBolus app owns its own read-only central.)
import CoreBluetooth

public protocol CBUUIDRawValue: RawRepresentable {}
public extension CBUUIDRawValue where RawValue == String {
    var cbUUID: CBUUID { CBUUID(string: rawValue) }
}

public enum SensorServiceUUID: String, CBUUIDRawValue {
    /// Advertised service used to scan for a G7/ONE+.
    case advertisement = "FEBC"
    case cgmService = "F8083532-849E-531C-C594-30F1F86A4EA5"
    case serviceB = "F8084532-849E-531C-C594-30F1F86A4EA5"
}

public enum CGMServiceCharacteristicUUID: String, CBUUIDRawValue {
    /// Read/Notify.
    case communication = "F8083533-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — carries glucoseTx (0x4e) messages we listen for.
    case control = "F8083534-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — auth handshake. **Never written to** in passive mode.
    case authentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    /// Read/Write/Notify — carries backfill (history) messages.
    case backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
}
