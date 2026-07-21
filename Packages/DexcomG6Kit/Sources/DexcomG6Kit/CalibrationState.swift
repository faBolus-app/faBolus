//  CalibrationState.swift — vendored from LoopKit/CGMBLEKit (originally xDripG5, MIT).
//  Tells whether a G6 reading is algorithmically reliable.
import Foundation

public enum CalibrationState: RawRepresentable, Equatable {
    public typealias RawValue = UInt8

    public enum State: RawValue {
        case stopped = 1
        case warmup = 2
        case needFirstInitialCalibration = 4
        case needSecondInitialCalibration = 5
        case ok = 6
        case needCalibration7 = 7
        case calibrationError8 = 8
        case calibrationError9 = 9
        case calibrationError10 = 10
        case sensorFailure11 = 11
        case sensorFailure12 = 12
        case calibrationError13 = 13
        case needCalibration14 = 14
        case sessionFailure15 = 15
        case sessionFailure16 = 16
        case sessionFailure17 = 17
        case questionMarks = 18
    }

    case known(State)
    case unknown(RawValue)

    public init(rawValue: RawValue) {
        self = State(rawValue: rawValue).map(CalibrationState.known) ?? .unknown(rawValue)
    }

    public var rawValue: RawValue {
        switch self {
        case .known(let s): return s.rawValue
        case .unknown(let v): return v
        }
    }

    public var hasReliableGlucose: Bool {
        guard case .known(let state) = self else { return false }
        switch state {
        case .ok, .needCalibration7, .needCalibration14:
            return true
        default:
            return false
        }
    }
}
