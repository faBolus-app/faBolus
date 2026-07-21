//  G6Opcode.swift — the control-characteristic opcodes we passively read. Vendored subset of
//  LoopKit/CGMBLEKit's Opcode (MIT).
import Foundation

public enum G6Opcode: UInt8 {
    case glucoseRx = 0x31       // G5
    case glucoseG6Rx = 0x4f     // G6 / ONE
    case glucoseBackfillRx = 0x51
}

public extension Data {
    func starts(with opcode: G6Opcode) -> Bool {
        guard count > 0 else { return false }
        return self[startIndex] == opcode.rawValue
    }
}
