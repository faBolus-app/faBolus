//  Data+G6.swift — little-endian integer + CRC-CCITT (XModem) helpers used by the G6 decoders.
//  Vendored from LoopKit/CGMBLEKit (originally xDripG5, MIT).
import Foundation

extension Data {
    /// Little-endian integer assembled byte-by-byte. Avoids binding memory + dereferencing a raw
    /// pointer: the transmitter's bytes land at arbitrary offsets in a `Data` slice, and a misaligned
    /// `pointee` load traps (EXC_BAD_ACCESS) on real ARM devices (only tolerated on the simulator).
    /// This shift-assemble is alignment-safe and works on any Data/slice.
    func to<T: FixedWidthInteger>(_ type: T.Type) -> T {
        var value: T = 0
        for (i, byte) in enumerated() where i < MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: byte) << (8 * i)
        }
        return value
    }
    func toInt<T: FixedWidthInteger>() -> T { to(T.self) }
    var hexadecimalString: String { map { String(format: "%02hhx", $0) }.joined() }
}

extension Collection where Element == UInt8 {
    /// CRC-CCITT (XModem), as the Dexcom transmitter uses.
    var crc16: UInt16 {
        var crc: UInt16 = 0
        for byte in self {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1 ^ 0x1021) : (crc << 1) }
        }
        return crc
    }
}

extension Data {
    /// True when the trailing little-endian 2-byte CRC matches the CRC of the preceding bytes.
    var isCRCValid: Bool { dropLast(2).crc16 == suffix(2).toInt() }
    /// Append the little-endian CRC (used by tests to build valid frames).
    func appendingCRC() -> Data {
        var d = self
        let c: UInt16 = crc16
        d.append(UInt8(c & 0xff)); d.append(UInt8(c >> 8))
        return d
    }
}
