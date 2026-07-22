import Foundation
import faBolusCore

/// Whether the app is driving **this phone's pump** or acting as a **remote** for another phone's pump
/// (app-wide Remote mode). The remote client is created lazily on first use and kept alive across
/// switches — its BLE central runs while a remote model exists — so switching back and forth is instant
/// and doesn't re-pair. Persisted so the app relaunches into whatever the user last chose.
@MainActor
@Observable
final class AppRouter {
    enum Target: String { case thisPump, remote }

    var target: Target {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: Self.key) }
    }
    /// The remote client, once the user has entered Remote mode at least once. Kept alive.
    private(set) var remote: PhoneRemoteClientModel?

    private static let key = "appTarget"

    init() {
        target = Target(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .thisPump
        if target == .remote { remote = PhoneRemoteClientModel() }
    }

    /// Switch to controlling this phone's own pump. The remote model stays alive (reconnects instantly
    /// when switched back); it's only released when the user forgets the host.
    func controlThisPump() { target = .thisPump }

    /// Switch to controlling the remote host (creating the remote client on first use).
    func controlRemote() {
        if remote == nil { remote = PhoneRemoteClientModel() }
        target = .remote
    }
}
