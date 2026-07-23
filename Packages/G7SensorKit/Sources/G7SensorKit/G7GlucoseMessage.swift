//  G7GlucoseMessage.swift — vendored from LoopKit/G7SensorKit (MIT), LoopKit types removed.
//  Decodes a G7/ONE+ real-time glucose message (opcode 0x4e) received on the control characteristic.
import Foundation

public struct G7GlucoseMessage: Equatable {
    public let glucose: UInt16?
    public let predicted: UInt16?
    public let glucoseIsDisplayOnly: Bool
    /// Seconds since sensor pairing, of the *message*. Subtract `age` for the reading's timestamp.
    public let messageTimestamp: UInt32
    public let algorithmState: AlgorithmState
    public let sequence: UInt16
    /// Signed trend rate, mg/dL/min (nil when the sensor reports no trend).
    public let trend: Double?
    public let data: Data
    /// Seconds elapsed from the sensor reading to BLE transmission.
    public let age: UInt16

    public var hasReliableGlucose: Bool { algorithmState.hasReliableGlucose }
    /// Sensor-clock timestamp (seconds since pairing) of the glucose reading itself. Guard the unsigned
    /// subtraction: a malformed sensor frame where `age > messageTimestamp` would otherwise underflow
    /// and trap (audit A-07).
    public var glucoseTimestamp: UInt32 { messageTimestamp >= UInt32(age) ? messageTimestamp - UInt32(age) : 0 }
    public var trendDirection: G7TrendDirection? { G7TrendDirection(rate: trend) }

    public init?(data: Data) {
        //    0  1  2 3 4 5  6 7  8  9 1011 1213 14 15 1617 18
        //         TTTTTTTT SQSQ       AGAG BGBG SS TR PRPR C
        // 0x4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
        guard data.count >= 19, data[1] == 0x00 else { return nil }

        messageTimestamp = data[2..<6].toInt()
        sequence = data[6..<8].to(UInt16.self)
        age = data[10..<12].to(UInt16.self)

        let glucoseData = data[12..<14].to(UInt16.self)
        if glucoseData != 0xffff {
            glucose = glucoseData & 0xfff
            glucoseIsDisplayOnly = (data[18] & 0x10) > 0
        } else {
            glucose = nil
            glucoseIsDisplayOnly = false
        }

        let predictionData = data[16..<18].to(UInt16.self)
        predicted = predictionData != 0xffff ? (predictionData & 0xfff) : nil

        algorithmState = AlgorithmState(rawValue: data[14])
        trend = data[15] == 0x7f ? nil : Double(Int8(bitPattern: data[15])) / 10
        self.data = data
    }
}

extension G7GlucoseMessage: CustomDebugStringConvertible {
    public var debugDescription: String {
        "G7GlucoseMessage(glucose:\(String(describing: glucose)), sequence:\(sequence) state:\(algorithmState) messageTimestamp:\(messageTimestamp) age:\(age))"
    }
}
