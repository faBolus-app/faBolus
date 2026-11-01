#if DEBUG
import Foundation
import PhoneApp

/// The scripted pump under the real session, for the simulator and for trying screens without a pump.
/// Debug builds only; turned on from the Debug menu or with the `-mockPump YES` launch argument, and read
/// at launch.
@MainActor
enum DebugMock {
    static let key = "mockPump"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    static let pump = MockPump()
    /// The mock's own files, apart from a real pump's.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mock-pump", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
#endif
