//  TransmitterTimeRxMessage.swift — MIT port of LoopKit/CGMBLEKit's TransmitterTimeRxMessage
//  (CGMBLEKit/Messages/TransmitterTimeRxMessage.swift). Decodes the transmitter's own periodic
//  time broadcast (opcode 0x25) — status/currentTime/sessionStartTime — the SAME control
//  characteristic notify stream `GlucoseRxMessage` already arrives on. This is the sensor-time
//  anchor D-08a uses: `activationDate = now - currentTime`, refreshed opportunistically whenever a
//  fresh message like this one is observed, then every glucose frame's sensor-relative `timestamp`
//  converts to a true wall date via `activationDate.addingTimeInterval(timestamp)` — instead of
//  stamping `Date()` at receipt, which reads a delayed/batched frame as artificially fresh.
import Foundation

public struct TransmitterTimeRxMessage: Equatable {
    /// Dexcom reports UInt32.max when no sensor session is active.
    public static let noActiveSessionStartTime = UInt32.max

    public let status: UInt8
    public let currentTime: UInt32
    public let sessionStartTime: UInt32

    public init?(data: Data) {
        guard data.count == 16, data.isCRCValid, data.starts(with: .transmitterTimeRx) else { return nil }
        // Index relative to `data.startIndex`, never absolutely: this init is `public`, so a caller
        // can pass a non-zero-based `Data` slice — mirrors `GlucoseRxMessage`'s slice-safe pattern.
        let s = data.startIndex
        status = data[s + 1]
        currentTime = data[(s + 2)..<(s + 6)].toInt()
        sessionStartTime = data[(s + 6)..<(s + 10)].toInt()
    }

    /// False when no sensor session is currently active (the transmitter's `UInt32.max` sentinel) or
    /// when the reported session start is inconsistent with the current time.
    public var hasValidSensorSession: Bool {
        sessionStartTime != Self.noActiveSessionStartTime && sessionStartTime <= currentTime
    }
}
