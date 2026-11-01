import Foundation
import faBolusCore
import os

@testable import GlucoseSources

/// Secrets in memory.
final class InMemorySecretStore: SecretStore {
    private let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    func secret(for account: String) -> String? { values.withLock { $0[account] } }
    func setSecret(_ value: String?, for account: String) throws { values.withLock { $0[account] = value } }
}

/// Settings in a UserDefaults suite of their own, so tests running in parallel don't share them.
func isolatedSettings() -> GlucoseSourceSettings {
    let suite = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    return GlucoseSourceSettings(defaults: defaults)
}

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    init(_ start: Date) { current = OSAllocatedUnfairLock(initialState: start) }
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in now } }
}

/// Records every wait asked for and never returns, so a poll loop runs exactly one step.
final class RecordingSleep: Sendable {
    private let delays = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
    var recorded: [TimeInterval] { delays.withLock { $0 } }
    var function: @Sendable (TimeInterval) async throws -> Void {
        { [self] delay in
            delays.withLock { $0.append(delay) }
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

/// Waits (briefly, polling) until `condition` holds.
func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Bytes from a hex string.
func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex, let end = string.index(index, offsetBy: 2, limitedBy: string.endIndex) {
        guard let byte = UInt8(string[index..<end], radix: 16) else { return Data() }
        data.append(byte)
        index = end
    }
    return data
}
