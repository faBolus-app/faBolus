import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// C2 §2.3 — host end-to-end for the OPTIONAL Garmin bolus passcode. Drives `AppModel.remoteDeliver`
/// from `.garmin` with a passcode set on the phone and asserts the exit criteria: an ABSENT or WRONG
/// entered code is denied (an echoed `.failed` carrying the passcode message), the CORRECT code passes
/// the gate, and the Apple Watch is EXEMPT (a watch deliver is never passcode-gated — wrist detection).
/// Uses the DEBUG in-memory Keychain seam (the app-hosted xctest has no Keychain) so the REAL salted-hash
/// `verify()` + exponential-backoff runs. The pure gate logic is covered by faBolusCore `AccessPolicyTests`;
/// this pins the AppModel wiring (the single stateful verify() + the required/satisfied threading).
@Suite(.serialized) @MainActor
struct BolusPasscodeGateTests {
    private final class Box { var echoes: [RemoteCommand] = [] }

    private let passcodeMessage = AccessPolicy.DenialReason.remoteBolusPasscodeRequired.userMessage

    private func makeModel() -> (AppModel, MockBackend, Box) {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pc-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: url)
        let box = Box()
        model.addRemoteEcho { cmd in box.echoes.append(cmd) }
        return (model, backend, box)
    }

    /// Clean gate state (Garmin+Watch bolusing ON, no read-only/child, advanced on for the Mobi mock) with
    /// the in-memory Keychain seam armed; restore everything after (incl. clearing the passcode + counters).
    private func withClean(_ body: () async -> Void) async {
        let s = AppSettings.shared
        let child = s.childModeEnabled, ro = s.phoneReadOnly, adv = s.advancedControlEnabled
        let rro = s.remotesReadOnly, gbe = s.garminBolusEnabled, wbe = s.watchBolusEnabled
        s.childModeEnabled = false; s.phoneReadOnly = false; s.advancedControlEnabled = true
        s.remotesReadOnly = false; s.garminBolusEnabled = true; s.watchBolusEnabled = true
        BolusPasscodeStore.useInMemoryBackingForTests = true
        await body()
        BolusPasscodeStore.setPasscode(nil)
        BolusPasscodeStore.useInMemoryBackingForTests = false
        s.childModeEnabled = child; s.phoneReadOnly = ro; s.advancedControlEnabled = adv
        s.remotesReadOnly = rro; s.garminBolusEnabled = gbe; s.watchBolusEnabled = wbe
    }

    @Test func garminDeliverDeniedWithoutOrWrongPasscodeAllowedWithCorrect() async {
        await withClean {
            #expect(BolusPasscodeStore.setPasscode("1234"))
            let (model, backend, box) = makeModel()
            await backend.connect()

            // Required + ABSENT ⇒ denied with the passcode message (a legacy watch that never prompted).
            await model.remoteDeliver(requestId: "a", units: 1.0, passcode: nil, from: .garmin, peerId: "garmin")
            #expect(box.echoes.contains { $0.status == .failed && $0.message == passcodeMessage })

            // Required + WRONG ⇒ denied with the passcode message (verify() fails).
            box.echoes.removeAll()
            await model.remoteDeliver(requestId: "b", units: 1.0, passcode: "0000", from: .garmin, peerId: "garmin")
            #expect(box.echoes.contains { $0.status == .failed && $0.message == passcodeMessage })

            // Required + CORRECT ⇒ passes the passcode gate (no passcode-denial echo — it proceeds to deliver).
            box.echoes.removeAll()
            await model.remoteDeliver(requestId: "c", units: 1.0, passcode: "1234", from: .garmin, peerId: "garmin")
            #expect(!box.echoes.contains { $0.message == passcodeMessage })
        }
    }

    @Test func appleWatchIsExemptFromThePasscode() async {
        await withClean {
            #expect(BolusPasscodeStore.setPasscode("1234"))
            let (model, backend, box) = makeModel()
            await backend.connect()
            // A watch deliver with NO code, while a passcode is set, is NEVER passcode-gated (wrist detection).
            await model.remoteDeliver(requestId: "w", units: 1.0, passcode: nil, from: .appleWatch, peerId: "watch")
            #expect(!box.echoes.contains { $0.message == passcodeMessage })
        }
    }
}
