//  G7Opcode.swift — vendored from LoopKit/G7SensorKit (MIT).
import Foundation

public enum G7Opcode: UInt8 {
    case authChallengeRx = 0x05
    case sessionStopTx = 0x28
    case glucoseTx = 0x4e
    case extendedVersionTx = 0x52
    case extendedVersionRx = 0x53
    case backfillFinished = 0x59
}

public extension Data {
    func starts(with opcode: G7Opcode) -> Bool {
        guard count > 0 else { return false }
        return self[startIndex] == opcode.rawValue
    }
}
