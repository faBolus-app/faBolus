import Foundation
import faBolusCore

/// Phase 3 (03-02, REMOTE-02) — the iPhone-to-iPhone peer "act as a remote for another phone" mode is
/// removed from narrow `main` (`PhoneRemoteClientModel` deleted, preserved on `dev/phone-remote`).
/// `Target` now has exactly one case; kept (not deleted outright) per the plan's explicit scope — a
/// future remote surface has one place to re-add a second case. Persisted so the app relaunches into
/// whatever the user last chose (today, always `.thisPump`).
@MainActor
@Observable
final class AppRouter {
    enum Target: String { case thisPump }

    var target: Target {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: Self.key) }
    }

    private static let key = "appTarget"

    init() {
        target = Target(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .thisPump
    }

    /// Switch to controlling this phone's own pump. The only mode narrow `main` supports.
    func controlThisPump() { target = .thisPump }
}
