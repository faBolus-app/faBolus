//  BluetoothServices.swift — Dexcom G5/G6/ONE GATT UUIDs. Vendored from LoopKit/CGMBLEKit (MIT).
//  (Same service/characteristic layout as the G7; the glucose message format/opcodes differ.)
import CoreBluetooth

public protocol CBUUIDRawValue: RawRepresentable {}
public extension CBUUIDRawValue where RawValue == String {
    var cbUUID: CBUUID { CBUUID(string: rawValue) }
}

public enum TransmitterServiceUUID: String, CBUUIDRawValue {
    /// Advertised service used to scan for a transmitter.
    case advertisement = "FEBC"
    case cgmService = "F8083532-849E-531C-C594-30F1F86A4EA5"
}

public enum CGMServiceCharacteristicUUID: String, CBUUIDRawValue {
    /// Read/Notify.
    case communication = "F8083533-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — carries the glucose messages we passively read.
    case control = "F8083534-849E-531C-C594-30F1F86A4EA5"
    /// Write/Indicate — auth handshake. **Never written to** in passive mode.
    case authentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    /// Read/Write/Notify — backfill (history).
    case backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
}
