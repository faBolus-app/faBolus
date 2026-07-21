//  Data+G7.swift — little-endian integer + hex helpers used by the G7 message decoders.
//  Vendored from LoopKit/G7SensorKit (originally xDripG5, MIT).
import Foundation

extension Data {
    /// Little-endian integer assembled byte-by-byte. Avoids binding memory + dereferencing: a
    /// misaligned `pointee` load traps (EXC_BAD_ACCESS) on real ARM devices (only tolerated on the
    /// simulator). This shift-assemble is alignment-safe and works on any Data/slice.
    func to<T: FixedWidthInteger>(_ type: T.Type) -> T {
        var value: T = 0
        for (i, byte) in enumerated() where i < MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: byte) << (8 * i)
        }
        return value
    }

    func toInt<T: FixedWidthInteger>() -> T {
        return to(T.self)
    }

    var hexadecimalString: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
