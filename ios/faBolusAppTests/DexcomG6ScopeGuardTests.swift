import Testing
import Foundation
@testable import faBolus

/// D-12a: proves the structural passive-only property both `DexcomG6BLESource` and
/// `DexcomG7BLESource` must hold — neither ever writes the authentication or control
/// characteristic. Mirrors `WatchDirectBleScopeGuardTests`' technique: a `#filePath`-rooted
/// repo-root walk + `String(contentsOf:)` + a source-scan, no BLE, no simulator, no live sensor.
/// Reading `Shared/DexcomG7BLESource.swift` here is inspection-only — no G7 change (D-11). This
/// guard must STAY green as Plan 03 adds the auth-observe-first subscribe (a notify, not a write).
struct DexcomG6ScopeGuardTests {

    /// Resolve `<root>` by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/DexcomG6ScopeGuardTests.swift`) until `Shared` exists — same
    /// technique as `WatchDirectBleScopeGuardTests.repoRootURL()`.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("Shared")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func readSource(_ relativePath: String) -> String? {
        guard let root = repoRootURL() else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Strip `//` line comments before scanning, so a comment mentioning the write call (e.g. this
    /// very file's own doc comments, or an explanatory "never writes X" note in the source) can
    /// never mask — or be mistaken for — an actual call.
    private static func stripLineComments(_ source: String) -> String {
        source.components(separatedBy: .newlines).map { line -> String in
            guard let range = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<range.lowerBound])
        }.joined(separator: "\n")
    }

    private static let sources = [
        "ios/faBolus/Data/Sources/DexcomG6BLESource.swift",
        "Shared/DexcomG7BLESource.swift",
    ]

    @Test func neitherG6NorG7SourceWritesTheCharacteristicWriteCall() throws {
        for path in Self.sources {
            guard let raw = Self.readSource(path) else {
                Issue.record("could not resolve \(path) from #filePath=\(#filePath)")
                continue
            }
            let code = Self.stripLineComments(raw)
            // <!-- planner-discipline-allow: writeValue( -->
            #expect(!code.contains("writeValue("),
                    "\(path) must never call CBPeripheral.writeValue(for:type:) — passive-read-only source (D-12a)")
        }
    }

    @Test func neitherG6NorG7SourceWritesTheAuthenticationOrControlCharacteristic() throws {
        for path in Self.sources {
            guard let raw = Self.readSource(path) else {
                Issue.record("could not resolve \(path) from #filePath=\(#filePath)")
                continue
            }
            let code = Self.stripLineComments(raw)
            for target in [".authentication", ".control"] {
                let writePattern = "writeValue(.*for: .*\(target)"
                #expect(code.range(of: writePattern, options: .regularExpression) == nil,
                        "\(path) must never write the \(target) characteristic (D-12a)")
            }
        }
    }

    /// The only characteristic-interaction API present must be the notify-subscribe call
    /// (`setNotifyValue`) — proving there is no OTHER write-shaped characteristic call hiding under
    /// a different method name.
    @Test func onlyCharacteristicInteractionIsNotifySubscribe() throws {
        for path in Self.sources {
            guard let raw = Self.readSource(path) else {
                Issue.record("could not resolve \(path) from #filePath=\(#filePath)")
                continue
            }
            let code = Self.stripLineComments(raw)
            #expect(code.contains("setNotifyValue("),
                    "\(path) is expected to subscribe to notifications (sanity check the file resolved correctly)")
            for forbidden in ["writeValue(", "readValue(for:"] {
                #expect(!code.contains(forbidden),
                        "\(path) must not call \(forbidden) — the only characteristic interaction allowed is notify-subscribe (D-12a)")
            }
        }
    }

    /// Vacuous-pass guard: fail loudly if the source files cannot be resolved from `#filePath` at
    /// all, rather than silently passing every `#expect` above because `readSource` returned nil.
    @Test func sourceFilesResolveFromFilePath() throws {
        for path in Self.sources {
            #expect(Self.readSource(path) != nil,
                    "path resolution broke: could not read \(path) from #filePath=\(#filePath)")
        }
    }
}
