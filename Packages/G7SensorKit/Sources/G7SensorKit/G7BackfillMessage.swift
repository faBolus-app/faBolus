//  G7BackfillMessage.swift — vendored from LoopKit/G7SensorKit (MIT), LoopKit types removed.
//  Decodes one historical reading received on the backfill characteristic (9 bytes).
import Foundation

public struct G7BackfillMessage: Equatable {
    /// Seconds since sensor pairing.
    public let timestamp: UInt32
    public let glucose: UInt16?
    public let glucoseIsDisplayOnly: Bool
    public let algorithmState: AlgorithmState
    public let trend: Double?
    public let data: Data

    public var hasReliableGlucose: Bool { algorithmState.hasReliableGlucose }
    public var trendDirection: G7TrendDirection? { G7TrendDirection(rate: trend) }

    public init?(data: Data) {
        //    0 1 2  3  4 5  6  7  8
        //   TTTTTT    BGBG SS    TR
        //   45a100 00 9600 06 0f fc
        guard data.count == 9 else { return nil }

        timestamp = data[0..<3].toInt()

        let glucoseBytes = data[4..<6].to(UInt16.self)
        glucose = glucoseBytes != 0xffff ? (glucoseBytes & 0xfff) : nil
        glucoseIsDisplayOnly = data[7] & 0x10 != 0
        algorithmState = AlgorithmState(rawValue: data[6])
        trend = data[8] == 0x7f ? nil : Double(Int8(bitPattern: data[8])) / 10
        self.data = data
    }
}

extension G7BackfillMessage: CustomDebugStringConvertible {
    public var debugDescription: String {
        "G7BackfillMessage(glucose:\(String(describing: glucose)), timestamp:\(timestamp))"
    }
}
