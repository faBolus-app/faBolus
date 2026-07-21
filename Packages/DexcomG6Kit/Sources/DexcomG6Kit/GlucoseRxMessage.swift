//  GlucoseRxMessage.swift — vendored from LoopKit/CGMBLEKit (MIT). Decodes the glucose message the
//  G5/G6/ONE transmitter sends on the control characteristic (opcode 0x31 / 0x4f). mg/dL.
import Foundation

public struct GlucoseSubMessage: Equatable {
    static let size = 8
    public let timestamp: UInt32        // seconds since transmitter activation
    public let glucoseIsDisplayOnly: Bool
    public let glucose: UInt16          // mg/dL
    public let state: UInt8
    public let trend: Int8              // trend rate, tenths of mg/dL per minute (0x7f = unavailable)

    init?(data: Data) {
        guard data.count >= GlucoseSubMessage.size else { return nil }
        var start = data.startIndex
        var end = start.advanced(by: 4)
        timestamp = data[start..<end].toInt()
        start = end; end = start.advanced(by: 2)
        let g = data[start..<end].to(UInt16.self)
        glucoseIsDisplayOnly = (g & 0xf000) > 0
        glucose = g & 0xfff
        start = end; end = start.advanced(by: 1)
        state = data[start]
        start = end
        trend = Int8(bitPattern: data[start])
    }
}

public struct GlucoseRxMessage: Equatable {
    public let status: UInt8
    public let sequence: UInt32
    public let glucose: GlucoseSubMessage

    public init?(data: Data) {
        guard data.count >= 16, data.isCRCValid,
              data.starts(with: .glucoseRx) || data.starts(with: .glucoseG6Rx) else { return nil }
        status = data[1]
        sequence = data[2..<6].toInt()
        guard let sub = GlucoseSubMessage(data: data[6...]) else { return nil }
        glucose = sub
    }

    public var calibrationState: CalibrationState { CalibrationState(rawValue: glucose.state) }

    /// A displayable/reliable reading per the algorithm state and a sane floor (matches CGMBLEKit).
    public var hasReliableGlucose: Bool {
        calibrationState.hasReliableGlucose && glucose.glucose >= 39
    }

    public var glucoseMgdl: Int { Int(glucose.glucose) }

    /// Trend rate in mg/dL/min, or nil when the transmitter reports it unavailable.
    public var trendRateMgDlPerMin: Double? {
        guard glucose.trend > Int8.min, glucose.trend < Int8.max else { return nil }
        return Double(glucose.trend) / 10
    }

    public var trendDirection: G6TrendDirection? { G6TrendDirection(rate: trendRateMgDlPerMin) }
}
