import Testing
import Foundation
@testable import faBolus

/// Heart-rate is chart context only, never a dose input. Pins that HR never enters the signed
/// command contract (`schema/command.schema.json` and `RemoteCommand.swift`); out-of-band
/// HealthKit / Garmin-bridge usage is out of this guard's scope by design.
struct HeartRateSchemaAbsenceGuardTests {
    /// The two source-of-truth files of the signed command contract (per check-schema-drift.sh).
    static let signedContractFiles = [
        "Packages/faBolusCore/Sources/faBolusCore/RemoteCommand.swift",
        "schema/command.schema.json"
    ]

    /// Heart-rate tokens banned from the signed command contract. Matched case-insensitively
    /// (the source is lowercased before the substring check), so `heartRate`, `HeartRate`,
    /// `heart_rate`-style camel/Pascal variants that spell `heartrate` once whitespace/underscores
    /// are stripped are NOT covered — but the two canonical spellings a real HR field would use
    /// (`heartRate` → `heartrate`, and the envelope key `hr_window`) are.
    static let bannedHeartRateTokens = ["heartrate", "hr_window"]

    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/HeartRateSchemaAbsenceGuardTests.swift`) — same technique as
    /// `KeyboardShortcutDoseGuardTests.resolve(_:)`.
    private static func resolve(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - no heart-rate token in the signed command contract

    @Test func signedCommandContractContainsNoHeartRateToken() throws {
        for relativePath in Self.signedContractFiles {
            guard let url = Self.resolve(relativePath) else {
                Issue.record("could not resolve \(relativePath) from #filePath=\(#filePath)")
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8).lowercased()
            for token in Self.bannedHeartRateTokens {
                #expect(
                    !source.contains(token),
                    "\(relativePath) contains banned heart-rate token '\(token)'. HR is chart context only and must be routed out-of-band (HealthKit + the Garmin envelope in GarminRemoteBridge.swift) before RemoteCommand.fromValidated, never added to the signed command schema."
                )
            }
        }
    }

    // MARK: - A path-resolution bug must fail loudly, not pass vacuously

    @Test func fileResolutionActuallyFoundBothContractFiles() {
        for relativePath in Self.signedContractFiles {
            #expect(
                Self.resolve(relativePath) != nil,
                "path resolution broke — could not resolve \(relativePath); the HR-absence scan would pass vacuously")
        }
    }
}
