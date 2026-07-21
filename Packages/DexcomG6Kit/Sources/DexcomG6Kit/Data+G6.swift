//  Data+G6.swift — little-endian integer + CRC-CCITT (XModem) helpers used by the G6 decoders.
//  Vendored from LoopKit/CGMBLEKit (originally xDripG5, MIT).
import Foundation

extension Data {
    private func toDefaultEndian<T: FixedWidthInteger>(_: T.Type) -> T {
        withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: T.self)
            guard let p = buf.baseAddress else { return 0 }
            return T(p.pointee)
        }
    }
    func to<T: FixedWidthInteger>(_ type: T.Type) -> T { T(littleEndian: toDefaultEndian(type)) }
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
