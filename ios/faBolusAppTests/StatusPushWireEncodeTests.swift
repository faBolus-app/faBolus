import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins that the status-push JSON no longer emits retired Apple-Watch-only and eating-advisory fields,
/// while garminBolusEnabled, activeMode, and watchChartRanges stay present. A broad deletion would drop live Garmin contract keys.
@MainActor
@Suite(.serialized) struct StatusPushWireEncodeTests {

    /// A unique durable-ledger URL so this suite's `AppModel` instances never share the App Group ledger
    /// file with another serialized test.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("status-wire-ledger-\(UUID().uuidString).json")
    }

    /// Non-status commands never carry `watchBolusEnabled` — the field was only ever set on the statusRead reply.
    @Test func nonStatusCommandsNeverCarryWatchBolusEnabled() throws {
        let cases: [(String, RemoteCommand)] = [
            ("bolusRequest", RemoteCommand(kind: .bolusRequest, units: 1.0)),
            ("cancelBolus", RemoteCommand(kind: .cancelBolus)),
            ("dismissAlert", RemoteCommand(kind: .dismissAlert))
        ]
        for (name, cmd) in cases {
            let json = String(data: try cmd.encoded(), encoding: .utf8) ?? ""
            #expect(!json.contains("watchBolusEnabled"), "\(name) must never carry watchBolusEnabled on the wire")
        }
    }

    /// Drives a real `AppModel.statusCommand` so the wire output is the production function's, not a stand-in.
    @Test func statusPushDropsWatchBolusEnabledButKeepsSiblings() async throws {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        await backend.connect()
        let cmd = model.statusCommand(includeHistory: false)
        let json = String(data: try cmd.encoded(), encoding: .utf8) ?? ""

        #expect(
            !json.contains("watchBolusEnabled"),
            "the real status push must no longer emit watchBolusEnabled"
        )

        #expect(
            !json.contains("eatingSensingOn"),
            "the real status push must no longer emit eatingSensingOn"
        )
        #expect(
            !json.contains("eatingProb"),
            "the real status push must no longer emit eatingProb — eatingProb is only ever set on an eatingEvent, not statusRead, but this pins its absence explicitly alongside eatingSensingOn"
        )

        for keepKey in ["garminBolusEnabled", "activeMode", "watchChartRanges"] {
            #expect(
                json.contains(keepKey),
                "KEEP sibling \(keepKey) must remain present on the status push — the deletion must be surgical, not broad"
            )
        }
    }
}
