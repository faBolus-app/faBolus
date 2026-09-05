import Foundation
import faBolusCore
@testable import faBolus

/// TEST-ONLY shared helpers for the phone-side remote-command suites, living beside
/// `RemoteCommandWireFixture` in `Support/`.
///
/// `FakeLink` is a minimal in-memory `RemoteTransport` so a `RemoteCommandWireFixture` (or any type that
/// takes a link) can be exercised without a real transport. Most suites drive `handle(_:)` directly — the
/// same entry point the link's `onReceive` calls — so `send(_:)` is intentionally a no-op; it only
/// satisfies the initializer.
///
/// `EchoRecorder` captures every `RemoteCommand` the model echoes back to a remote, so a test can assert on
/// the exact status sequence and messages a surface would see. (The `CrossClientMutexTests` suite keeps its
/// own request-id-keyed recorder, whose API differs — it is intentionally not this type.)
final class FakeLink: RemoteTransport {
    var onReceive: (@MainActor (RemoteCommand) -> Void)?
    var onReachabilityChange: (@MainActor (Bool) -> Void)?
    var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
    var isReachable: Bool = true
    func send(_ command: RemoteCommand) {}
}

@MainActor
final class EchoRecorder {
    private(set) var commands: [RemoteCommand] = []
    func attach(to model: AppModel) { model.addRemoteEcho { [weak self] c in self?.commands.append(c) } }
    var last: RemoteCommand? { commands.last }
    var statuses: [RemoteCommand.Status] { commands.compactMap { $0.status } }
    func count(_ s: RemoteCommand.Status) -> Int { statuses.filter { $0 == s }.count }
}
