import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 17.5 Plan 01 (D1-01/REMED-17) — the before/after wire-encode proof that gates every deletion in
/// this phase's retirement of the Apple-Watch-only wire fields. This is the ONE net-new artifact this
/// plan produces; later plans in the phase (02/03) EXTEND it rather than recreate it.
///
/// Test A pins the already-true invariant that non-status commands never carry `watchBolusEnabled` — the
/// field is only ever set on the `statusRead` reply — so deleting it is provably byte-identical for every
/// other `Kind`. Test B is the RED-today proof: the REAL `AppModel.statusCommand()` emits
/// `watchBolusEnabled` unconditionally today; this asserts it is ABSENT from the encoded JSON while the
/// KEEP siblings (`garminBolusEnabled`, `activeMode`, `watchChartRanges` — none of them Apple-Watch-only)
/// stay PRESENT, proving the coming deletion in Task 2 is surgical, not broad.
@MainActor
@Suite(.serialized) struct StatusPushWireEncodeTests {

    /// A unique durable-ledger URL so this suite's `AppModel` instances never share the App Group ledger
    /// file with another serialized test.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("status-wire-ledger-\(UUID().uuidString).json")
    }

    /// Test A (non-status byte-safety): `watchBolusEnabled` is never set on `bolusRequest`/`cancelBolus`/
    /// `dismissAlert` — already true today, and stays true forever, because only `statusCommand()` (the
    /// `statusRead` reply) touches this field. Documents WHY removing it is byte-identical for these kinds.
    @Test func nonStatusCommandsNeverCarryWatchBolusEnabled() throws {
        let cases: [(String, RemoteCommand)] = [
            ("bolusRequest", RemoteCommand(kind: .bolusRequest, units: 1.0)),
            ("cancelBolus", RemoteCommand(kind: .cancelBolus)),
            ("dismissAlert", RemoteCommand(kind: .dismissAlert)),
        ]
        for (name, cmd) in cases {
            let json = String(data: try cmd.encoded(), encoding: .utf8) ?? ""
            #expect(!json.contains("watchBolusEnabled"), "\(name) must never carry watchBolusEnabled on the wire")
        }
    }

    /// Test B (status-push exact-delta, RED today): drives a REAL `AppModel` (backed by `MockBackend`, no
    /// hardware) to a connected snapshot and encodes its actual `statusCommand(...)` output — never a
    /// hand-built `RemoteCommand` — so this proves the real function's wire output, not a stand-in. FAILS
    /// today because `AppModel.statusCommand()` still emits `watchBolusEnabled` unconditionally; goes GREEN
    /// once Task 2 deletes the field end-to-end.
    ///
    /// Phase 17.5 Plan 03 (D1-01/REMED-17) extends this SAME proof to the eating-advisory wire fields:
    /// `RemoteStatusComposer.compose(...)` (the real function `AppModel.statusCommand()` now delegates
    /// to, post-16-01) emits `eatingSensingOn` unconditionally — RED today because it is still present;
    /// goes GREEN once Task 2 deletes `eatingSensingOn`/`eatingProb` end-to-end.
    @Test func statusPushDropsWatchBolusEnabledButKeepsSiblings() async throws {
        let backend = MockBackend()
        let model = AppModel(source: backend, ledgerStoreURL: tempLedgerURL())
        await backend.connect()
        let cmd = model.statusCommand(includeHistory: false)
        let json = String(data: try cmd.encoded(), encoding: .utf8) ?? ""

        #expect(!json.contains("watchBolusEnabled"),
                "the real status push must no longer emit watchBolusEnabled (D1-01) — this is the RED assertion Task 2 turns GREEN")

        #expect(!json.contains("eatingSensingOn"),
                "the real status push must no longer emit eatingSensingOn (D1-01) — this is the RED assertion Task 2 turns GREEN")
        #expect(!json.contains("eatingProb"),
                "the real status push must no longer emit eatingProb (D1-01) — eatingProb is only ever set on an eatingEvent, not statusRead, but this pins its absence explicitly alongside eatingSensingOn")

        for keepKey in ["garminBolusEnabled", "activeMode", "watchChartRanges"] {
            #expect(json.contains(keepKey),
                    "KEEP sibling \(keepKey) must remain present on the status push — the deletion must be surgical, not broad")
        }
    }
}
