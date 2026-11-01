import Foundation
import Testing

@testable import RemoteProtocol

/// The contract files are written by Swift: every fixture on disk is exactly what these values encode to.
/// Run with `UPDATE_CONTRACT=1` to rewrite them after a deliberate change, then sync the watch.
@Suite struct GoldenFixtureTests {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contract")
    static let fixtures = contract.appendingPathComponent("fixtures")

    @Test func fixturesOnDiskAreWhatSwiftWrites() throws {
        let update = ProcessInfo.processInfo.environment["UPDATE_CONTRACT"] == "1"
        for fixture in GoldenFixtures.fixtures {
            let url = Self.fixtures.appendingPathComponent("\(fixture.name).json")
            let expected = fixture.wire.canonicalJSON
            if update { try expected.write(to: url, atomically: true, encoding: .utf8) }
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            #expect(onDisk == expected, "\(fixture.name).json is stale: run the tests with UPDATE_CONTRACT=1")
        }
        let names = Set(GoldenFixtures.fixtures.map { "\($0.name).json" })
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path))
        #expect(files == names, "contract/fixtures holds files no fixture writes")
    }

    @Test func everyKindHasAFixture() {
        let kinds = Set(GoldenFixtures.fixtures.compactMap { $0.message?.kind })
        #expect(kinds == Set(RemoteMessage.Kind.allCases))
    }

    /// Read back from the JSON on disk, each version 2 fixture is the typed message it was written from,
    /// and encodes to the same wire value.
    @Test func versionTwoFixturesRoundTrip() throws {
        for fixture in GoldenFixtures.fixtures {
            guard let message = fixture.message else { continue }
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(fixture.name).json"))
            let wire = try WireValue(json: data)
            #expect(wire == fixture.wire, "\(fixture.name)")
            #expect(RemoteMessage.receive(wire) == .message(message), "\(fixture.name)")
            #expect(message.wire == wire, "\(fixture.name)")
        }
    }

    /// The same round trip through Foundation objects, the form Connect IQ hands over.
    @Test func versionTwoFixturesSurviveTheFoundationBridge() throws {
        for fixture in GoldenFixtures.fixtures {
            guard let message = fixture.message else { continue }
            let bridged = try WireValue(foundation: fixture.wire.foundation)
            #expect(RemoteMessage.receive(bridged) == .message(message), "\(fixture.name)")
        }
    }

    @Test func versionOneFixturesAreRecognizedAsLegacy() throws {
        for name in ["v1-statusRead-from-watch", "v1-bolusRequest-from-watch", "v1-statusRead-from-phone"] {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
            guard case .legacy = RemoteMessage.receive(try WireValue(json: data)) else {
                Issue.record("\(name) wasn't recognized as version 1")
                continue
            }
        }
    }

    /// The calculator fixtures the watch vendors are the ones the phone's composer is tested against.
    @Test func oracleFixturesAreTheCoreOnes() throws {
        let core = Self.contract.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("faBolusCore/Tests/faBolusCoreTests/Fixtures/bolus_oracle_fixtures.jsonl")
        let ours = Self.contract.appendingPathComponent("bolus_oracle_fixtures.jsonl")
        #expect(try Data(contentsOf: ours) == Data(contentsOf: core))
    }

    /// Every calculator input in the fixtures is exact on the wire, which carries the carb ratio in mg/U
    /// and IOB in milliunits, so the watch computes from the same numbers as the phone.
    @Test func oracleFixtureInputsAreExactOnTheWire() throws {
        let text = try String(
            contentsOf: Self.contract.appendingPathComponent("bolus_oracle_fixtures.jsonl"), encoding: .utf8)
        var rows = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard case .object(let row) = try WireValue(json: Data(line.utf8)) else {
                Issue.record("not an object: \(line)")
                continue
            }
            rows += 1
            for key in ["cr", "iob", "u"] {
                let value: Double
                switch row[key] {
                case .double(let d): value = d
                case .int(let i): value = Double(i)
                default:
                    Issue.record("\(key) missing in \(line)")
                    continue
                }
                #expect(abs((value * 1000).rounded() - value * 1000) < 1e-6, "\(key) in \(line)")
            }
        }
        #expect(rows == 563)
    }
}
